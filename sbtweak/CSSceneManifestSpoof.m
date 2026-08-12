#define CS_TAG "manifest"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <objc/message.h>

// The upstream half of gate G1.
//
// Promoting a CRCarPlayAppPolicy is not enough: CarKit only builds a
// CRCarPlayAppDeclaration — and therefore only asks for a policy — for apps it
// already considers CarPlay-capable. A backtrace showed the declarations being
// built inside CarKit off the FrontBoardServices app library, which reads each
// app's cached Info.plist through LSBundleProxy.
//
// What makes an app capable is visible in Apple's own non-template CarPlay apps.
// /Applications/CarCamera.app declares exactly this and nothing else:
//
//   UIApplicationSceneManifest = {
//     UISceneConfigurations = {
//       UIWindowSceneSessionRoleCarPlay = ( { UISceneDelegateClassName = ... } );
//     };
//   };
//
// UIWindowSceneSessionRoleCarPlay is a plain UIWindowScene role — a first-class
// UIKit mechanism for rendering real app UI on the head unit, distinct from the
// CPTemplateApplication template role. Apple's CarCamera, CarRadio, CarClimate and
// AutoSettings all work this way.
//
// So rather than forge CarPlay entitlements, this reports that role in the scene
// manifest of allowlisted apps. CarKit then treats them exactly like CarCamera.
// The app's own Info.plist on disk is untouched, so no code signature is affected.

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

/// Returns `manifest` with a CarPlay window-scene configuration added. The app's
/// existing configurations are preserved: removing its phone scene role would
/// break the app everywhere else.
static NSDictionary *CSManifestWithCarPlayRole(id manifest, NSString *bundleID) {
    NSDictionary *original = [manifest isKindOfClass:NSDictionary.class] ? manifest : nil;

    NSDictionary *existingConfigurations = original[kSceneConfigurationsKey];
    if ([existingConfigurations isKindOfClass:NSDictionary.class] &&
        existingConfigurations[kCarPlayRoleKey]) {
        return original; // genuinely CarPlay-capable already
    }

    NSMutableDictionary *configurations =
        [existingConfigurations isKindOfClass:NSDictionary.class]
            ? [existingConfigurations mutableCopy]
            : [NSMutableDictionary new];

    // No UISceneDelegateClassName: we cannot know the app's delegate, and the
    // app-side tweak rewrites this role onto the app's own default window-scene
    // configuration anyway. CarKit only needs the role to be present.
    configurations[kCarPlayRoleKey] = @[ @{ @"UISceneConfigurationName" : @"CarSurf" } ];

    NSMutableDictionary *result = original ? [original mutableCopy] : [NSMutableDictionary new];
    result[kSceneConfigurationsKey] = configurations;
    result[kMultipleScenesKey] = @YES;

    CSVLog("advertising %s as a CarPlay window-scene app", bundleID.UTF8String);
    return result;
}

#pragma mark - Hooks

static id (*orig_objectForInfoDictionaryKey)(id, SEL, NSString *, Class);

static id cs_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key, Class expected) {
    id value = orig_objectForInfoDictionaryKey(self, _cmd, key, expected);

    if ([key isEqualToString:kStarkLaunchModesKey]) {
        if (value) return value; // already declares it — nothing to add
        NSString *bundleID = nil;
        if (!CSShouldSpoofProxy(self, &bundleID)) return value;
        CSVLog("SBStarkLaunchModes spoofed for %s", bundleID.UTF8String);
        return @[ @"Default" ];
    }

    if (![key isEqualToString:kSceneManifestKey]) return value;

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return value;

    return CSManifestWithCarPlayRole(value, bundleID);
}

static id (*orig_objectsForInfoDictionaryKeys)(id, SEL, NSArray *);

static id cs_objectsForInfoDictionaryKeys(id self, SEL _cmd, NSArray *keys) {
    id values = orig_objectsForInfoDictionaryKeys(self, _cmd, keys);
    if (![keys containsObject:kSceneManifestKey]) return values;
    if (![values isKindOfClass:NSDictionary.class]) return values;

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return values;

    NSMutableDictionary *patched = [values mutableCopy];
    patched[kSceneManifestKey] =
        CSManifestWithCarPlayRole(patched[kSceneManifestKey], bundleID);
    return patched;
}

