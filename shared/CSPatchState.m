#define CS_TAG "patchstate"

#import "CSPatchState.h"
#import "CSLog.h"
#import <notify.h>
#import <sys/stat.h>

static NSString *const kStateDirectory = @"/var/jb/Library/CarSurf";
static NSString *const kStatePath = @"/var/jb/Library/CarSurf/patched.plist";
static NSString *const kRequestPath = @"/var/jb/Library/CarSurf/patch-request.plist";
NSString *const CSPatchRequestNotification = @"com.pavunato.carsurf/patch-now";

#pragma mark - Record

@implementation CSPatchRecord
- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if ((self = [super init])) {
        NSString *status = dict[@"status"];
        if ([status isEqualToString:@"patched"]) {
            _status = CSPatchStatusPatched;
        } else if ([status isEqualToString:@"failed"]) {
            _status = CSPatchStatusFailed;
        } else if ([status isEqualToString:@"native"]) {
            _status = CSPatchStatusNative;
        } else if ([status isEqualToString:@"native-bridged"]) {
            _status = CSPatchStatusNativeBridged;
        } else {
            _status = CSPatchStatusUnknown;
        }
        _updatedAt = [dict[@"updatedAt"] isKindOfClass:NSDate.class] ? dict[@"updatedAt"] : nil;
        _appVersion = [dict[@"appVersion"] isKindOfClass:NSString.class] ? dict[@"appVersion"] : nil;
        _failureReason = [dict[@"failureReason"] isKindOfClass:NSString.class] ? dict[@"failureReason"] : nil;
    }
    return self;
}
@end

#pragma mark - Shared I/O

static NSDictionary<NSString *, NSDictionary *> *CSPatchStateLoadRoot(void) {
    id contents = [NSDictionary dictionaryWithContentsOfFile:kStatePath];
    if ([contents isKindOfClass:NSDictionary.class]) return contents;

    // Legacy format: a bare array of bundle identifiers, all implicitly
    // "patched" with no timestamp. Read-only compatibility; the next successful
    // write from the daemon upgrades the file to the dictionary format.
    id legacy = [NSArray arrayWithContentsOfFile:kStatePath];
    if ([legacy isKindOfClass:NSArray.class]) {
        NSMutableDictionary *upgraded = [NSMutableDictionary new];
        for (id bundleID in (NSArray *)legacy) {
            if (![bundleID isKindOfClass:NSString.class]) continue;
            upgraded[bundleID] = @{ @"status" : @"patched" };
        }
        return upgraded;
    }

    return @{};
}

/// Write-then-rename so a reader never observes a half-written file, mirroring
/// CSRelay's approach for the same reason.
static void CSAtomicWritePlist(id plist, NSString *path) {
    [NSFileManager.defaultManager createDirectoryAtPath:kStateDirectory
                            withIntermediateDirectories:YES
                                             attributes:@{ NSFilePosixPermissions : @(0755) }
                                                  error:NULL];

    NSString *temporary = [path stringByAppendingPathExtension:@"tmp"];
    if (![plist writeToFile:temporary atomically:NO]) {
        CSLog("failed to write %s", temporary.UTF8String);
        return;
    }
    chmod(temporary.fileSystemRepresentation, 0644);

    NSFileManager *fileManager = NSFileManager.defaultManager;
    [fileManager removeItemAtPath:path error:NULL];
    NSError *error = nil;
    if (![fileManager moveItemAtPath:temporary toPath:path error:&error]) {
        CSLog("rename to %s failed: %s", path.UTF8String, error.localizedDescription.UTF8String);
        [fileManager removeItemAtPath:temporary error:NULL];
    }
}

#pragma mark - Reader API

CSPatchRecord *CSPatchStateRead(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) return nil;
    NSDictionary *entry = CSPatchStateLoadRoot()[bundleIdentifier];
    if (![entry isKindOfClass:NSDictionary.class]) return nil;
    return [[CSPatchRecord alloc] initWithDictionary:entry];
}

BOOL CSPatchStateIsPatched(NSString *bundleIdentifier) {
    return CSPatchStateRead(bundleIdentifier).status == CSPatchStatusPatched;
}

BOOL CSPatchStateIsNative(NSString *bundleIdentifier) {
    return CSPatchStateRead(bundleIdentifier).status == CSPatchStatusNative;
}

BOOL CSPatchStateIsNativeBridged(NSString *bundleIdentifier) {
    return CSPatchStateRead(bundleIdentifier).status == CSPatchStatusNativeBridged;
}

NSArray<NSString *> *CSPatchStateAllPatchedIdentifiers(void) {
    NSDictionary *root = CSPatchStateLoadRoot();
    NSMutableArray *identifiers = [NSMutableArray new];
    [root enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, NSDictionary *entry, BOOL *stop) {
        if ([entry[@"status"] isEqualToString:@"patched"]) [identifiers addObject:bundleID];
    }];
    return identifiers;
}

#pragma mark - Writer API

static void CSPatchStateSetEntry(NSString *bundleIdentifier, NSDictionary *_Nullable entry) {
    if (bundleIdentifier.length == 0) return;
    NSMutableDictionary *root = [CSPatchStateLoadRoot() mutableCopy];
    if (entry) {
        root[bundleIdentifier] = entry;
    } else {
        [root removeObjectForKey:bundleIdentifier];
    }
    CSAtomicWritePlist(root, kStatePath);
}

void CSPatchStateRecordSuccess(NSString *bundleIdentifier, NSString *appVersion) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"patched", @"status", [NSDate date], @"updatedAt", nil];
    if (appVersion.length) entry[@"appVersion"] = appVersion;
    CSPatchStateSetEntry(bundleIdentifier, entry);
}

void CSPatchStateRecordNative(NSString *bundleIdentifier, NSString *appVersion) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"native", @"status", [NSDate date], @"updatedAt", nil];
    if (appVersion.length) entry[@"appVersion"] = appVersion;
    CSPatchStateSetEntry(bundleIdentifier, entry);
}

void CSPatchStateRecordNativeBridged(NSString *bundleIdentifier, NSString *appVersion) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"native-bridged", @"status", [NSDate date], @"updatedAt", nil];
    if (appVersion.length) entry[@"appVersion"] = appVersion;
    CSPatchStateSetEntry(bundleIdentifier, entry);
}

void CSPatchStateRecordFailure(NSString *bundleIdentifier, NSString *reason) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        @"failed", @"status", [NSDate date], @"updatedAt", nil];
    if (reason.length) entry[@"failureReason"] = reason;
    CSPatchStateSetEntry(bundleIdentifier, entry);
}

void CSPatchStateRemove(NSString *bundleIdentifier) {
    CSPatchStateSetEntry(bundleIdentifier, nil);
}

#pragma mark - Manual request queue

void CSPatchRequestSubmit(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) return;

    NSMutableArray<NSString *> *pending =
        [[NSArray arrayWithContentsOfFile:kRequestPath] mutableCopy] ?: [NSMutableArray new];
    if (![pending containsObject:bundleIdentifier]) [pending addObject:bundleIdentifier];
    CSAtomicWritePlist(pending, kRequestPath);

    notify_post(CSPatchRequestNotification.UTF8String);
}

NSArray<NSString *> *CSPatchRequestTakeAll(void) {
    NSArray<NSString *> *pending = [NSArray arrayWithContentsOfFile:kRequestPath];
    if (pending.count == 0) return @[];
    [NSFileManager.defaultManager removeItemAtPath:kRequestPath error:NULL];
    return pending;
}
