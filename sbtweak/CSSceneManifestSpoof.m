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

/// The entitlements that make CarPlay drive an app through its *template*
/// interface — the real, Apple-issued ones a navigation or audio app ships.
static BOOL CSIsTemplateCapabilityKey(NSString *key) {
    return [key isKindOfClass:NSString.class] &&
           ([key hasPrefix:@"com.apple.developer.carplay-"] ||
            [key isEqualToString:@"com.apple.developer.playable-content"]);
}

/// YES if this manifest declares more than the one plain CarPlay template scene
/// — a Dashboard and/or Instrument Cluster scene beside it (Vietmap, Waze).
/// Mirrors CSApp.m's CSAppHasComplexNativeCarPlayScenes and helperd's
/// CSInfoHasComplexNativeCarPlayScenes; all three have to agree about an app.
static BOOL CSManifestHasComplexCarPlayScenes(NSDictionary *manifest) {
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;

    if ([manifest[@"CPSupportsDashboardNavigationScene"] boolValue]) return YES;
    if ([manifest[@"CPSupportsInstrumentClusterNavigationScene"] boolValue]) return YES;

    NSDictionary *configurations = manifest[kSceneConfigurationsKey];
    if (![configurations isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *role in configurations) {
        if ([role isKindOfClass:NSString.class] &&
            [role hasPrefix:@"CPTemplateApplication"] &&
            ![role isEqualToString:@"CPTemplateApplicationSceneSessionRoleApplication"]) {
            return YES;
        }
    }
    return NO;
}

/// YES when this app should show its phone screen on the car display rather than
/// the CarPlay interface it ships — which is what CarSurf does for every enabled
/// app except a multi-scene native one left on Auto.
///
/// Phone Screen says so outright. Auto means it too for a *single-scene* native
/// app: CSApp.m bridges those (YouTube Music is the standing example) and
/// helperd records them native-bridged, so leaving their template entitlement
/// answering here contradicts the rest of the tweak — on iOS 16, where there is
/// no CarKit policy hook to force launchUsingTemplateUI off, that entitlement is
/// the whole decision and CarPlay drives the app with its Now Playing template
/// instead of the bridged scene.
static BOOL CSShouldShowPhoneScene(NSString *bundleID, NSDictionary *manifest) {
    if (bundleID.length == 0) return NO;
    switch ([CSConfig.sharedConfig optionsForBundle:bundleID].sceneSource) {
        case CSSceneSourcePhone:  return YES;
        case CSSceneSourceNative: return NO;
        case CSSceneSourceAuto:   break;
    }
    return !CSManifestHasComplexCarPlayScenes(manifest);
}

static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *, Class); // installed below

/// The app's real scene manifest, read through the *unhooked* getter so our own
/// spoof does not answer, and cached per bundle — the entitlement getters run
/// constantly, while this only changes when the app is updated.
static NSDictionary *CSRealSceneManifest(id proxy, NSString *bundleID) {
    static NSMutableDictionary *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });

    @synchronized (cache) {
        id cached = cache[bundleID];
        if (cached) return cached == NSNull.null ? nil : cached;
    }

    id manifest = nil;
    SEL sel = sel_getUid("objectForInfoDictionaryKey:ofClass:");
    if (orig_objectForInfoDictionaryKey && [proxy respondsToSelector:sel]) {
        manifest = orig_objectForInfoDictionaryKey(proxy, sel, kSceneManifestKey,
                                                   NSDictionary.class);
    }
    if (![manifest isKindOfClass:NSDictionary.class]) manifest = nil;

    @synchronized (cache) { cache[bundleID] = manifest ?: (id)NSNull.null; }
    return manifest;
}

/// Answers "this app has no template capability" for an app whose phone screen
/// CarSurf is putting on the car display.
///
/// Hiding the template scene roles from the manifest is not enough on its own:
/// CarPlay decides an app is a template app from these entitlements, and the
/// manifest is only consulted afterwards. Measured on Vietmap — with the roles
/// hidden but the entitlements still answering, CarPlay still built a
/// CPTemplateApplicationSceneSessionRoleApplication scene. Masking is confined
/// to a bundle the user enabled and is having bridged; every other app, and
/// every other key, keeps its real answer.
static BOOL CSShouldMaskTemplateCapability(id proxy, NSString *key, NSString **outBundleID) {
    if (!CSIsTemplateCapabilityKey(key)) return NO;

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(proxy, &bundleID)) return NO;
    if (!CSShouldShowPhoneScene(bundleID, CSRealSceneManifest(proxy, bundleID))) return NO;

    if (outBundleID) *outBundleID = bundleID;
    return YES;
}

