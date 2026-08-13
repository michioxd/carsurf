#define CS_TAG "mirror"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSPrivate.h"

// Apps with no UIApplicationSceneManifest run in UIKit's single-window
// compatibility mode: their delegate owns exactly one UIWindow and there is no
// scene delegate to build a second UI. The car scene still connects (see
// CSSceneBridge.m) but arrives empty.
//
// Rather than host the phone window's CAContext in a CALayerHost and hand-forward
// touches — which loses gestures, keyboard, and presentation contexts — this
// *transplants* the app's root view controller into the car window and puts it
// back on disconnect. Touch, gestures, modals, and the keyboard then work with no
// forwarding code at all, because UIKit is doing its normal job on a window that
// happens to live on the head unit.
//
// The trade-off is that the phone screen goes blank while the app is bridged. A
// view controller can only belong to one window, and duplicating the render tree
// is what the layer-hosting approach buys at the cost of an inert UI. For a screen
// you are not supposed to be looking at while driving, blank is the right answer.

static UIWindow *gSourceWindow;
static UIViewController *gTransplantedRoot;
static UIWindow *gCarWindow;
static __weak UIWindowScene *gCarScene;
static CSAppOptions *gCarOptions;
static CGSize gSourceSize;
static BOOL gVideoActive;
static BOOL gAutoHorizontalApplied;

/// Positions the actual app window inside whatever CarPlay's persistent chrome
/// leaves free — a leading sidebar on a landscape head unit, a bottom bar on a
/// portrait one — then applies the user's render scale inside that rectangle. The app's
/// own root controller remains the window root so its menus and presentations
/// use their normal UIKit hierarchy.
static UIEdgeInsets CSConfigureTransplantWindow(UIWindow *window,
                                                  UIWindowScene *scene,
                                                  CSAppOptions *options,
                                                  CGSize sourceSize,
                                                  BOOL autoHorizontal,
                                                  BOOL *outPortrait) {
    // Explicit layout modes are hard constraints. Only Auto is allowed to switch
    // from the source window's natural portrait shape to horizontal for video.
    UIEdgeInsets sceneSafeArea = UIEdgeInsetsZero;
    CGRect usableFrame = CSCarViewportForWindow(window, scene, options, sourceSize,
                                                autoHorizontal, &sceneSafeArea,
                                                outPortrait);

    CGFloat scale = options.scale > 0.01 ? options.scale : 1.0;
    window.frame = usableFrame;
    window.bounds = CGRectMake(0, 0, usableFrame.size.width / scale,
                               usableFrame.size.height / scale);
    window.layer.anchorPoint = CGPointZero;
    window.layer.position = usableFrame.origin;
    window.layer.transform = CATransform3DMakeScale(scale, scale, 1.0);
    [window layoutIfNeeded];
    CSNeutralizeResidualSafeArea(window);
    return sceneSafeArea;
}

BOOL CSAppIsSingleWindowOnly(void) {
    static BOOL singleWindow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *manifest = NSBundle.mainBundle.infoDictionary[@"UIApplicationSceneManifest"];
        NSDictionary *configurations = [manifest isKindOfClass:NSDictionary.class]
                                           ? manifest[@"UISceneConfigurations"] : nil;
        singleWindow = ![configurations isKindOfClass:NSDictionary.class] ||
                       [configurations count] == 0;
        CSVLog("scene manifest %s -> %s mode",
                 singleWindow ? "absent/empty" : "present",
                 singleWindow ? "transplant" : "independent scene");
    });
    return singleWindow;
}

