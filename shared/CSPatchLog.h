#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Root-helper transcript shown by the Settings live log viewer. The file is
/// deliberately outside app containers so a user can reproduce a failure and
/// share the exact helper output without SSH.
FOUNDATION_EXPORT NSString *const CSPatchLogPath;
FOUNDATION_EXPORT NSString *const CSPatchLogClearNotification;

#ifdef __cplusplus
extern "C" {
#endif

/// Reader side. Returns an empty string when the helper has not logged yet.
NSString *CSPatchLogRead(void);

/// Writer side (carsurf-helperd). Appends one timestamped line and keeps the
/// file world-readable. The transcript is bounded so an unattended daemon
/// cannot grow it forever.
void CSPatchLogAppend(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// Writer side. Truncates the transcript and adds a fresh session marker.
void CSPatchLogClear(void);

/// Settings side. Asks the root helper to clear the transcript.
void CSPatchLogRequestClear(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
