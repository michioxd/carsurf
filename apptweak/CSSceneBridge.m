#define CS_TAG "scene"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"
#import <objc/message.h>

NSString *const CSCarSceneRolePrefix = @"CPTemplateApplicationSceneSessionRole";

// Two role families reach a bridged app:
//
//   UIWindowSceneSessionRoleCarPlay          what the manifest spoof advertises,
//                                            and what Apple's own CarCamera /
//                                            CarRadio / AutoSettings use
//   CPTemplateApplicationSceneSessionRole*   the template role, for apps CarPlay
//                                            already knew about
//
// Neither exists in an ordinary app's Info.plist, so both are rewritten onto the
// app's real window-scene configuration.
NSString *const CSCarPlayWindowSceneRolePrefix = @"UIWindowSceneSessionRoleCarPlay";

BOOL CSIsCarSceneRole(NSString *role) {
    if (![role isKindOfClass:NSString.class]) return NO;
    return [role hasPrefix:CSCarSceneRolePrefix] ||
           [role hasPrefix:CSCarPlayWindowSceneRolePrefix];
}

// The whole tweak turns on this one idea: rather than teach a normal app to speak
// CarPlay's template protocol, we rewrite the *role* of the incoming scene from
// CPTemplateApplicationSceneSessionRoleApplication to the ordinary
// UIWindowSceneSessionRoleApplication. UIKit then resolves the app's own
// Info.plist scene configuration, instantiates a plain UIWindowScene, and hands
// it to the app's real scene delegate. The app renders a full interactive UI on
// the head unit without knowing the display is a car.
//
// Two selectors have to agree on the lie:
//   * -[UISceneConfiguration initWithName:sessionRole:] — so the configuration
//     lookup finds a match in Info.plist instead of throwing.
//   * -[UISceneSession role] — so an app whose delegate branches on the role
//     takes its normal path.

#pragma mark - Bridged scene bookkeeping

/// Sessions whose role we rewrote. Weak, so a disconnected scene's session does
/// not keep anything alive.
static NSHashTable *CSBridgedSessions(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static NSLock *CSBridgeLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}

static void CSMarkSessionBridged(id session) {
    if (!session) return;
    NSLock *lock = CSBridgeLock();
    [lock lock];
    [CSBridgedSessions() addObject:session];
    [lock unlock];
}

static BOOL CSIsSessionBridged(id session) {
    if (!session) return NO;
    NSLock *lock = CSBridgeLock();
    [lock lock];
    BOOL bridged = [CSBridgedSessions() containsObject:session];
    [lock unlock];
    return bridged;
}

BOOL CSIsBridgedCarScene(UIScene *scene) {
    return scene && CSIsSessionBridged(scene.session);
}

static NSInteger gActiveCarScenes = 0;

BOOL CSHasActiveCarScene(void) { return gActiveCarScenes > 0; }

#pragma mark - Role rewriting

static BOOL CSBridgingEnabledForThisApp(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        enabled = [CSConfig.sharedConfig isBundleEnabled:bundleID];
    });
    return enabled;
}

static id (*orig_initWithNameSessionRole)(id, SEL, NSString *, NSString *);

static id cs_initWithNameSessionRole(id self, SEL _cmd, NSString *name, NSString *role) {
    if (!CSIsCarSceneRole(role) || !CSBridgingEnabledForThisApp()) {
        return orig_initWithNameSessionRole(self, _cmd, name, role);
    }

    CSLog("rewriting scene role %s -> %s (configuration name: %s)",
            role.UTF8String, UIWindowSceneSessionRoleApplication.UTF8String,
            name.length ? name.UTF8String : "(default)");

    // Drop the configuration name too: it would be a CarPlay-specific name that
    // the app's Info.plist does not contain, and nil means "the default
    // configuration for this role".
    id configuration = orig_initWithNameSessionRole(self, _cmd, nil,
                                                    UIWindowSceneSessionRoleApplication);

    // Belt and braces: even with the role rewritten, pin the scene and delegate
    // classes to the app's window-scene pair so UIKit cannot fall back to a
    // template scene.
    UISceneConfiguration *typed = configuration;
    if ([typed respondsToSelector:@selector(setSceneClass:)]) {
        typed.sceneClass = UIWindowScene.class;
    }
    return configuration;
}

static NSString *(*orig_sessionRole)(id, SEL);