/// Logs every window the app owns and where it lives. When CarPlay launches an app
/// that was not already running, "no UI to transplant" is ambiguous between the app
/// having built nothing and our having looked in the wrong place; this settles it.
static void CSLogWindowInventory(void) {
    UIApplication *application = UIApplication.sharedApplication;

    id delegate = application.delegate;
    UIWindow *delegateWindow = nil;
    if ([delegate respondsToSelector:@selector(window)]) {
        delegateWindow = [delegate performSelector:@selector(window)];
    }
    CSLog("inventory: delegate=%s delegate.window=%s rootVC=%s",
            object_getClassName(delegate),
            delegateWindow ? object_getClassName(delegateWindow) : "nil",
            delegateWindow.rootViewController ? object_getClassName(delegateWindow.rootViewController)
                                              : "nil");

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        CSLog("inventory: scene %s role=%s bridged=%d windows=%lu",
                object_getClassName(scene), scene.session.role.UTF8String,
                CSIsBridgedCarScene(scene), (unsigned long)windowScene.windows.count);
        for (UIWindow *window in windowScene.windows) {
            CSLog("inventory:   window %s rootVC=%s hidden=%d",
                    object_getClassName(window),
                    window.rootViewController ? object_getClassName(window.rootViewController)
                                              : "nil",
                    window.hidden);
        }
    }
}

/// A window whose root view controller we can move to the head unit.
///
/// Searched widest-first, because in single-window compatibility mode UIKit hands
/// the app's only window to the delegate rather than to a scene we can enumerate:
///   1. the delegate's own -window (compatibility mode)
///   2. any window on a scene that is not the car scene
///   3. any window on the car scene — meaning UIKit already placed the app's UI
///      there, in which case nothing needs moving at all
static UIWindow *CSTransplantSourceWindow(UIWindowScene *carScene,
                                            BOOL *outAlreadyOnCarScene) {
    if (outAlreadyOnCarScene) *outAlreadyOnCarScene = NO;
    UIApplication *application = UIApplication.sharedApplication;

    id delegate = application.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        UIWindow *window = [delegate performSelector:@selector(window)];
        if (window.rootViewController && window != gCarWindow) {
            if (window.windowScene == carScene && outAlreadyOnCarScene) {
                *outAlreadyOnCarScene = YES;
            }
            return window;
        }
    }

    UIWindow *onCarScene = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            if (!window.rootViewController || window == gCarWindow) continue;
            if (scene == carScene || CSIsBridgedCarScene(scene)) {
                onCarScene = onCarScene ?: window;
                continue;
            }
            return window; // a genuine phone-side window: prefer it
        }
    }

    if (onCarScene && outAlreadyOnCarScene) *outAlreadyOnCarScene = YES;
    return onCarScene;
}

static void CSAttemptTransplant(UIWindowScene *scene, CSAppOptions *options,
                                  NSInteger attemptsLeft);

void CSStartMirroringIntoScene(UIWindowScene *scene, CSAppOptions *options) {
    if (gCarWindow) {
        CSLog("already transplanted; ignoring duplicate request");
        return;
    }
    CSAttemptTransplant(scene, options, 10);
}

void CSSetMirroringVideoActive(BOOL active) {
    // Remember the player state even if it arrives before the mirror window is
    // ready. The initial transplant then starts in the correct Auto geometry.
    gVideoActive = active;
    if (!gCarWindow || !gCarScene || !gCarOptions) return;

    BOOL autoHorizontal = active && gCarOptions.layoutMode == CSLayoutModeAuto;
    if (gAutoHorizontalApplied == autoHorizontal) return;

    gAutoHorizontalApplied = autoHorizontal;
    BOOL portrait = NO;
    CSConfigureTransplantWindow(gCarWindow, gCarScene, gCarOptions,
                                  gSourceSize, autoHorizontal, &portrait);
    [gCarWindow.rootViewController.view setNeedsLayout];
    [gCarWindow.rootViewController.view layoutIfNeeded];
    CSLog("video auto-layout active=%d result=%s window=%.0fx%.0f at x=%.0f",
            active, portrait ? "vertical" : "horizontal",
            gCarWindow.bounds.size.width, gCarWindow.bounds.size.height,
            gCarWindow.layer.position.x);
}

