#define CS_TAG "app"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <notify.h>
#import <stdlib.h>
#import <Security/Security.h>

// SecTask.h ships on macOS but not in the public iOS SDK, even though the
// symbols are real exports of the iOS Security.framework this process already
// links. Declare just what's needed rather than pull in a private header.
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement,
                                                CFErrorRef *error);

// Injected into every UIKit process, so the first job is to get out of the way
// again as fast as possible. Only a process that is (a) a real app, (b) not part
// of the system UI, and (c) on the user's allowlist installs a single hook.

static BOOL CSProcessIsBridgeableApp(void) {
    NSBundle *main = NSBundle.mainBundle;
    NSString *bundleID = main.bundleIdentifier;
    if (bundleID.length == 0) return NO;

    // System UI processes get the other dylib, not this one.
    static NSSet *excluded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = [NSSet setWithArray:@[
            @"com.apple.springboard",
            @"com.apple.CarPlayApp",
            @"com.apple.CarPlayTemplateUIHost",
            @"com.apple.Preferences",
        ]];
    });
    if ([excluded containsObject:bundleID.lowercaseString] ||
        [excluded containsObject:bundleID]) {
        return NO;
    }

    // Extensions, daemons and XPC services share UIKit but can never own a
    // CarPlay scene.
    NSString *path = main.bundlePath;
    if ([path hasSuffix:@".appex"] || [path hasSuffix:@".xpc"]) return NO;
    if (main.infoDictionary[@"NSExtension"]) return NO;

    return YES;
}

/// A native CarPlay app is not automatically unsafe to bridge — YouTube Music
/// (single CarPlay scene role, UIApplicationSupportsMultipleScenes false in
/// its own Info.plist) took the scene-role rewrite fine. Waze crashed, and
/// what's actually different about it isn't "native" — it's that Waze runs
/// *three* concurrent CarPlay-family scenes (main template, Dashboard,
/// Instrument Cluster) under UIApplicationSupportsMultipleScenes true. Our
/// rewrite hook only knows about the one scene it's touching; swapping that
/// scene's class out from under whatever UIKit/Waze's own delegate does to
/// coordinate all three at once is what tripped the assertion in
/// +[UIScene _sceneForFBSScene:create:withSession:connectionOptions:] — not
/// rewriting a template role in general. See CSAppHasComplexNativeCarPlayScenes.
static NSArray<NSString *> *CSKnownCarPlayEntitlementKeys(void) {
    static NSArray *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *mutable = [NSMutableArray arrayWithObjects:
            @"CARCapableApp", @"com.apple.developer.playable-content", nil];
        // The full set CarKit's admission gate recognises — see
        // +[CRCarPlayAppDeclaration requiredEntitlementKeys].
        NSArray *suffixes = @[ @"parking", @"communication", @"audio", @"public-safety",
                               @"charging", @"driving-task", @"maps", @"protocols",
                               @"messaging", @"calling", @"quick-ordering", @"fueling" ];
        for (NSString *suffix in suffixes) {
            [mutable addObject:[@"com.apple.developer.carplay-" stringByAppendingString:suffix]];
        }
        keys = mutable;
    });
    return keys;
}

static BOOL CSAppHasNativeCarPlayCapability(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;

    BOOL found = NO;
    for (NSString *key in CSKnownCarPlayEntitlementKeys()) {
        CFTypeRef value = SecTaskCopyValueForEntitlement(task, (__bridge CFStringRef)key, NULL);
        if (!value) continue;
        id boxed = (__bridge_transfer id)value; // transfers ownership; releases value
        if ([boxed respondsToSelector:@selector(boolValue)] && [boxed boolValue]) {
            found = YES;
            break;
        }
    }
    CFRelease(task);
    return found;
}

