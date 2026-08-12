#import "CSPatchLog.h"
#import <notify.h>
#import <sys/stat.h>

NSString *const CSPatchLogPath = @"/var/jb/Library/CarSurf/patch.log";
NSString *const CSPatchLogClearNotification =
    @"com.pavunato.carsurf/patch-log-clear";

static const unsigned long long kMaximumPatchLogBytes = 1024 * 1024;
static const NSUInteger kRetainedPatchLogBytes = 512 * 1024;

static NSString *CSPatchLogTimestamp(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    return [formatter stringFromDate:NSDate.date];
}

NSString *CSPatchLogRead(void) {
    NSData *data = [NSData dataWithContentsOfFile:CSPatchLogPath];
    if (data.length == 0) return @"";
    NSString *text = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    return text ?: @"[CarSurf could not decode the patch log as UTF-8.]\n";
}

static void CSPatchLogEnsureDirectory(void) {
    NSString *directory = CSPatchLogPath.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:@{ NSFilePosixPermissions : @(0755) }
                                                  error:NULL];
}

static void CSPatchLogTrimIfNeeded(void) {
    NSDictionary *attributes = [NSFileManager.defaultManager
        attributesOfItemAtPath:CSPatchLogPath error:NULL];
    if ([attributes fileSize] <= kMaximumPatchLogBytes) return;

    NSData *data = [NSData dataWithContentsOfFile:CSPatchLogPath];
    if (data.length <= kRetainedPatchLogBytes) return;
    NSUInteger start = data.length - kRetainedPatchLogBytes;
    const unsigned char *bytes = data.bytes;
    // Begin on a complete line, which also avoids cutting through a multibyte
    // UTF-8 character in an app name or diagnostic message.
    while (start < data.length && bytes[start] != '\n') start++;
    if (start < data.length) start++;
    NSData *tail = [data subdataWithRange:NSMakeRange(start, data.length - start)];
    NSMutableData *replacement = [NSMutableData dataWithData:
        [@"[Older patch-log entries were trimmed.]\n"
            dataUsingEncoding:NSUTF8StringEncoding]];
    [replacement appendData:tail];
    [replacement writeToFile:CSPatchLogPath atomically:YES];
    chmod(CSPatchLogPath.fileSystemRepresentation, 0644);
}

void CSPatchLogAppend(NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (body.length == 0) return;

    CSPatchLogEnsureDirectory();
    CSPatchLogTrimIfNeeded();
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      CSPatchLogTimestamp(), body];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![NSFileManager.defaultManager fileExistsAtPath:CSPatchLogPath]) {
        [data writeToFile:CSPatchLogPath atomically:YES];
    } else {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:CSPatchLogPath];
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    }
    chmod(CSPatchLogPath.fileSystemRepresentation, 0644);
}

void CSPatchLogClear(void) {
    CSPatchLogEnsureDirectory();
    [[NSData data] writeToFile:CSPatchLogPath atomically:YES];
    chmod(CSPatchLogPath.fileSystemRepresentation, 0644);
    CSPatchLogAppend(@"[log] Cleared by user — ready to reproduce the patch failure.");
}

void CSPatchLogRequestClear(void) {
    notify_post(CSPatchLogClearNotification.UTF8String);
}
