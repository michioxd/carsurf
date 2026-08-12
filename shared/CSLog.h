#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Logs to the system log under the "CarSurf" subsystem. Compiled out of
/// release builds unless CS_VERBOSE is set in the environment at runtime.
void CSLogImpl(const char *tag, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/// YES when verbose logging is enabled (CS_VERBOSE=1, or the `verboseLogging`
/// preference). Cached after first call.
BOOL CSVerboseEnabled(void);

#ifdef __cplusplus
}
#endif

#ifndef CS_TAG
#define CS_TAG "carsurf"
#endif

#define CSLog(fmt, ...)  CSLogImpl(CS_TAG, fmt, ##__VA_ARGS__)
#define CSVLog(fmt, ...) do { if (CSVerboseEnabled()) CSLogImpl(CS_TAG, fmt, ##__VA_ARGS__); } while (0)