/// YES if this app declares more than the one plain CarPlay scene role — a
/// Dashboard and/or Instrument Cluster scene alongside the main template
/// scene, or explicitly opts into them via the CPSupports* flags. Reads this
/// process's own Info.plist, which is always public, sandboxed-safe API —
/// no entitlement inspection needed for a fact the app itself declares.
static BOOL CSAppHasComplexNativeCarPlayScenes(void) {
    NSDictionary *manifest = NSBundle.mainBundle.infoDictionary[@"UIApplicationSceneManifest"];
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;

    if ([manifest[@"CPSupportsDashboardNavigationScene"] boolValue]) return YES;
    if ([manifest[@"CPSupportsInstrumentClusterNavigationScene"] boolValue]) return YES;

    NSDictionary *configurations = manifest[@"UISceneConfigurations"];
    if (![configurations isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *role in configurations) {
        // Any CarPlay-family role beyond the one plain template role this
        // tweak already knows how to rewrite — Dashboard and Instrument
        // Cluster both fall under this without hardcoding their exact names,
        // so a future CPTemplateApplication* role variant is caught too.
        if ([role hasPrefix:@"CPTemplateApplication"] &&
            ![role isEqualToString:@"CPTemplateApplicationSceneSessionRoleApplication"]) {
            return YES;
        }
    }
    return NO;
}

__attribute__((constructor))
static void CSAppInit(void) {
    @autoreleasepool {
        if (!CSProcessIsBridgeableApp()) return;

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        CSConfig *config = CSConfig.sharedConfig;

        // Logged unconditionally, and before the checks below. Previously a
        // sandbox that hid the preferences made this function return in silence,
        // which was indistinguishable in the log from the dylib never having been
        // injected at all — two very different bugs.
        CSLog("loaded into %s (enabled=%d, allowlisted=%d)", bundleID.UTF8String,
                config.isEnabled, [config isBundleEnabled:bundleID]);

        if (!config.isEnabled) return;
        if (![config isBundleEnabled:bundleID]) return;

        BOOL native = CSAppHasNativeCarPlayCapability();
        CSSceneSource source = [CSConfig.sharedConfig optionsForBundle:bundleID].sceneSource;

        // The choice only exists for an app that ships its own CarPlay UI. For
        // everything else there is no template UI to fall back to, so asking for
        // one would just mean the app never appears.
        if (native && source == CSSceneSourceNative) {
            CSLog("%s is set to use its own CarPlay interface — installing no "
                    "bridge hooks", bundleID.UTF8String);
            return;
        }
        if (native && CSAppHasComplexNativeCarPlayScenes() &&
            source != CSSceneSourcePhone) {
            CSLog("%s runs multiple concurrent native CarPlay scenes (dashboard/"
                    "instrument cluster) — installing no bridge hooks; rewriting "
                    "one of several coordinated scenes crashed Waze this way. "
                    "Uses its own CarPlay UI instead. Set CarPlay Interface to "
                    "Phone Screen for this app to bridge it anyway.",
                    bundleID.UTF8String);
            return;
        }
        if (!native && source == CSSceneSourceNative) {
            CSLog("%s has no CarPlay interface of its own — bridging its phone "
                    "scene despite the Own Interface setting", bundleID.UTF8String);
        }

        CSLog("bridging enabled for %s%s", bundleID.UTF8String,
                !native ? ""
                        : (source == CSSceneSourcePhone
                               ? " (native, phone scene requested — bridged "
                                 "instead of its own template UI)"
                               : " (native, single CarPlay scene — bridged rather "
                                 "than left on its own template UI)"));
        // The per-app Settings page posts this cooperative close request after
        // changing display options. It avoids a whole-device respring and does
        // not require Preferences to hold process-management privileges.
        NSString *closeNotification =
            [@"com.pavunato.carsurf/close/" stringByAppendingString:bundleID];
        int closeToken = 0;
        notify_register_dispatch(closeNotification.UTF8String, &closeToken,
                                 dispatch_get_main_queue(), ^(int token) {
            CSLog("close requested from per-app display settings");
            exit(0);
        });

        // A native app in Phone Screen mode should be handed a plain CarPlay
        // window scene, because CSSceneManifestSpoof.m hides its template roles
        // from CarPlay. If a template scene turns up regardless, rewriting it is
        // fatal — leave it to the app.
        CSSetLeavesTemplateScenesAlone(native && source == CSSceneSourcePhone);

        CSInstallSceneBridge();
        CSInstallTraitOverrides();
        CSInstallFullscreenLayoutSupport();
        CSInstallKeyboardSupport();
    }
}
