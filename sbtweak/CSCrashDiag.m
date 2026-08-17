#define CS_TAG "crash"

#import "CSSystemInternal.h"
#import "CSLog.h"
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <string.h>

// Why this exists.
//
// The CarPlay host (com.apple.CarPlayApp, process "CarPlay") was observed to
// exit with SIGABRT and respawn while a runtime-admitted app (com.apple.stocks)
// was launched on the car screen. SIGABRT means an uncaught ObjC exception or a
// C++/libc abort — but no .ips crash report survived for it (ReportCrash appears
// to drop the report during the rapid respawn loop), and iOS ships no `log`
// binary, so the abort reason was simply unrecoverable after the fact.
//
// This module makes the reason recoverable. It installs, once, in the CarPlay UI
// processes:
//
//   * an uncaught-exception handler that writes the exception name, reason and
//     symbolicated call stack to carsurf.log *synchronously* (the normal CSLog
//     path is async and never flushes before abort()), then chains whatever
//     handler was already installed; and
//   * a SIGABRT/SIGILL/SIGTRAP handler for the non-ObjC abort case, which dumps
//     a raw backtrace with async-signal-safe calls to a log fd opened at install
//     time, then re-raises the default disposition so the normal crash-reporting
//     path is preserved.
//
// It changes no behaviour on any success path; it only records what happens on
// the way down. Once the launch crash is fixed this can stay in the debug build
// as a safety net or be removed.

static int gCrashLogFD = -1;

/// Open the shared log for append with a raw fd we can write from a signal
/// handler. Mirrors CSLog.m's path order; falls back to /var/tmp.
static void CSCrashOpenLogFD(void) {
    const char *paths[] = {
        "/var/mobile/Library/Logs/carsurf.log",
        "/var/tmp/carsurf.log",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths); i++) {
        int fd = open(paths[i], O_WRONLY | O_APPEND | O_CREAT, 0666);
        if (fd >= 0) {
            gCrashLogFD = fd;
            return;
        }
    }
}

/// Async-signal-safe write of a NUL-terminated string to the crash fd.
static void CSCrashWriteRaw(const char *text) {
    if (gCrashLogFD < 0 || !text) return;
    size_t len = strlen(text);
    ssize_t written = 0;
    while ((size_t)written < len) {
        ssize_t n = write(gCrashLogFD, text + written, len - written);
        if (n <= 0) break;
        written += n;
    }
}

/// Synchronous, non-async path (safe to use Foundation): write one already
/// composed line plus newline directly, bypassing CSLog's async queue so it is
/// on disk before the process dies.
static void CSCrashWriteLineSync(NSString *line) {
    if (!line) return;
    const char *utf8 = line.UTF8String;
    if (!utf8) return;
    if (gCrashLogFD >= 0) {
        CSCrashWriteRaw(utf8);
        CSCrashWriteRaw("\n");
        fsync(gCrashLogFD);
        return;
    }
    // Last resort: open, write, close on the calling thread.
    int fd = open("/var/tmp/carsurf.log", O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd < 0) return;
    write(fd, utf8, strlen(utf8));
    write(fd, "\n", 1);
    close(fd);
}

static NSUncaughtExceptionHandler *gPreviousExceptionHandler;

static void CSCrashExceptionHandler(NSException *exception) {
    const char *process = NSProcessInfo.processInfo.processName.UTF8String ?: "?";
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterShortStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    CSCrashWriteLineSync([NSString stringWithFormat:
        @"%@ [crash/%s] ==== UNCAUGHT EXCEPTION ====", stamp, process]);
    CSCrashWriteLineSync([NSString stringWithFormat:
        @"%@ [crash/%s] name=%@ reason=%@", stamp, process,
        exception.name ?: @"(nil)", exception.reason ?: @"(nil)"]);
    if (exception.userInfo) {
        CSCrashWriteLineSync([NSString stringWithFormat:
            @"%@ [crash/%s] userInfo=%@", stamp, process, exception.userInfo]);
    }
    for (NSString *frame in exception.callStackSymbols) {
        CSCrashWriteLineSync([NSString stringWithFormat:@"%@ [crash/%s]   %@",
                              stamp, process, frame]);
    }
    CSCrashWriteLineSync([NSString stringWithFormat:
        @"%@ [crash/%s] ==== END EXCEPTION ====", stamp, process]);

    // Preserve any handler already installed (e.g. a crash reporter) so we do
    // not suppress the normal path.
    if (gPreviousExceptionHandler) gPreviousExceptionHandler(exception);
}

static struct sigaction gPreviousAbortAction;
static struct sigaction gPreviousIllAction;
static struct sigaction gPreviousTrapAction;

static void CSCrashSignalHandler(int signo, siginfo_t *info, void *context) {
    CSCrashWriteRaw("\n==== FATAL SIGNAL ");
    switch (signo) {
        case SIGABRT: CSCrashWriteRaw("SIGABRT"); break;
        case SIGILL:  CSCrashWriteRaw("SIGILL"); break;
        case SIGTRAP: CSCrashWriteRaw("SIGTRAP"); break;
        default:      CSCrashWriteRaw("?"); break;
    }
    CSCrashWriteRaw(" in CarPlay host ====\n");

    void *frames[64];
    int count = backtrace(frames, 64);
    if (gCrashLogFD >= 0 && count > 0) {
        backtrace_symbols_fd(frames, count, gCrashLogFD);
        fsync(gCrashLogFD);
    }
    CSCrashWriteRaw("==== END FATAL SIGNAL ====\n");
    if (gCrashLogFD >= 0) fsync(gCrashLogFD);

    // Re-raise with the previous disposition so the normal crash-reporting path
    // (and respawn) is preserved.
    struct sigaction *prev = signo == SIGABRT ? &gPreviousAbortAction
                           : signo == SIGILL  ? &gPreviousIllAction
                                              : &gPreviousTrapAction;
    sigaction(signo, prev, NULL);
    raise(signo);
}

static void CSInstallSignal(int signo, struct sigaction *saved) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = CSCrashSignalHandler;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    sigaction(signo, &action, saved);
}

void CSInstallCrashDiagnostics(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    CSCrashOpenLogFD();

    gPreviousExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(CSCrashExceptionHandler);

    CSInstallSignal(SIGABRT, &gPreviousAbortAction);
    CSInstallSignal(SIGILL, &gPreviousIllAction);
    CSInstallSignal(SIGTRAP, &gPreviousTrapAction);

    CSLog("crash diagnostics installed (uncaught-exception + SIGABRT/SIGILL/SIGTRAP capture)");
}