static void CSAttemptTransplant(UIWindowScene *scene, CSAppOptions *options,
                                  NSInteger attemptsLeft) {
    if (gCarWindow) return;
    if (scene.activationState == UISceneActivationStateUnattached) {
        CSLog("car scene went away before the transplant could run");
        return;
    }

    BOOL alreadyOnCarScene = NO;
    UIWindow *source = CSTransplantSourceWindow(scene, &alreadyOnCarScene);
    UIViewController *root = source.rootViewController;
    if (!root) {
        // When CarPlay is what launched the app, its window may not exist yet.
        // Retry briefly rather than giving up on the first frame.
        if (attemptsLeft > 0) {
            CSVLog("no window with a root view controller yet; retrying (%ld left)",
                     (long)attemptsLeft);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CSAttemptTransplant(scene, options, attemptsLeft - 1);
            });
            return;
        }
        CSLog("nothing to transplant — window inventory follows:");
        CSLogWindowInventory();
        return;
    }

    if (alreadyOnCarScene) {
        // UIKit already attached the app's only window to the car scene. Moving it
        // would be a no-op at best; just make sure it is actually on screen.
        source.hidden = NO;
        [source makeKeyAndVisible];
        CSApplyScaleToCarScene(scene, options);
        CSLog("app's window was already on the car scene (%s) — made it visible "
                "instead of transplanting", object_getClassName(root));
        return;
    }

    gSourceWindow = source;
    gTransplantedRoot = root;
    gCarScene = scene;
    gCarOptions = options;
    gSourceSize = source.bounds.size;
    gAutoHorizontalApplied = gVideoActive && options.layoutMode == CSLayoutModeAuto;

    // Detach before re-attaching: UIKit asserts if a view controller is set as the
    // root of two windows at once.
    source.rootViewController = nil;

    UIWindow *car = [[UIWindow alloc] initWithWindowScene:scene];
    car.frame = scene.coordinateSpace.bounds;
    car.rootViewController = root;
    [car makeKeyAndVisible];
    gCarWindow = car;

    BOOL portrait = NO;
    UIEdgeInsets sceneSafeArea =
        CSConfigureTransplantWindow(car, scene, options, gSourceSize,
                                      gAutoHorizontalApplied,
                                      &portrait);
    UIEdgeInsets contentSafeArea = root.view.safeAreaInsets;

    CSLog("transplanted %s as the window root (%.0fx%.0f at (%.0f,%.0f), portrait=%d, "
            "scene safe l=%.0f t=%.0f r=%.0f b=%.0f, "
            "content safe l=%.0f t=%.0f r=%.0f b=%.0f)",
            object_getClassName(root), car.bounds.size.width, car.bounds.size.height,
            car.layer.position.x, car.layer.position.y, portrait,
            sceneSafeArea.left, sceneSafeArea.top,
            sceneSafeArea.right, sceneSafeArea.bottom,
            contentSafeArea.left, contentSafeArea.top,
            contentSafeArea.right, contentSafeArea.bottom);
}

void CSStopMirroring(void) {
    if (!gTransplantedRoot) return;

    UIViewController *root = gTransplantedRoot;
    UIWindow *source = gSourceWindow;

    gCarWindow.rootViewController = nil;
    gCarWindow.hidden = YES;
    gCarWindow = nil;

    // Put the UI back on the phone. If the source window went away while we were
    // bridged there is nothing to restore it to, and the app will rebuild its own
    // UI on next activation.
    if (source) {
        source.rootViewController = root;
        [source makeKeyAndVisible];
        CSLog("restored %s to the phone display", object_getClassName(root));
    } else {
        CSLog("source window is gone; leaving restoration to the app");
    }

    gTransplantedRoot = nil;
    gSourceWindow = nil;
    gCarScene = nil;
    gCarOptions = nil;
    gSourceSize = CGSizeZero;
    gAutoHorizontalApplied = NO;
}
