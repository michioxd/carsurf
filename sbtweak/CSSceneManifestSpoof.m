#define CS_TAG "manifest"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>

// Runtime CarPlay admission for iOS 16.
//
// On iOS 18.5 nothing here fires: CarKit builds its declarations without ever
// consulting LaunchServices, which is why this file was abandoned once already.
// iOS 16 is a different pipeline, and a crash backtrace proved it reads exactly
// what we can reach:
//
//   DashBoard           +[DashBoard _newApplicationLibrary]_block_invoke
//   FrontBoardServices  _proxyPassesInclusionFilter
//   CoreServices        -[LSBundleProxy entitlementValueForKey:ofClass:valuesOfClass:]
//
// DashBoard is the CarPlay UI, and it filters the app library by asking
// LSBundleProxy for entitlements. That is the admission gate, and it is a plain
// ObjC message we can answer.
//
// This matters most on RootHide, where the on-disk route is simply unavailable:
// `jbctl trustcache add` silently refuses (exit 0, no error, no entry) for any
// path under /var/containers/Bundle/Application, so a re-signed App Store binary
// can never be made launchable. Measured directly — a probe in /var/mobile takes
// the trustcache from 166 to 167 entries, the same probe inside an app container
// leaves it at 167. Runtime admission is the only route left there.
//
// WHAT NOT TO DO — this file aborted both SpringBoard and CarPlay into safe mode:
//
//   * Never hook -entitlements or -_entitlements. On iOS 16 they do not vend an
//     NSDictionary; substituting one makes CoreServices send an LSEntitlements-only
//     selector to a plain dictionary. The unrecognized-selector exception is
//     thrown on FrontBoardServices' app-loader thread, which has no @catch, so the
//     process aborts during startup before any UI exists.
//   * Never call -bundleIdentifier on an NSBundle from inside an info-dictionary
//     hook; -bundleIdentifier is built on the info dictionary and the recursion
//     kills the stack.
//
// Everything below therefore only ever answers *value* getters, always with a
// type the caller already expects, and every hook body is wrapped so a surprise
// degrades to "not spoofed" instead of a boot loop.

static NSString *const kSceneManifestKey = @"UIApplicationSceneManifest";
static NSString *const kSceneConfigurationsKey = @"UISceneConfigurations";
static NSString *const kCarPlayRoleKey = @"UIWindowSceneSessionRoleCarPlay";
static NSString *const kMultipleScenesKey = @"UIApplicationSupportsMultipleScenes";
static NSString *const kStarkLaunchModesKey = @"SBStarkLaunchModes";

