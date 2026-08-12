#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CSConfig.h"

NS_ASSUME_NONNULL_BEGIN

/// Any role string beginning with this prefix is CarPlay's main app scene role.
/// The dashboard-widget and instrument-cluster roles are deliberately left alone —
/// bridging those would put a full app UI where the car expects a small widget.
extern NSString *const CSCarSceneRolePrefix;

/// YES if `role` is the CarPlay main app scene role.
BOOL CSIsCarSceneRole(NSString *_Nullable role);

#pragma mark - Gate G2: give the app a scene it actually has

/// Rewrites the incoming CarPlay scene role to the app's ordinary window-scene
/// role, so UIKit resolves the app's real Info.plist scene configuration and
/// builds a plain, interactive UIWindowScene on the head unit.
void CSInstallSceneBridge(void);

/// YES once a bridged car scene has connected in this process.
BOOL CSHasActiveCarScene(void);

/// YES if this scene is one the tweak bridged onto the head-unit display.
BOOL CSIsBridgedCarScene(UIScene *_Nullable scene);

#pragma mark - Gate G3: make the app lay out for the head unit

/// Reports UIUserInterfaceIdiomPhone in place of ...IdiomCarPlay, and optionally
/// points +[UIScreen mainScreen] at the car screen.
void CSInstallTraitOverrides(void);

/// Updates the screen returned by the optional +[UIScreen mainScreen] override.
/// SceneBridge supplies this directly from the activated UIWindowScene so the
/// hook never has to enumerate UIApplication.connectedScenes recursively.
void CSSetActiveCarScreen(UIScreen *_Nullable screen);

/// Applies the per-app render scale to a freshly connected car scene.
void CSApplyScaleToCarScene(UIWindowScene *scene, CSAppOptions *options);

#pragma mark - Mirror mode (legacy single-window apps)

/// YES if this app cannot be given a second scene: no UIApplicationSceneManifest
/// in its Info.plist, so UIKit is running it in single-window compatibility mode.
BOOL CSAppIsSingleWindowOnly(void);

/// Puts a CALayerHost bound to the app's existing key window on the car scene and
/// forwards touches back to that window. Used when a real second scene is
/// impossible.
void CSStartMirroringIntoScene(UIWindowScene *scene, CSAppOptions *options);
void CSStopMirroring(void);

/// Temporarily expands an Auto-layout mirror to the full horizontal CarPlay
/// viewport while an app-owned video player is active. Explicit Horizontal and
/// Vertical selections are never overridden.
void CSSetMirroringVideoActive(BOOL active);

/// Installs narrow, app-specific video lifecycle adapters. These only change
/// Auto-layout geometry; they do not intercept modal or overlay presentation.
void CSInstallFullscreenLayoutSupport(void);

/// Enables UIKit's software keyboard for text responders hosted on a bridged
/// external-display scene. The overrides are inactive without a live car scene.
void CSInstallKeyboardSupport(void);

NS_ASSUME_NONNULL_END
