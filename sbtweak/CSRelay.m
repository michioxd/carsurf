#define CS_TAG "relay"

#import "CSSystemInternal.h"
#import "CSLog.h"
#import <notify.h>
#import <sys/stat.h>

static NSString *const kPrefsPath =
    @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist";
/// Must match CSConfig's first relay candidate. Under the jailbreak root, which
/// sandboxed apps can read; /var/tmp cannot be read from an app sandbox.
static NSString *const kRelayPath = @"/var/jb/Library/CarSurf/relay.plist";

// App sandboxes deny the shared Preferences directory. libSandy is the clean fix,
// but it is only a Recommends, so SpringBoard also drops a world-readable copy of
// the preferences where a sandboxed app can reach it. Nothing secret lives in
// there — it is an allowlist of bundle identifiers and a few layout numbers.
//
// carsurf-helperd writes the identical file for the identical reason. That is
// deliberate redundancy, not a leftover: this copy only exists once SpringBoard
// has been restarted with the tweak injected, and a just-installed package that
// has not resprung yet would otherwise leave every app tweak inert. Both writers
// are atomic and produce the same bytes, so whichever runs last is correct.
static void CSWriteRelay(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!prefs) {
        CSVLog("no preferences at %s; leaving relay untouched", kPrefsPath.UTF8String);
        return;
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:prefs
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        CSLog("relay serialization failed: %s", error.localizedDescription.UTF8String);
        return;
    }

    // The directory is ours to create on first run.
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:kRelayPath.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES
                                             attributes:@{ NSFilePosixPermissions : @(0755) }
                                                  error:&directoryError];

    // Write-then-rename so a reader never observes a half-written file.
    NSString *temporary = [kRelayPath stringByAppendingPathExtension:@"tmp"];
    if (![data writeToFile:temporary atomically:NO]) {
        CSLog("relay write to %s failed", temporary.UTF8String);
        return;
    }
    chmod(temporary.fileSystemRepresentation, 0644);

    NSFileManager *fileManager = NSFileManager.defaultManager;
    [fileManager removeItemAtPath:kRelayPath error:NULL];
    if (![fileManager moveItemAtPath:temporary toPath:kRelayPath error:&error]) {
        CSLog("relay rename failed: %s", error.localizedDescription.UTF8String);
        [fileManager removeItemAtPath:temporary error:NULL];
        return;
    }

    CSVLog("relay updated (%lu bytes)", (unsigned long)data.length);
}

void CSStartRelay(void) {
    CSWriteRelay();

    int token = 0;
    notify_register_dispatch("com.pavunato.carsurf/reload", &token,
                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                             ^(int t) { CSWriteRelay(); });
}
