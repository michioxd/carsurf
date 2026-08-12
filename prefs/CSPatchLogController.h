#import "CSPreferencesShim.h"

NS_ASSUME_NONNULL_BEGIN

/// Live, user-shareable view of carsurf-helperd's patch transcript.
@interface CSPatchLogController : PSViewController

/// Presents the same share sheet used by the log screen. Useful from a failed
/// patch alert so support data is one tap away.
+ (void)presentShareSheetFromController:(UIViewController *)controller
                             sourceView:(nullable UIView *)sourceView
                       bundleIdentifier:(nullable NSString *)bundleIdentifier;
@end

NS_ASSUME_NONNULL_END