static id (*orig_infoDictionary)(id, SEL);

static id cs_infoDictionary(id self, SEL _cmd) {
    id info = orig_infoDictionary(self, _cmd);
    if (![info isKindOfClass:NSDictionary.class]) return info;

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return info;

    NSMutableDictionary *patched = [info mutableCopy];
    patched[kSceneManifestKey] =
        CSManifestWithCarPlayRole(patched[kSceneManifestKey], bundleID);
    return patched;
}

#pragma mark - NSBundle path

// LSBundleProxy's info-dictionary accessors are never consulted for a
// non-CarPlay app, so CarKit is not reading capability from LaunchServices. The
// declaration carries a -bundlePath, which points at CarKit loading each app
// bundle's Info.plist itself. These hooks cover that route.
//
// The bundle-identifier check short-circuits before any dictionary work, so the
// cost on SpringBoard's own (very frequent) info-dictionary reads is one string
// comparison.

// DANGER: -[NSBundle bundleIdentifier] is itself implemented on top of the info
// dictionary. Asking a bundle for its identifier from inside these hooks recurses
// until the stack dies, which takes SpringBoard with it. The identifier is
// therefore read out of the raw dictionary, and a reentrancy guard backs that up.
//
// Because a mistake here costs a boot loop rather than a missing feature, the
// whole NSBundle route is opt-in: set spoofViaNSBundle in the preferences.

static _Thread_local BOOL gInsideBundleHook = NO;

static BOOL CSNSBundleSpoofEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *path in @[ @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist",
                                  @"/var/tmp/.carsurf-relay.plist" ]) {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
            if (!prefs) continue;
            enabled = [prefs[@"spoofViaNSBundle"] boolValue];
            break;
        }
    });
    return enabled;
}

/// Identifier straight out of the dictionary — never via -bundleIdentifier.
static NSString *CSIdentifierFromInfo(NSDictionary *info) {
    id value = info[@"CFBundleIdentifier"];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id (*orig_bundleObjectForInfoDictionaryKey)(id, SEL, NSString *);

static id cs_bundleObjectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    id value = orig_bundleObjectForInfoDictionaryKey(self, _cmd, key);
    if (gInsideBundleHook || ![key isEqualToString:kSceneManifestKey]) return value;

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return value;

    gInsideBundleHook = YES;
    // Calling the original directly keeps this lookup out of our own hook.
    id identifier = orig_bundleObjectForInfoDictionaryKey(self, _cmd, @"CFBundleIdentifier");
    NSString *bundleID = [identifier isKindOfClass:NSString.class] ? identifier : nil;
    id result = value;
    if (bundleID && [config isBundleEnabled:bundleID]) {
        result = CSManifestWithCarPlayRole(value, bundleID);
    }
    gInsideBundleHook = NO;
    return result;
}

static id (*orig_bundleInfoDictionary)(id, SEL);

static id cs_bundleInfoDictionary(id self, SEL _cmd) {
    id info = orig_bundleInfoDictionary(self, _cmd);
    if (gInsideBundleHook || ![info isKindOfClass:NSDictionary.class]) return info;

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return info;

    NSString *bundleID = CSIdentifierFromInfo(info);
    if (!bundleID || ![config isBundleEnabled:bundleID]) return info;

    gInsideBundleHook = YES;
    NSMutableDictionary *patched = [info mutableCopy];
    patched[kSceneManifestKey] =
        CSManifestWithCarPlayRole(patched[kSceneManifestKey], bundleID);
    gInsideBundleHook = NO;
    return patched;
}

static void CSInstallBundleManifestSpoof(void) {
    if (!CSNSBundleSpoofEnabled()) {
        CSLog("NSBundle manifest spoof disabled (set spoofViaNSBundle to enable)");
        return;
    }

    BOOL key = CSSwizzleInstanceMethod(
        NSBundle.class, @selector(objectForInfoDictionaryKey:),
        (IMP)cs_bundleObjectForInfoDictionaryKey,
        (IMP *)&orig_bundleObjectForInfoDictionaryKey);

    BOOL whole = CSSwizzleInstanceMethod(
        NSBundle.class, @selector(infoDictionary),
        (IMP)cs_bundleInfoDictionary, (IMP *)&orig_bundleInfoDictionary);

    CSLog("NSBundle manifest spoof installed (key=%d, whole=%d)", key, whole);
}