static NSString *CSProxyBundleIdentifier(id proxy) {
    SEL sel = @selector(bundleIdentifier);
    if (![proxy respondsToSelector:sel]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(proxy, sel);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static BOOL CSShouldSpoofProxy(id proxy, NSString **outBundleID) {
    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return NO;

    NSString *bundleID = CSProxyBundleIdentifier(proxy);
    if (!bundleID || ![config isBundleEnabled:bundleID]) return NO;

    if (outBundleID) *outBundleID = bundleID;
    return YES;
}

/// The CarCamera-style capability flags: they grant the plain UIWindowScene
/// CarPlay role rather than a template capability like -carplay-audio, which
/// would additionally advertise the app as a media source CarKit expects to
/// drive with the Now Playing template.
static BOOL CSIsCapabilityFlagKey(NSString *key) {
    return [key isKindOfClass:NSString.class] &&
           ([key isEqualToString:@"CARCapableApp"] ||
            [key isEqualToString:@"SBStarkCapable"]);
}

#pragma mark - Entitlement value getters (the admission gate)

// iOS 16's real selector, seen in the DashBoard backtrace. The two-argument form
// below is a wrapper around it on this release, but both are hooked because the
// shape has moved across versions and answering only one leaves a hole.

static id (*orig_entitlementValueForKey3)(id, SEL, NSString *, Class, Class);

static id cs_entitlementValueForKey3(id self, SEL _cmd, NSString *key,
                                     Class expected, Class valuesExpected) {
    id value = orig_entitlementValueForKey3(self, _cmd, key, expected, valuesExpected);
    if (value) return value; // genuinely entitled — never override a real answer

    @try {
        if (!CSIsCapabilityFlagKey(key)) return value;
        NSString *bundleID = nil;
        if (!CSShouldSpoofProxy(self, &bundleID)) return value;

        // Answer with the type the caller asked for. A boolean entitlement is an
        // NSNumber; if the caller wants anything else, decline rather than hand
        // back something it will message with a selector NSNumber lacks.
        if (expected && expected != NSNumber.class) return value;

        CSVLog("admitted %s via %s (3-arg)", bundleID.UTF8String, key.UTF8String);
        return @YES;
    } @catch (id exception) {
        CSLog("entitlement spoof (3-arg) suppressed an exception");
        return value;
    }
}

static id (*orig_entitlementValueForKey2)(id, SEL, NSString *, Class);

static id cs_entitlementValueForKey2(id self, SEL _cmd, NSString *key, Class expected) {
    id value = orig_entitlementValueForKey2(self, _cmd, key, expected);
    if (value) return value;

    @try {
        if (!CSIsCapabilityFlagKey(key)) return value;
        NSString *bundleID = nil;
        if (!CSShouldSpoofProxy(self, &bundleID)) return value;
        if (expected && expected != NSNumber.class) return value;

        CSVLog("admitted %s via %s (2-arg)", bundleID.UTF8String, key.UTF8String);
        return @YES;
    } @catch (id exception) {
        CSLog("entitlement spoof (2-arg) suppressed an exception");
        return value;
    }
}

#pragma mark - LSBundleInfoCachedValues (SpringBoard's route)

// SpringBoard does not read entitlements the way CarPlay does. Its
// FBSApplicationInfo builds the app library through -entitlementValuesForKeys:,
// which does not return an NSDictionary at all — it returns a private
// LSBundleInfoCachedValues, and the caller then pulls values out with -boolForKey:
// and friends. Substituting a dictionary for that object is exactly what aborted
// SpringBoard into safe mode, so instead the real object is handed back untouched
// and merely *tagged*; the accessors below then answer capability keys for tagged
// objects only.
//
// The tag set is weak: a cached-values object that goes away must not be kept
// alive, and a later object reusing the address must not inherit the tag.

static NSHashTable *CSTaggedCachedValues(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSLock *CSTagLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

static void CSTagCachedValues(id object) {
    if (!object) return;
    NSLock *lock = CSTagLock();
    [lock lock];
    [CSTaggedCachedValues() addObject:object];
    [lock unlock];
}

static BOOL CSIsTaggedCachedValues(id object) {
    if (!object) return NO;
    NSLock *lock = CSTagLock();
    [lock lock];
    BOOL tagged = [CSTaggedCachedValues() containsObject:object];
    [lock unlock];
    return tagged;
}

/// True when this lookup is one we should answer: a tagged object being asked
/// about a capability flag it does not really have.
static BOOL CSShouldAnswerCachedValue(id self, NSString *key, id existing) {
    return !existing && CSIsCapabilityFlagKey(key) && CSIsTaggedCachedValues(self);
}

static BOOL (*orig_cv_boolForKey)(id, SEL, NSString *);

static BOOL cs_cv_boolForKey(id self, SEL _cmd, NSString *key) {
    BOOL value = orig_cv_boolForKey(self, _cmd, key);
    @try {
        if (value) return value;
        if (!CSIsCapabilityFlagKey(key) || !CSIsTaggedCachedValues(self)) return value;
        CSVLog("answered boolForKey:%s for a tagged app library entry", key.UTF8String);
        return YES;
    } @catch (id exception) {
        return value;
    }
}

static id (*orig_cv_objectForKey)(id, SEL, NSString *);

static id cs_cv_objectForKey(id self, SEL _cmd, NSString *key) {
    id value = orig_cv_objectForKey(self, _cmd, key);
    @try {
        if (!CSShouldAnswerCachedValue(self, key, value)) return value;
        CSVLog("answered objectForKey:%s for a tagged app library entry", key.UTF8String);
        return @YES;
    } @catch (id exception) {
        return value;
    }
}

static id (*orig_cv_numberForKey)(id, SEL, NSString *);

static id cs_cv_numberForKey(id self, SEL _cmd, NSString *key) {
    id value = orig_cv_numberForKey(self, _cmd, key);
    @try {
        if (!CSShouldAnswerCachedValue(self, key, value)) return value;
        CSVLog("answered numberForKey:%s for a tagged app library entry", key.UTF8String);
        return @YES;
    } @catch (id exception) {
        return value;
    }
}

static id (*orig_cv_objectForKeyOfClass)(id, SEL, NSString *, Class);

static id cs_cv_objectForKeyOfClass(id self, SEL _cmd, NSString *key, Class expected) {
    id value = orig_cv_objectForKeyOfClass(self, _cmd, key, expected);
    @try {
        if (!CSShouldAnswerCachedValue(self, key, value)) return value;
        if (expected && expected != NSNumber.class) return value;
        CSVLog("answered objectForKey:%s ofClass: for a tagged app library entry",
              key.UTF8String);
        return @YES;
    } @catch (id exception) {
        return value;
    }
}

static id (*orig_cv_objectForKeyOfClassValues)(id, SEL, NSString *, Class, Class);

static id cs_cv_objectForKeyOfClassValues(id self, SEL _cmd, NSString *key,
                                          Class expected, Class valuesExpected) {
    id value = orig_cv_objectForKeyOfClassValues(self, _cmd, key, expected, valuesExpected);
    @try {
        if (!CSShouldAnswerCachedValue(self, key, value)) return value;
        if (expected && expected != NSNumber.class) return value;
        CSVLog("answered objectForKey:%s ofClass:valuesOfClass: for a tagged entry",
              key.UTF8String);
        return @YES;
    } @catch (id exception) {
        return value;
    }
}

static void CSInstallCachedValuesHooks(void) {
    Class cls = CSLookupClass("LSBundleInfoCachedValues");
    if (!cls) {
        CSLog("LSBundleInfoCachedValues absent — SpringBoard's app library cannot "
              "be answered on this release");
        return;
    }

    BOOL b = CSSwizzleInstanceMethod(cls, @selector(boolForKey:),
                                     (IMP)cs_cv_boolForKey, (IMP *)&orig_cv_boolForKey);
    BOOL o = CSSwizzleInstanceMethod(cls, @selector(objectForKey:),
                                     (IMP)cs_cv_objectForKey, (IMP *)&orig_cv_objectForKey);
    BOOL n = CSSwizzleInstanceMethod(cls, @selector(numberForKey:),
                                     (IMP)cs_cv_numberForKey, (IMP *)&orig_cv_numberForKey);
    BOOL oc = CSSwizzleInstanceMethod(cls, sel_getUid("objectForKey:ofClass:"),
                                      (IMP)cs_cv_objectForKeyOfClass,
                                      (IMP *)&orig_cv_objectForKeyOfClass);
    BOOL ocv = CSSwizzleInstanceMethod(cls, sel_getUid("objectForKey:ofClass:valuesOfClass:"),
                                       (IMP)cs_cv_objectForKeyOfClassValues,
                                       (IMP *)&orig_cv_objectForKeyOfClassValues);

    CSLog("app library accessors hooked (bool=%d, object=%d, number=%d, "
          "ofClass=%d, ofClassValues=%d)", b, o, n, oc, ocv);
}

static id (*orig_entitlementValuesForKeys)(id, SEL, NSArray *);

static id cs_entitlementValuesForKeys(id self, SEL _cmd, NSArray *keys) {
    id result = orig_entitlementValuesForKeys(self, _cmd, keys);

    @try {
        NSString *bundleID = nil;
        if (!CSShouldSpoofProxy(self, &bundleID)) return result;

        // Only ever augment a real dictionary. Manufacturing one when the callee
        // returned some other type is what aborted SpringBoard before. Log the
        // type when we decline: FBSApplicationInfo builds SpringBoard's app
        // library through this getter, so declining here is the difference
        // between an app reaching the CarPlay dashboard and not.
        // SpringBoard's FBSApplicationInfo gets an LSBundleInfoCachedValues here,
        // not a dictionary. Hand back the real object untouched and tag it — the
        // accessors above answer capability keys for tagged objects, which is the
        // only safe way to influence a type whose interface we do not own.
        if (![result isKindOfClass:NSDictionary.class]) {
            CSTagCachedValues(result);
            CSVLog("tagged the app library entry for %s (%s)", bundleID.UTF8String,
                  result ? object_getClassName(result) : "nil");
            return result;
        }
        if (![keys isKindOfClass:NSArray.class]) return result;

        NSMutableDictionary *patched = nil;
        for (NSString *key in keys) {
            if (!CSIsCapabilityFlagKey(key)) continue;
            if (((NSDictionary *)result)[key]) continue;
            if (!patched) patched = [result mutableCopy];
            patched[key] = @YES;
        }
        if (!patched) return result;

        CSVLog("admitted %s via a bulk entitlement query", bundleID.UTF8String);
        return patched;
    } @catch (id exception) {
        CSLog("entitlement spoof (bulk) suppressed an exception");
        return result;
    }
}

#pragma mark - Info dictionary (SBStarkLaunchModes and the CarPlay scene role)

/// Returns `manifest` with a CarPlay window-scene configuration added, preserving
/// the app's existing configurations — removing its phone scene role would break
/// the app everywhere else.
static NSDictionary *CSManifestWithCarPlayRole(id manifest, NSString *bundleID) {
    NSDictionary *original = [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;

    NSDictionary *existing = original[kSceneConfigurationsKey];
    if ([existing isKindOfClass:NSDictionary.class] && existing[kCarPlayRoleKey]) {
        return original; // genuinely CarPlay-capable already
    }

    NSMutableDictionary *configurations =
        [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy]
                                                    : [NSMutableDictionary new];

    // No UISceneDelegateClassName: we cannot know the app's delegate, and the
    // app-side tweak rewrites this role onto the app's own default window-scene
    // configuration anyway. The role only has to be present.
    configurations[kCarPlayRoleKey] = @[ @{ @"UISceneConfigurationName" : @"CarSurf" } ];

    NSMutableDictionary *result = original ? [original mutableCopy] : [NSMutableDictionary new];
    result[kSceneConfigurationsKey] = configurations;
    result[kMultipleScenesKey] = @YES;

    CSVLog("advertising %s as a CarPlay window-scene app", bundleID.UTF8String);
    return result;
}

static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *, Class);

static id cs_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key, Class expected) {
    id value = orig_objectForInfoDictionaryKey(self, _cmd, key, expected);

    @try {
        if ([key isEqualToString:kStarkLaunchModesKey]) {
            if (value) return value; // already declares it
            NSString *bundleID = nil;
            if (!CSShouldSpoofProxy(self, &bundleID)) return value;
            if (expected && expected != NSArray.class) return value;
            CSVLog("declared SBStarkLaunchModes for %s", bundleID.UTF8String);
            return @[ @"Default" ];
        }

        if (![key isEqualToString:kSceneManifestKey]) return value;
        if (expected && expected != NSDictionary.class) return value;

        NSString *bundleID = nil;
        if (!CSShouldSpoofProxy(self, &bundleID)) return value;
        return CSManifestWithCarPlayRole(value, bundleID);
    } @catch (id exception) {
        CSLog("info-dictionary spoof suppressed an exception");
        return value;
    }
}

#pragma mark - Install

void CSInstallSceneManifestSpoof(void) {
    Class proxy = CSLookupClass("LSBundleProxy");
    if (!proxy) {
        CSLog("WARNING: LSBundleProxy absent — runtime CarPlay admission is "
              "unavailable and allowlisted apps will not reach the dashboard.");
        return;
    }

    BOOL three = CSSwizzleInstanceMethod(
        proxy, sel_getUid("entitlementValueForKey:ofClass:valuesOfClass:"),
        (IMP)cs_entitlementValueForKey3, (IMP *)&orig_entitlementValueForKey3);

    BOOL two = CSSwizzleInstanceMethod(
        proxy, @selector(entitlementValueForKey:ofClass:),
        (IMP)cs_entitlementValueForKey2, (IMP *)&orig_entitlementValueForKey2);

    BOOL bulk = CSSwizzleInstanceMethod(
        proxy, @selector(entitlementValuesForKeys:),
        (IMP)cs_entitlementValuesForKeys, (IMP *)&orig_entitlementValuesForKeys);

    BOOL info = CSSwizzleInstanceMethod(
        proxy, @selector(objectForInfoDictionaryKey:ofClass:),
        (IMP)cs_objectForInfoDictionaryKey, (IMP *)&orig_objectForInfoDictionaryKey);

    CSLog("runtime admission installed (3-arg=%d, 2-arg=%d, bulk=%d, info=%d)",
          three, two, bulk, info);

    // SpringBoard's half of the gate. CarPlay's DashBoard is answered by the
    // getters above; SpringBoard owns the dashboard *layout* and reads through
    // the cached-values object instead, so both have to be covered or the app is
    // admitted to the library and still never appears.
    CSInstallCachedValuesHooks();

    if (!three && !two) {
        CSLog("WARNING: no entitlement value getter was hooked; apps cannot be "
              "admitted at runtime on this release.");
    }
}