/// One line per bundle+key: these getters are called constantly, and the fact
/// worth recording is that masking happened at all, not how often.
static void CSLogMaskedCapabilityOnce(NSString *bundleID, NSString *key) {
    static NSMutableSet<NSString *> *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });

    NSString *identity = [NSString stringWithFormat:@"%@|%@", bundleID, key];
    @synchronized (seen) {
        if ([seen containsObject:identity]) return;
        [seen addObject:identity];
    }
    CSLog("hiding %s from %s: phone screen requested, so CarPlay must not treat "
          "it as a template app", key.UTF8String, bundleID.UTF8String);
}

#pragma mark - Entitlement value getters (the admission gate)

// iOS 16's real selector, seen in the DashBoard backtrace. The two-argument form
// below is a wrapper around it on this release, but both are hooked because the
// shape has moved across versions and answering only one leaves a hole.

static id (*orig_entitlementValueForKey3)(id, SEL, NSString *, Class, Class);

static id cs_entitlementValueForKey3(id self, SEL _cmd, NSString *key,
                                     Class expected, Class valuesExpected) {
    id value = orig_entitlementValueForKey3(self, _cmd, key, expected, valuesExpected);
    if (value) {
        @try {
            NSString *masked = nil;
            if (CSShouldMaskTemplateCapability(self, key, &masked)) {
                CSLogMaskedCapabilityOnce(masked, key);
                return nil;
            }
        } @catch (id exception) {
            CSLog("template capability mask (3-arg) suppressed an exception");
        }
        return value; // genuinely entitled — never override a real answer
    }

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
    if (value) {
        @try {
            NSString *masked = nil;
            if (CSShouldMaskTemplateCapability(self, key, &masked)) {
                CSLogMaskedCapabilityOnce(masked, key);
                return nil;
            }
        } @catch (id exception) {
            CSLog("template capability mask (2-arg) suppressed an exception");
        }
        return value;
    }

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

/// The same idea for the other direction: entries belonging to an app the user
/// switched to Phone Screen, whose real template entitlements the accessors
/// below must answer as absent.
static NSHashTable *CSPhoneSceneCachedValues(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static void CSTagPhoneSceneCachedValues(id object) {
    if (!object) return;
    NSLock *lock = CSTagLock();
    [lock lock];
    [CSPhoneSceneCachedValues() addObject:object];
    [lock unlock];
}

static BOOL CSIsPhoneSceneCachedValues(id object) {
    if (!object) return NO;
    NSLock *lock = CSTagLock();
    [lock lock];
    BOOL tagged = [CSPhoneSceneCachedValues() containsObject:object];
    [lock unlock];
    return tagged;
}

/// True when this lookup must be answered as "no such entitlement" — a template
/// capability on an entry belonging to a Phone Screen app.
static BOOL CSShouldHideCachedValue(id self, NSString *key) {
    return CSIsTemplateCapabilityKey(key) && CSIsPhoneSceneCachedValues(self);
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
        if (CSShouldHideCachedValue(self, key)) return NO;
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
        if (CSShouldHideCachedValue(self, key)) return nil;
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
        if (CSShouldHideCachedValue(self, key)) return nil;
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
        if (CSShouldHideCachedValue(self, key)) return nil;
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
        if (CSShouldHideCachedValue(self, key)) return nil;
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
        BOOL phoneScene = CSShouldShowPhoneScene(bundleID, CSRealSceneManifest(self, bundleID));
        if (![result isKindOfClass:NSDictionary.class]) {
            CSTagCachedValues(result);
            if (phoneScene) CSTagPhoneSceneCachedValues(result);
            CSVLog("tagged the app library entry for %s (%s%s)", bundleID.UTF8String,
                  result ? object_getClassName(result) : "nil",
                  phoneScene ? ", phone screen" : "");
            return result;
        }
        if (![keys isKindOfClass:NSArray.class]) return result;

        NSMutableDictionary *patched = nil;
        for (NSString *key in keys) {
            // Same masking as the single-key getters: a Phone Screen app must
            // not look like a template app in a bulk query either.
            if (phoneScene && CSIsTemplateCapabilityKey(key) && ((NSDictionary *)result)[key]) {
                if (!patched) patched = [result mutableCopy];
                [patched removeObjectForKey:key];
                CSLogMaskedCapabilityOnce(bundleID, key);
                continue;
            }
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

/// Drops every CarPlay *template* scene role from a configuration set, leaving
/// the app's phone scene roles untouched.
///
/// This is what makes Phone Screen work at all. Adding the window-scene role
/// while the app's own CPTemplateApplication* roles are still declared leaves
/// CarPlay preferring the template path, so the app is launched into a real
/// template scene — and rewriting *that* scene's role throws inside
/// +[UIScene _sceneForFBSScene:create:withSession:connectionOptions:] and kills
/// the app on every launch. Reproduced on Vietmap on both iOS 16.7.12 and 18.5;
/// it is the same crash CSApp.m records against Waze. Nothing here touches the
/// app's own Info.plist — only the declaration CarPlay reads through
/// LSBundleProxy — so the app still behaves normally everywhere else.
static NSMutableDictionary *CSConfigurationsWithoutTemplateRoles(NSDictionary *configurations,
                                                                 NSString *bundleID,
                                                                 NSUInteger *outRemoved) {
    NSMutableDictionary *result = [configurations mutableCopy] ?: [NSMutableDictionary new];
    NSUInteger removed = 0;
    for (NSString *role in configurations.allKeys) {
        if (![role isKindOfClass:NSString.class]) continue;
        if (![role hasPrefix:@"CPTemplateApplication"]) continue;
        [result removeObjectForKey:role];
        removed++;
        CSVLog("hiding %s from %s: phone screen requested", role.UTF8String,
               bundleID.UTF8String);
    }
    if (outRemoved) *outRemoved = removed;
    return result;
}

/// Returns `manifest` with a CarPlay window-scene configuration added, preserving
/// the app's existing configurations — removing its phone scene role would break
/// the app everywhere else. In Phone Screen mode the app's own CarPlay template
/// roles are dropped as well; see CSConfigurationsWithoutTemplateRoles.
static NSDictionary *CSManifestWithCarPlayRole(id manifest, NSString *bundleID) {
    NSDictionary *original = [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;
    BOOL phoneScene = CSShouldShowPhoneScene(bundleID, original);

    NSDictionary *existing = original[kSceneConfigurationsKey];
    if (!phoneScene && [existing isKindOfClass:NSDictionary.class] && existing[kCarPlayRoleKey]) {
        return original; // genuinely CarPlay-capable already
    }

    NSMutableDictionary *configurations =
        [existing isKindOfClass:NSDictionary.class] ? [existing mutableCopy]
                                                    : [NSMutableDictionary new];

    NSUInteger hiddenTemplateRoles = 0;
    if (phoneScene) {
        configurations = CSConfigurationsWithoutTemplateRoles(configurations, bundleID,
                                                              &hiddenTemplateRoles);
    }
    if (phoneScene && configurations[kCarPlayRoleKey] && hiddenTemplateRoles == 0) {
        return original; // already exactly what Phone Screen wants
    }

    // No UISceneDelegateClassName: we cannot know the app's delegate, and the
    // app-side tweak rewrites this role onto the app's own default window-scene
    // configuration anyway. The role only has to be present. An app that already
    // declares the role keeps its own entry — ours names no delegate, so
    // replacing a real one would cost the app its scene delegate.
    if (!configurations[kCarPlayRoleKey]) {
        configurations[kCarPlayRoleKey] = @[ @{ @"UISceneConfigurationName" : @"CarSurf" } ];
    }

    NSMutableDictionary *result = original ? [original mutableCopy] : [NSMutableDictionary new];
    result[kSceneConfigurationsKey] = configurations;
    result[kMultipleScenesKey] = @YES;

    if (hiddenTemplateRoles > 0) {
        // These two ask CarPlay for a Dashboard and an Instrument Cluster scene
        // on top of the template scene. Leaving them set while the template
        // roles are gone invites CarPlay to build scenes with no configuration
        // behind them.
        [result removeObjectForKey:@"CPSupportsDashboardNavigationScene"];
        [result removeObjectForKey:@"CPSupportsInstrumentClusterNavigationScene"];
        CSVLog("advertising %s as a CarPlay window-scene app with %lu template "
               "role(s) hidden", bundleID.UTF8String, (unsigned long)hiddenTemplateRoles);
        return result;
    }

    CSVLog("advertising %s as a CarPlay window-scene app", bundleID.UTF8String);
    return result;
}

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
