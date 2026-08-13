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

/// YES if `applicationProxy` (an LSApplicationProxy) already carries real,
/// Apple-issued CarPlay entitlements — CARCapableApp, playable-content, or any
/// com.apple.developer.carplay-*.
///
/// carsurf-helperd never re-signs one of these (doing so destroys the signature
/// those entitlements are validated against), so anything the UI says about
/// patching is wrong for them. Deliberately does not count SBStarkCapable: that
/// is the entitlement CarSurf itself grants, and treating it as "native" would
/// make an app look untouchable the moment it had been patched.
///
/// Answers from LaunchServices rather than the binary, so it works from a
/// sandboxed process that cannot read the app bundle.
BOOL CSAppProxyHasNativeCarPlay(id applicationProxy);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