#pragma mark - Entitlement declaration spoof (the actual G1 admission gate)

// The scene-manifest route above is necessary but not sufficient: CarKit never
// even asks a non-candidate app for its manifest. Measurement narrowed the real
// gate to +[CRCarPlayAppDeclaration requiredEntitlementKeys], fetched at
// hook-install time so a renamed/rebalanced key list on a future release is
// picked up automatically rather than hardcoded:
//
//   com.apple.developer.carplay-{parking,communication,audio,public-safety,
//     charging,driving-task,maps,protocols,messaging,calling,quick-ordering,
//     fueling}, com.apple.developer.playable-content, CARCapableApp,
//   SBStarkCapable   (requiredInfoKeys: SBStarkLaunchModes)
//
// Reading the actual code signatures on-device (ldid -e) shows two disjoint
// routes apps take through this list:
//
//   /Applications/CarCamera.app       entitlement CARCapableApp = true
//   /Applications/CarPlaySettings.app entitlement CARCapableApp = true
//   /Applications/MobilePhone.app     entitlement SBStarkCapable = true,
//                                     Info.plist SBStarkLaunchModes = [Default, Siri]
//                                     (no com.apple.developer.carplay-* keys at all)
//
// So CARCapableApp is the literal, documented-by-Apple's-own-usage flag for "this
// app renders on the CarPlay UIWindowScene" — exactly CarCamera's mechanism, which
// is the one this whole approach already targets. Safari's compiled entitlements
// obviously carry none of this and cannot be changed without re-signing, but
// CarKit does not read the live code signature for this decision: it goes through
// LSBundleProxy's declared-entitlement accessors, the same cached-metadata layer
// the manifest spoof above already lies to. Spoofing these getters is cosmetic to
// CarKit's bookkeeping, not a code-signature or sandbox change — it grants no real
// entitlement to the process, same as the existing manifest spoof.

static NSArray<NSString *> *CSRequiredEntitlementKeys(void) {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class declaration = CSLookupClass("CRCarPlayAppDeclaration");
        SEL sel = sel_getUid("requiredEntitlementKeys");
        id result = nil;
        if (declaration && [(id)declaration respondsToSelector:sel]) {
            result = ((id (*)(id, SEL))objc_msgSend)(declaration, sel);
        }
        keys = [result isKindOfClass:NSArray.class] ? result : @[ @"CARCapableApp" ];
        CSVLog("required entitlement keys for a CarPlay declaration: %s",
                 [[keys componentsJoinedByString:@", "] UTF8String]);
    });
    return keys;
}

/// True if this is the CarCamera-style capability flag we actually want: it
/// grants the plain UIWindowScene CarPlay role, not a template capability like
/// -carplay-audio that would additionally advertise the app as, say, a media
/// source CarKit expects to drive with the Now Playing template.
static BOOL CSIsCapabilityFlagKey(NSString *key) {
    return [key isEqualToString:@"CARCapableApp"] || [key isEqualToString:@"SBStarkCapable"];
}

static id (*orig_entitlementValueForKey)(id, SEL, NSString *, Class);

static id cs_entitlementValueForKey(id self, SEL _cmd, NSString *key, Class expected) {
    id value = orig_entitlementValueForKey(self, _cmd, key, expected);
    if (value) return value; // already entitled for real — nothing to add

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return value;
    if (!CSIsCapabilityFlagKey(key)) return value;

    CSVLog("entitlementValueForKey:%s spoofed YES for %s", key.UTF8String, bundleID.UTF8String);
    return @YES;
}

static id (*orig_entitlementValuesForKeys)(id, SEL, NSArray *);

