#define CS_TAG "log"

#import "CSLog.h"
#import <os/log.h>
#import <stdarg.h>
#import <sys/stat.h>
#import <unistd.h>

// iOS ships no `log` binary, so os_log output is effectively unreadable on a
// device without extra tooling (and on zsh, `log` is a shell built-in that
// silently swallows `log show ...`). Everything therefore also goes to a plain
// text file.
//
// Paths are tried in order. SpringBoard and CarPlay.app run as mobile and can
// write the shared locations; sandboxed apps fall back to their own container,
// which carsurf-logs collects.
static NSString *const kSharedLogPaths[] = {
    @"/var/mobile/Library/Logs/carsurf.log",
    @"/var/tmp/carsurf.log",
};

static os_log_t CSLogHandle(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("com.pavunato.carsurf", "tweak");
    });
    return handle;
}

BOOL CSVerboseEnabled(void) {
    static BOOL enabled;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("CS_VERBOSE");
        if (env && *env && *env != '0') {
            enabled = YES;
            return;
        }
        // Read the preference directly: CSConfig depends on this file, so it
        // cannot be used here without a cycle.
        for (NSString *path in @[ @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist",
                                  @"/var/tmp/.carsurf-relay.plist" ]) {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
            if (prefs) {
                enabled = [prefs[@"verboseLogging"] boolValue];
                return;
            }
        }
    });
    return enabled;
}

/// The first writable log path for this process, resolved once.
static NSString *CSLogFilePath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fileManager = NSFileManager.defaultManager;

        for (size_t i = 0; i < sizeof(kSharedLogPaths) / sizeof(*kSharedLogPaths); i++) {
            NSString *candidate = kSharedLogPaths[i];
            NSString *directory = candidate.stringByDeletingLastPathComponent;
            if (![fileManager fileExistsAtPath:directory]) continue;
            if (access(directory.fileSystemRepresentation, W_OK) != 0) continue;
            // A writable directory is not enough: carsurf-helperd runs as root
            // and creates this file 0644 root-owned, after which SpringBoard and
            // CarPlay.app (mobile) can no longer append to it. fopen just fails
            // and every line from those processes is lost — which is exactly how
            // the CarPlay policy and manifest hooks came to leave no trace at
            // all while helperd filled the same file with thousands of lines.
            if ([fileManager fileExistsAtPath:candidate] &&
                access(candidate.fileSystemRepresentation, W_OK) != 0) {
                continue;
            }
            path = candidate;
            return;
        }

        // Always writable, but inside the app's own container.
        path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"carsurf.log"];
    });
    return path;
}

static void CSAppendToFile(const char *line) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.pavunato.carsurf.log", DISPATCH_QUEUE_SERIAL);
    });

    NSString *entry = [NSString stringWithUTF8String:line];
    if (!entry) return;

    dispatch_async(queue, ^{
        NSString *path = CSLogFilePath();
        BOOL existed = access(path.fileSystemRepresentation, F_OK) == 0;
        FILE *file = fopen(path.fileSystemRepresentation, "a");
        if (!file) return;
        // Whoever creates the shared log decides who else can use it. root gets
        // there first (helperd starts at boot), so widen it immediately rather
        // than lock every mobile process out of the file it just made.
        if (!existed) chmod(path.fileSystemRepresentation, 0666);
        fputs(entry.UTF8String, file);
        fputc('\n', file);
        fclose(file);
    });
}

void CSLogImpl(const char *tag, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char *body = NULL;
    if (vasprintf(&body, fmt, args) < 0) body = NULL;
    va_end(args);
    if (!body) return;

    const char *process = NSProcessInfo.processInfo.processName.UTF8String ?: "?";

    os_log(CSLogHandle(), "[%{public}s/%{public}s] %{public}s", tag, process, body);

    // Timestamped, because the file accumulates across resprings.
    char *line = NULL;
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                    dateStyle:NSDateFormatterShortStyle
                                                    timeStyle:NSDateFormatterMediumStyle];
    if (asprintf(&line, "%s [%s/%s] %s", stamp.UTF8String ?: "?", tag, process, body) >= 0) {
        CSAppendToFile(line);
        free(line);
    }

    free(body);
}