static NSString *cs_sessionRole(id self, SEL _cmd) {
    NSString *role = orig_sessionRole(self, _cmd);
    if (!CSIsCarSceneRole(role) || !CSBridgingEnabledForThisApp()) return role;

    // Remember this session so the trait and scale code can recognise the car
    // scene later, when its role no longer looks like CarPlay's.
    CSMarkSessionBridged(self);
    return UIWindowSceneSessionRoleApplication;
}

#pragma mark - Multi-scene support

static BOOL (*orig_supportsMultipleScenes)(id, SEL);

static BOOL cs_supportsMultipleScenes(id self, SEL _cmd) {
    if (!CSBridgingEnabledForThisApp()) return orig_supportsMultipleScenes(self, _cmd);
    // The phone scene and the car scene have to coexist; without this UIKit
    // refuses to connect the second one.
    return YES;
}

#pragma mark - Manifest configuration fallback

// Rewriting the role is usually enough, because the app's Info.plist has a
// configuration for the ordinary window-scene role. Apps with no scene manifest
// at all have nothing for UIKit to find, and the lookup throws
// "Info.plist contained no UIScene configuration dictionary". This catches that
// case and hands back the default window-scene configuration instead.

static id (*orig_configurationForRole)(id, SEL, NSString *);

/// +configurationWithName:sessionRole: below can re-enter this lookup. One level
/// of recursion is enough to know the synthesis path is already running.
static _Thread_local BOOL gSynthesizing = NO;

static id cs_configurationForRole(id self, SEL _cmd, NSString *role) {
    id configuration = orig_configurationForRole(self, _cmd, role);
    if (configuration || gSynthesizing || !CSBridgingEnabledForThisApp()) {
        return configuration;
    }

    if (!CSIsCarSceneRole(role) &&
        ![role isEqualToString:UIWindowSceneSessionRoleApplication]) {
        return configuration;
    }

    // Synthesize the configuration UIKit would have built for a plain window
    // scene. delegateClass is left nil: in compatibility mode there is no scene
    // delegate, and CSMirror transplants the UI into the resulting empty scene.
    gSynthesizing = YES;
    UISceneConfiguration *synthetic =
        [UISceneConfiguration configurationWithName:nil
                                       sessionRole:UIWindowSceneSessionRoleApplication];
    gSynthesizing = NO;
    synthetic.sceneClass = UIWindowScene.class;

    CSLog("synthesized a window-scene configuration for role %s", role.UTF8String);
    return synthetic;
}

#pragma mark - Scale

void CSApplyScaleToCarScene(UIWindowScene *scene, CSAppOptions *options) {
    CGFloat scale = options.scale > 0.01 ? options.scale : 1.0;

    for (UIWindow *window in scene.windows) {
        CGRect sceneBounds = scene.coordinateSpace.bounds;
        if (sceneBounds.size.width <= 0 || sceneBounds.size.height <= 0) continue;
        CGSize originalSize = window.bounds.size;

        window.layer.transform = CATransform3DIdentity;
        window.frame = sceneBounds;
        [window layoutIfNeeded];

        UIEdgeInsets safeArea = window.safeAreaInsets;
        CGRect visibleFrame = sceneBounds;
        visibleFrame.origin.x += safeArea.left;
        visibleFrame.size.width = MAX(1.0, visibleFrame.size.width - safeArea.left);
        BOOL portrait = options.layoutMode == CSLayoutModeVertical ||
                        (options.layoutMode == CSLayoutModeAuto &&
                         originalSize.height > originalSize.width);
        if (portrait) {
            CGFloat portraitWidth = MIN(visibleFrame.size.width,
                                        visibleFrame.size.height * (9.0 / 16.0));
            visibleFrame.origin.x += (visibleFrame.size.width - portraitWidth) * 0.5;
            visibleFrame.size.width = portraitWidth;
        }

        // Grow the window's logical size by 1/scale and shrink it visually by
        // scale: the app lays out for a larger canvas, and the result is
        // fitted inside the selected viewport. scale < 1 shows more UI.
        window.frame = visibleFrame;
        window.bounds = CGRectMake(0, 0, visibleFrame.size.width / scale,
                                   visibleFrame.size.height / scale);
        window.layer.anchorPoint = CGPointZero;
        window.layer.position = visibleFrame.origin;
        window.layer.transform = CATransform3DMakeScale(scale, scale, 1.0);

        CSVLog("configured car window to %.0fx%.0f at x=%.0f, %.2fx, portrait=%d",
                 window.bounds.size.width, window.bounds.size.height,
                 window.layer.position.x, scale, portrait);
    }
}

