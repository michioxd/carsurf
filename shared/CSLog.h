#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Logs to the system log under the "CarSurf" subsystem. Compiled out of
/// release builds unless CS_VERBOSE is set in the environment at runtime.
void CSLogImpl(const char *tag, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void CSLogTimingImpl(const char *tag, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/// YES when verbose logging is enabled (CS_VERBOSE=1, or the `verboseLogging`
/// preference). Cached after first call.
BOOL CSVerboseEnabled(void);

#ifdef __cplusplus
}
#endif

#ifndef CS_TAG
#define CS_TAG "carsurf"
#endif

// CSLog is diagnostic. Each call runs an NSDateFormatter plus a file write on
// the calling thread, and CarPlay's DashBoard calls Carsurf's admission and
// roster hooks for every app on a parallel rebuild — dozens of synchronous logs
// there stalled the main thread (the freeze-then-catch-up seen on device). Gate
// it behind verbose so daily use (verbose off) does no logging work at all,
// including evaluating the argument expressions.
#define CSLog(fmt, ...) do { if (CSVerboseEnabled()) CSLogImpl(CS_TAG, fmt, ##__VA_ARGS__); } while (0)
// Timing traces are diagnostics only. They fire on hot paths (every dashboard
// roster query), and each unconditional log runs an NSDateFormatter plus a file
// write on the calling thread, which is enough to hitch CarPlay animations — so
// keep them out of the default path and only emit when verbose is enabled.
#define CSTimingLog(fmt, ...) do { if (CSVerboseEnabled()) CSLogTimingImpl(CS_TAG, fmt, ##__VA_ARGS__); } while (0)
#define CSVLog(fmt, ...) do { if (CSVerboseEnabled()) CSLogImpl(CS_TAG, fmt, ##__VA_ARGS__); } while (0)