static id cs_entitlementValuesForKeys(id self, SEL _cmd, NSArray *keys) {
    id result = orig_entitlementValuesForKeys(self, _cmd, keys);

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return result;

    NSMutableDictionary *patched =
        [result isKindOfClass:NSDictionary.class] ? [result mutableCopy] : [NSMutableDictionary new];
    BOOL changed = NO;
    for (NSString *key in keys) {
        if (patched[key] || !CSIsCapabilityFlagKey(key)) continue;
        patched[key] = @YES;
        changed = YES;
    }
    if (changed) {
        CSVLog("entitlementValuesForKeys spoofed capability flags for %s", bundleID.UTF8String);
    }
    return patched;
}

/// -entitlements / -_entitlements hand back the whole declared-entitlement
/// dictionary; some CarKit paths may read it directly rather than asking for
/// individual keys, so both routes get the same capability flags merged in.
static id (*orig_entitlements)(id, SEL);

static id cs_entitlements(id self, SEL _cmd) {
    id value = orig_entitlements(self, _cmd);

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return value;

    NSMutableDictionary *patched =
        [value isKindOfClass:NSDictionary.class] ? [value mutableCopy] : [NSMutableDictionary new];
    if (!patched[@"CARCapableApp"]) patched[@"CARCapableApp"] = @YES;
    return patched;
}

static id (*orig_underscoreEntitlements)(id, SEL);

static id cs_underscoreEntitlements(id self, SEL _cmd) {
    id value = orig_underscoreEntitlements(self, _cmd);

    NSString *bundleID = nil;
    if (!CSShouldSpoofProxy(self, &bundleID)) return value;

    NSMutableDictionary *patched =
        [value isKindOfClass:NSDictionary.class] ? [value mutableCopy] : [NSMutableDictionary new];
    if (!patched[@"CARCapableApp"]) patched[@"CARCapableApp"] = @YES;
    return patched;
}

static void CSInstallEntitlementDeclarationSpoof(Class proxy) {
    CSRequiredEntitlementKeys(); // logs the fetched list once, verbose only

    BOOL single = CSSwizzleInstanceMethod(
        proxy, @selector(entitlementValueForKey:ofClass:),
        (IMP)cs_entitlementValueForKey, (IMP *)&orig_entitlementValueForKey);

    BOOL multiple = CSSwizzleInstanceMethod(
        proxy, @selector(entitlementValuesForKeys:),
        (IMP)cs_entitlementValuesForKeys, (IMP *)&orig_entitlementValuesForKeys);

    BOOL whole = CSSwizzleInstanceMethod(
        proxy, @selector(entitlements),
        (IMP)cs_entitlements, (IMP *)&orig_entitlements);

    BOOL wholeUnderscore = CSSwizzleInstanceMethod(
        proxy, sel_getUid("_entitlements"),
        (IMP)cs_underscoreEntitlements, (IMP *)&orig_underscoreEntitlements);

    CSLog("entitlement declaration spoof installed (single=%d, multiple=%d, "
            "whole=%d, wholeUnderscore=%d)",
            single, multiple, whole, wholeUnderscore);
}

#pragma mark - Install

void CSInstallSceneManifestSpoof(void) {
    Class proxy = CSLookupClass("LSBundleProxy");
    if (!proxy) {
        CSLog("WARNING: LSBundleProxy absent — allowlisted apps cannot be "
                "advertised to CarKit and will not reach the dashboard.");
        return;
    }

    BOOL single = CSSwizzleInstanceMethod(
        proxy, @selector(objectForInfoDictionaryKey:ofClass:),
        (IMP)cs_objectForInfoDictionaryKey, (IMP *)&orig_objectForInfoDictionaryKey);

    BOOL multiple = CSSwizzleInstanceMethod(
        proxy, @selector(objectsForInfoDictionaryKeys:),
        (IMP)cs_objectsForInfoDictionaryKeys, (IMP *)&orig_objectsForInfoDictionaryKeys);

    BOOL whole = CSSwizzleInstanceMethod(
        proxy, @selector(_infoDictionary),
        (IMP)cs_infoDictionary, (IMP *)&orig_infoDictionary);

    CSLog("scene manifest spoof installed (single=%d, multiple=%d, whole=%d)",
            single, multiple, whole);

    CSInstallBundleManifestSpoof();
    CSInstallEntitlementDeclarationSpoof(proxy);
}