#pragma mark - Scene lifecycle

static void CSCarSceneConnected(UIScene *scene) {
    gActiveCarScenes++;

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    CSAppOptions *options = [CSConfig.sharedConfig optionsForBundle:bundleID];

    CSBridgeMode mode = options.mode;
    if (mode == CSBridgeModeAuto) {
        mode = CSAppIsSingleWindowOnly() ? CSBridgeModeMirror : CSBridgeModeScene;
    }

    CSLog("car scene connected (mode=%ld, scale=%.2f, layout=%ld)",
            (long)mode, options.scale, (long)options.layoutMode);

    if (![scene isKindOfClass:UIWindowScene.class]) {
        CSLog("car scene is a %s, not a UIWindowScene — role rewrite did not "
                "take effect; nothing to present", object_getClassName(scene));
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    CSSetActiveCarScreen(windowScene.screen);
    if (mode == CSBridgeModeMirror) {
        CSStartMirroringIntoScene(windowScene, options);
    } else {
        // The app's own scene delegate has already built its UI by now; all that
        // is left is the geometry adjustment.
        CSApplyScaleToCarScene(windowScene, options);
    }
}

static void CSCarSceneDisconnected(UIScene *scene) {
    if (gActiveCarScenes > 0) gActiveCarScenes--;
    if (gActiveCarScenes == 0) CSSetActiveCarScreen(nil);
    CSLog("car scene disconnected");
    CSStopMirroring();
}

static void CSObserveSceneLifecycle(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    // Activation, not connection: at connect time the app's scene delegate has
    // not yet created its window, so there would be nothing to scale.
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        UIScene *scene = note.object;
        if (!CSIsBridgedCarScene(scene)) return;
        static NSMutableSet *seen;
        if (!seen) seen = [NSMutableSet new];
        NSString *identifier = scene.session.persistentIdentifier ?: @"";
        if ([seen containsObject:identifier]) return;
        [seen addObject:identifier];
        CSCarSceneConnected(scene);
    }];

    [center addObserverForName:UISceneDidDisconnectNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        UIScene *scene = note.object;
        if (!CSIsBridgedCarScene(scene)) return;
        CSCarSceneDisconnected(scene);
    }];
}

#pragma mark - Install

void CSInstallSceneBridge(void) {
    BOOL configuration = CSSwizzleInstanceMethod(
        UISceneConfiguration.class, @selector(initWithName:sessionRole:),
        (IMP)cs_initWithNameSessionRole, (IMP *)&orig_initWithNameSessionRole);

    BOOL role = CSSwizzleInstanceMethod(
        UISceneSession.class, @selector(role),
        (IMP)cs_sessionRole, (IMP *)&orig_sessionRole);

    Class manifest = CSLookupClass("UIApplicationSceneManifest");
    BOOL multiScene = CSSwizzleInstanceMethod(
        manifest, @selector(supportsMultipleScenes),
        (IMP)cs_supportsMultipleScenes, (IMP *)&orig_supportsMultipleScenes);

    // The lookup selector has moved across releases; take whichever exists.
    static const char *const kRoleLookupSelectors[] = {
        "configurationForRole:", "sceneConfigurationForRole:", "_configurationForRole:",
    };
    for (size_t i = 0; i < sizeof(kRoleLookupSelectors) / sizeof(*kRoleLookupSelectors); i++) {
        SEL sel = sel_getUid(kRoleLookupSelectors[i]);
        if (!CSHasInstanceMethod(manifest, sel)) continue;
        CSSwizzleInstanceMethod(manifest, sel, (IMP)cs_configurationForRole,
                                  (IMP *)&orig_configurationForRole);
        break;
    }

    CSObserveSceneLifecycle();

    CSLog("scene bridge installed (configuration=%d, role=%d, multiScene=%d)",
            configuration, role, multiScene);

    if (!configuration && !role) {
        CSLog("WARNING: neither role-rewrite hook landed; this app cannot be "
                "bridged. Run tools/carsurf-audit on this device.");
    }
    if (!multiScene) {
        CSLog("WARNING: UIApplicationSceneManifest.supportsMultipleScenes not "
                "hooked; the car scene may be refused while the app is on screen.");
    }
}
