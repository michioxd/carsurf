#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// YES if `applicationProxy` (an LSApplicationProxy) is an app the user can
/// actually launch and would recognise on the home screen.
///
/// iOS ships well over 200 registered "applications", most of which are internal
/// UIServices — AuthKitUIService, app-clip hosts, print and share sheets. They are
/// ordinary `.app` bundles in /Applications with real display names, are not
/// placeholders, and are not launch-prohibited, so the only thing separating them
/// from Safari is `SBAppTags` containing "hidden" in their Info.plist. That is what
/// SpringBoard itself keys off.
///
/// `outReason` receives a short explanation when the answer is NO, for the
/// diagnostic tool.
BOOL CSAppIsUserVisible(id applicationProxy, NSString *_Nullable *_Nullable outReason);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
