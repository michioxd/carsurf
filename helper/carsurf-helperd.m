// carsurf-helperd — root helper that makes an app qualify for the CarPlay dashboard
// when the user enables it in Settings.
//
// Qualification cannot be done from the tweak or from Settings. The gate is
// +[CRCarPlayAppDeclaration requiredEntitlementKeys], which reads code-signed
// entitlements at app-registration time; granting one means re-signing the app's
// binary, trusting the new cdhash, and re-registering with LaunchServices. All of
// that needs root and none of it is possible inside a sandboxed app.
//
// The daemon is a *reconciler*, not a command queue: on every preference change it
// compares the set of enabled bundle identifiers against the set it has already
// patched, and re-verifies every one of them, not just the ones it hasn't seen
// before. That matters because an App Store update re-signs a bundle's binary
// with Apple's own signature, silently stripping the SBStarkCapable entitlement
// this daemon adds — the app just falls off CarPlay with no notification. Always
// re-checking (CSApplyPatch reads live entitlements and is a fast no-op when
// the patch is already in place) is what makes that self-heal instead of being
// masked forever by "we already touched this bundle once" state.
//
// Reconcile runs at boot and on every preference change. A manual "patch now"
// request is deliberately targeted to the requested app so its UI gets one
// prompt result without waiting for unrelated enabled apps to be re-verified.
//
// The outcome of every attempt — success, failure, and which app version it was
// attempted against — is recorded in CSPatchState. That record is the
// "indicator" the CarKit policy hook (CSCarKitPolicy.m) actually gates on, not
// the user's enabled toggle by itself: an app can be enabled in preferences and
// still not promoted to CarPlay if its last patch attempt didn't succeed.
//
// Every patch is backed up before it is applied, and disabling an app restores the
// backup, so the modifications are reversible without reinstalling the app.

#define CS_TAG "helperd"

#import <Foundation/Foundation.h>
#import "CSAppFilter.h"
#import "CSLog.h"
#import "CSPatchLog.h"
#import "CSPatchState.h"
#import <crt_externs.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <stdarg.h>
#import <sys/stat.h>
#import <sys/wait.h>

static NSString *const kPrefsPath =
    @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist";
static NSString *const kStateDirectory = @"/var/jb/Library/CarSurf";
/// Must match CSConfig's first relay candidate.
static NSString *const kRelayPath = @"/var/jb/Library/CarSurf/relay.plist";
static NSString *const kChangeNotification = @"com.pavunato.carsurf/reload";

static NSString *const kLdid = @"/var/jb/usr/bin/ldid";
static NSString *const kJbctl = @"/var/jb/usr/bin/jbctl";
static NSString *const kUicache = @"/var/jb/usr/bin/uicache";

// There is deliberately no RootHide special case here. An earlier build skipped
// patching entirely when AutoPatches.dylib was present, on the theory that
// CSSceneManifestSpoof would admit the app at runtime instead. That runtime route
// does not work and crashes SpringBoard (see CSSystem.m), and the skip was worse
// than useless: it reported CSApplyPatchResultPatched without touching the app,
// so the app silently never qualified. RootHide gets the same on-disk patch as
// every other jailbreak — measured working on iOS 16.7.12.

/// Keep the normal CarSurf log and the user-shareable patch transcript in sync
/// for every helper diagnostic. Other processes continue using CSLog normally.
static void CSHelperLog(const char *format, ...)
    __attribute__((format(printf, 1, 2)));
static void CSHelperLog(const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    char *body = NULL;
    if (vasprintf(&body, format, arguments) < 0) body = NULL;
    va_end(arguments);
    if (!body) return;
    CSLogImpl(CS_TAG, "%s", body);
    NSString *message = [NSString stringWithUTF8String:body];
    if (!message) {
        message = [[NSString alloc] initWithBytes:body length:strlen(body)
                                         encoding:NSISOLatin1StringEncoding];
    }
    CSPatchLogAppend(@"[helperd] %@", message ?: @"(unreadable log message)");
    free(body);
}

#undef CSLog
#define CSLog(fmt, ...) CSHelperLog(fmt, ##__VA_ARGS__)

/// Never touch these, whatever the preferences say. SpringBoard and Settings would
/// take the UI down with them; the rest keep the jailbreak itself manageable, and a
/// failed re-sign there could leave the device hard to recover.
static NSSet *CSProtectedBundleIdentifiers(void) {
    static NSSet *protected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        protected = [NSSet setWithArray:@[
            @"com.apple.springboard", @"com.apple.Preferences",
            @"org.coolstar.SileoStore", @"com.tigisoftware.Filza",
            @"com.opa334.Dopamine", @"com.opa334.Dopamine.WQX993NE3M",
        ]];
    });
    return protected;
}

static NSString *const kCSProtectedPatchReason =
    @"This app is protected because modifying it could break the jailbreak or "
     "device management. CarSurf will not patch it.";

#pragma mark - Subprocess

/// Runs a tool to completion. `stdoutPath`, when given, receives its stdout.
/// Returns the exit status, or -1 if the process could not be started.
static int CSRun(NSArray<NSString *> *arguments, NSString *stdoutPath) {
    if (arguments.count == 0) return -1;

    CSLog("run: %s", [arguments componentsJoinedByString:@" "].UTF8String);

    NSMutableArray *storage = [NSMutableArray new];
    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) return -1;
    for (NSUInteger i = 0; i < arguments.count; i++) {
        NSString *copy = [arguments[i] copy];
        [storage addObject:copy];
        argv[i] = (char *)copy.fileSystemRepresentation;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (stdoutPath) {
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                         stdoutPath.fileSystemRepresentation,
                                         O_WRONLY | O_CREAT | O_TRUNC, 0600);
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO,
                                         CSPatchLogPath.fileSystemRepresentation,
                                         O_WRONLY | O_CREAT | O_APPEND, 0644);
    } else {
        // Stream command output directly into the transcript while it runs.
        // This is what makes the Settings screen genuinely live rather than a
        // final summary assembled only after the helper has already failed.
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO,
                                         CSPatchLogPath.fileSystemRepresentation,
                                         O_WRONLY | O_CREAT | O_APPEND, 0644);
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    }

    pid_t pid = 0;
    // environ is not directly available to a dylib-free tool on iOS; go through the
    // documented accessor.
    int spawned = posix_spawn(&pid, argv[0], &actions, NULL, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&actions);
    free(argv);

    if (spawned != 0) {
        CSLog("failed to spawn %s: %s", arguments[0].UTF8String, strerror(spawned));
        return -1;
    }

    int status = 0;
    waitpid(pid, &status, 0);
    chmod(CSPatchLogPath.fileSystemRepresentation, 0644);
    int exitStatus = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    CSLog("exit %d: %s", exitStatus, arguments[0].UTF8String);
    return exitStatus;
}

#pragma mark - Bundle lookup

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@end

static NSString *CSBundlePathForIdentifier(NSString *bundleID) {
    Class proxyClass = objc_getClass("LSApplicationProxy");
    if (!proxyClass) return nil;

    id proxy = ((id (*)(Class, SEL, NSString *))objc_msgSend)(
        proxyClass, sel_getUid("applicationProxyForIdentifier:"), bundleID);
    if (!proxy) return nil;

    // Reuse the shared filter: it is what the preference picker offers, so anything
    // it rejects should never have been enabled in the first place.
    NSString *reason = nil;
    if (!CSAppIsUserVisible(proxy, &reason)) {
        CSLog("refusing %s: %s", bundleID.UTF8String, reason.UTF8String ?: "not user visible");
        return nil;
    }

    id url = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_getUid("bundleURL"));
    return [url isKindOfClass:NSURL.class] ? [(NSURL *)url path] : nil;
}

static NSString *CSExecutablePath(NSString *bundlePath) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executable = info[@"CFBundleExecutable"];
    if (executable.length == 0) return nil;
    return [bundlePath stringByAppendingPathComponent:executable];
}

#pragma mark - State

static NSString *CSBackupDirectory(NSString *bundleID) {
    return [[kStateDirectory stringByAppendingPathComponent:@"backups"]
            stringByAppendingPathComponent:bundleID];
}

/// RootHide runs jailbreak tools through its translated jbroot. A file created
/// in the system /tmp is consequently invisible when ldid later opens the same
/// literal path. Keep every helper scratch file under /var/jb instead, which
/// RootHide translates consistently for both the daemon and its child tools.
/// A UUID also prevents stale files or overlapping requests from colliding.
static NSString *CSScratchPath(NSString *purpose, NSString *extension) {
    NSString *name = [NSString stringWithFormat:@".%@-%@%@", purpose,
                      NSUUID.UUID.UUIDString,
                      extension.length ? [@"." stringByAppendingString:extension] : @""];
    return [kStateDirectory stringByAppendingPathComponent:name];
}

static NSString *CSAppVersion(NSString *bundleID) {
    NSString *bundlePath = CSBundlePathForIdentifier(bundleID);
    if (!bundlePath) return nil;
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                          [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    id version = info[@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] ? version : nil;
}

#pragma mark - Signing

/// Adds a newly-signed executable to the jailbreak's trustcache. RootHide's
/// jbctl expects a Mach-O path; older Dopamine jbctl builds expect a cdhash.
/// Try the path API first, then retain the cdhash form strictly as a fallback.
static BOOL CSTrustExecutable(NSString *executablePath) {
    if (CSRun(@[ kJbctl, @"trustcache", @"add", executablePath ], nil) == 0) {
        return YES;
    }

    CSLog("path-based trustcache add failed for %s; trying legacy cdhash API",
          executablePath.UTF8String);
    NSString *dump = CSScratchPath(@"cdhash", @"txt");
    if (CSRun(@[ kLdid, @"-h", executablePath ], dump) != 0) {
        [NSFileManager.defaultManager removeItemAtPath:dump error:NULL];
        return NO;
    }

    NSString *text = [NSString stringWithContentsOfFile:dump
                                              encoding:NSUTF8StringEncoding error:NULL];
    NSString *hash = nil;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"CDHash="]) {
            hash = [line substringFromIndex:@"CDHash=".length];
            break;
        }
    }
    [NSFileManager.defaultManager removeItemAtPath:dump error:NULL];

    if (hash.length == 0) {
        CSLog("could not read a cdhash for %s", executablePath.UTF8String);
        return NO;
    }
    return CSRun(@[ kJbctl, @"trustcache", @"add", hash ], nil) == 0;
}

static BOOL CSSignWithEntitlements(NSString *executablePath, NSString *entitlementsPath) {
    // -S replaces the entitlement set wholesale, which is why callers always pass a
    // merged copy of the app's real entitlements rather than just the new key.
    NSString *flag = [@"-S" stringByAppendingString:entitlementsPath];
    if (CSRun(@[ kLdid, flag, executablePath ], nil) != 0) {
        CSLog("ldid failed to sign %s", executablePath.UTF8String);
        return NO;
    }
    return CSTrustExecutable(executablePath);
}

/// A trustcache entry makes the re-signed main executable a *platform* process.
/// dyld then refuses to map any image into it — any embedded framework or
/// standalone dylib included — unless that image is platform-trusted too. This
/// was missing entirely until it took down YouTube Music and Photos: both got
/// SBStarkCapable, both got trustcache-added, neither had its Frameworks/
/// touched, and both were SIGKILLed within milliseconds of every launch —
/// on the phone, not just CarPlay — because dyld hit an untrusted framework
/// before app code ever ran. tools/carsurf-patch-app.sh always did this; the
/// daemon has to as well. See that script for the original recipe this mirrors.
static BOOL CSTrustFrameworks(NSString *bundlePath) {
    NSString *frameworksPath = [bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:frameworksPath isDirectory:&isDirectory] || !isDirectory) {
        return YES;
    }

    NSArray<NSString *> *entries = [fileManager contentsOfDirectoryAtPath:frameworksPath error:NULL];
    NSUInteger trusted = 0;
    BOOL succeeded = YES;
    for (NSString *entry in entries) {
        NSString *itemPath = [frameworksPath stringByAppendingPathComponent:entry];
        NSString *binaryPath;

        if ([entry hasSuffix:@".framework"]) {
            // A framework's signed Mach-O image conventionally matches its bundle
            // name — inspect that directly instead of every resource inside it.
            NSString *name = [entry stringByDeletingPathExtension];
            binaryPath = [itemPath stringByAppendingPathComponent:name];
        } else if ([entry hasSuffix:@".dylib"]) {
            binaryPath = itemPath;
        } else {
            continue;
        }
        if (![fileManager fileExistsAtPath:binaryPath]) continue;

        if (!CSTrustExecutable(binaryPath)) {
            CSLog("could not trust framework image %s", binaryPath.UTF8String);
            succeeded = NO;
            continue;
        }
        trusted++;

        // Do not replace the framework's inode after trusting it. Frameworks
        // carrying FairPlay SC_Info metadata (YouTube's Widevine is one) can
        // bind DRM integrity to the original file identity and crash at launch
        // if it is copied/deleted/moved, even when its bytes are unchanged. A
        // successful RootHide/Dopamine trustcache add is sufficient; the app
        // must be relaunched normally to pick it up.
    }
    CSLog("trusted %lu embedded framework/dylib image(s)", (unsigned long)trusted);
    return succeeded;
}

static NSDictionary *CSReadEntitlements(NSString *executablePath) {
    NSString *dump = CSScratchPath(@"entitlements-read", @"plist");
    if (CSRun(@[ kLdid, @"-e", executablePath ], dump) != 0) {
        [NSFileManager.defaultManager removeItemAtPath:dump error:NULL];
        return nil;
    }
    NSDictionary *entitlements = [NSDictionary dictionaryWithContentsOfFile:dump];
    [NSFileManager.defaultManager removeItemAtPath:dump error:NULL];
    return entitlements;
}

/// True for an app the App Store already shipped with real, provisioning-bound
/// CarPlay capability (CARCapableApp, any com.apple.developer.carplay-*, or
/// com.apple.developer.playable-content) — the same gate
/// tools/carsurf-patch-app.sh has always checked before touching a binary.
///
/// This was missing here, and it is what crashed YouTube Music on every launch
/// (phone and CarPlay alike): it already carries com.apple.developer.carplay-audio
/// and com.apple.developer.mediasetup, both cryptographically tied to Apple's own
/// signature over the binary. Re-signing with ldid replaces that signature with
/// an ad-hoc one that cannot back up those entitlements, and AMFI/CoreTrust kills
/// the process before it runs rather than let it claim capability it can no
/// longer prove. Re-signing an ordinary app costs nothing; re-signing one of
/// these does exactly this. Never do it — CarKit already admits these on its own.
static BOOL CSHasNativeCarPlayCapability(NSDictionary *entitlements) {
    if ([entitlements[@"CARCapableApp"] boolValue]) return YES;
    if ([entitlements[@"com.apple.developer.playable-content"] boolValue]) return YES;

    __block BOOL found = NO;
    [entitlements enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if ([key hasPrefix:@"com.apple.developer.carplay-"]) {
            found = YES;
            *stop = YES;
        }
    }];
    return found;
}

/// YES if a native CarPlay app declares more than the one plain CarPlay scene
/// role — a Dashboard and/or Instrument Cluster scene alongside its main
/// template scene (Waze), or opts into them via the CPSupports* flags.
/// Mirrors CSApp.m's CSAppHasComplexNativeCarPlayScenes exactly, reading the
/// same Info.plist from disk instead of a live process's own bundle — the two
/// must agree, since this decides CSPatchStatusNative (hands off completely)
/// vs CSPatchStatusNativeBridged (CSApp.m bridges it, so CSCarKitPolicy.m has
/// to force launchUsingTemplateUI off for it same as a patched app).
static BOOL CSInfoHasComplexNativeCarPlayScenes(NSDictionary *info) {
    NSDictionary *manifest = info[@"UIApplicationSceneManifest"];
    if (![manifest isKindOfClass:NSDictionary.class]) return NO;

    if ([manifest[@"CPSupportsDashboardNavigationScene"] boolValue]) return YES;
    if ([manifest[@"CPSupportsInstrumentClusterNavigationScene"] boolValue]) return YES;

    NSDictionary *configurations = manifest[@"UISceneConfigurations"];
    if (![configurations isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *role in configurations) {
        if ([role hasPrefix:@"CPTemplateApplication"] &&
            ![role isEqualToString:@"CPTemplateApplicationSceneSessionRoleApplication"]) {
            return YES;
        }
    }
    return NO;
}

/// True for a system app that opts *out* of the normal sandboxed container to
/// run under its own dedicated seatbelt profile (no-container, usually paired
/// with platform-application and a named entry in seatbelt-profiles). sandboxd
/// only grants that profile after verifying the binary's real Apple signature;
/// an ad-hoc ldid re-sign can't back that up and the process gets a
/// SANDBOX-namespace SIGKILL within milliseconds of every launch.
///
/// com.apple.private.security.system-application alone is deliberately NOT
/// checked here — Tips carries it and has been re-signed for months without
/// issue. What actually broke Photos was no-container plus its own
/// "MobileSlideShow" seatbelt-profiles entry; that comparison is what isolated
/// this signal. Getting this distinction right matters: over-blocking silently
/// leaves an app like Tips permanently un-bridgeable.
static BOOL CSHasDedicatedSandboxProfile(NSDictionary *entitlements) {
    if ([entitlements[@"platform-application"] boolValue]) return YES;
    if ([entitlements[@"com.apple.private.security.no-container"] boolValue]) return YES;
    NSArray *profiles = entitlements[@"seatbelt-profiles"];
    return [profiles isKindOfClass:NSArray.class] && profiles.count > 0;
}

#pragma mark - Patch / revert

static BOOL CSReregister(NSString *bundlePath) {
    return CSRun(@[ kUicache, @"-p", bundlePath ], nil) == 0;
}

/// Writes the two registration inputs CarPlay reads after the executable's
/// SBStarkCapable entitlement: the Stark launch mode and a CarPlay scene role
/// based on the app's normal window-scene configuration. This is also used to
/// repair an interrupted patch where signing succeeded before trustcache or
/// uicache failed.
static BOOL CSPrepareCarPlayInfo(NSString *infoPath, NSString *bundleID) {
    NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:infoPath] mutableCopy];
    if (!info) {
        CSLog("failed to read Info.plist for %s", bundleID.UTF8String);
        return NO;
    }
    info[@"SBStarkLaunchModes"] = @[ @"Default" ];

    NSMutableDictionary *manifest = [info[@"UIApplicationSceneManifest"] mutableCopy];
    NSMutableDictionary *configurations = [manifest[@"UISceneConfigurations"] mutableCopy];
    id defaultRole = configurations[@"UIWindowSceneSessionRoleApplication"];
    if (defaultRole && !configurations[@"UIWindowSceneSessionRoleCarPlay"]) {
        configurations[@"UIWindowSceneSessionRoleCarPlay"] = defaultRole;
        manifest[@"UISceneConfigurations"] = configurations;
        manifest[@"UIApplicationSupportsMultipleScenes"] = @YES;
        info[@"UIApplicationSceneManifest"] = manifest;
        CSLog("%s: added a native CarPlay window-scene role", bundleID.UTF8String);
    }

    if (![info writeToFile:infoPath atomically:YES]) {
        CSLog("failed to write Info.plist for %s", bundleID.UTF8String);
        return NO;
    }
    return YES;
}

typedef NS_ENUM(NSInteger, CSApplyPatchResult) {
    CSApplyPatchResultFailed = 0,
    /// The binary was re-signed (or already had been) — CSPatchStatusPatched.
    CSApplyPatchResultPatched,
    /// Untouched, and CSApp.m installs no bridge hooks either: real Apple-
    /// issued CarPlay entitlements plus more than one concurrent CarPlay
    /// scene (Waze). CSPatchStatusNative.
    CSApplyPatchResultNative,
    /// Untouched, but CSApp.m does bridge its one plain CarPlay scene: real
    /// Apple-issued CarPlay entitlements, single scene (YouTube Music).
    /// CSPatchStatusNativeBridged — CSCarKitPolicy.m must force
    /// launchUsingTemplateUI off for this one same as a patched app.
    CSApplyPatchResultNativeBridged,
};

/// outReason is set only for the refusal the Settings UI needs to explain
/// specifically (the dedicated-sandbox-profile case) — every other failure
/// falls back to the generic "see device log" message at the call site.
static CSApplyPatchResult CSApplyPatch(NSString *bundleID, NSString **outReason) {
    NSString *bundlePath = CSBundlePathForIdentifier(bundleID);
    if (!bundlePath) return CSApplyPatchResultFailed;

    // Before iOS 18 the app is admitted at runtime with its signature intact, so
    // there is nothing to do on disk — and doing it anyway is destructive. Report
    // NativeBridged: untouched bundle, but CSApp.m still bridges its CarPlay
    // scene and CSCarKitPolicy.m still forces template UI off, which is exactly
    // the shape of a runtime-admitted app.
    if (CSUsesRuntimeCarPlayAdmission()) {
        CSLog("%s: admitted at runtime on this iOS release — leaving the bundle "
              "untouched", bundleID.UTF8String);
        return CSApplyPatchResultNativeBridged;
    }

    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSString *executablePath = CSExecutablePath(bundlePath);

    // Reported separately: one message covering both conditions previously blamed
    // writability for what was really a failure to read CFBundleExecutable.
    if (!executablePath) {
        CSLog("cannot patch %s: could not read CFBundleExecutable from %s",
                bundleID.UTF8String, infoPath.UTF8String);
        return CSApplyPatchResultFailed;
    }
    // access() rather than -isWritableFileAtPath:, which reported "not writable"
    // for a path root can demonstrably write.
    if (access(infoPath.fileSystemRepresentation, W_OK) != 0) {
        CSLog("cannot patch %s: %s not writable (errno %d: %s)", bundleID.UTF8String,
                infoPath.UTF8String, errno, strerror(errno));
        return CSApplyPatchResultFailed;
    }
    if (access(executablePath.fileSystemRepresentation, W_OK) != 0) {
        CSLog("cannot patch %s: %s not writable (errno %d: %s)", bundleID.UTF8String,
                executablePath.UTF8String, errno, strerror(errno));
        return CSApplyPatchResultFailed;
    }

    NSDictionary *entitlements = CSReadEntitlements(executablePath);
    if (!entitlements) {
        CSLog("cannot read entitlements for %s", bundleID.UTF8String);
        return CSApplyPatchResultFailed;
    }
    if (CSHasNativeCarPlayCapability(entitlements)) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        if (CSInfoHasComplexNativeCarPlayScenes(info)) {
            CSLog("%s already has native CarPlay capability with multiple "
                  "concurrent scenes — leaving its signature and scenes "
                  "untouched entirely; CarKit admits it on its own",
                  bundleID.UTF8String);
            return CSApplyPatchResultNative;
        }
        CSLog("%s already has native CarPlay capability (single scene) — "
              "leaving its signature untouched; CarSurf bridges its scene "
              "instead of touching the binary", bundleID.UTF8String);
        return CSApplyPatchResultNativeBridged; // nothing to patch, and never re-sign this one
    }
    if (CSHasDedicatedSandboxProfile(entitlements)) {
        CSLog("refusing to patch %s: runs under its own dedicated sandbox profile "
              "(no-container/platform-application) — re-signing would strip the "
              "real Apple signature that profile depends on and crash it on "
              "every launch, same as Photos did", bundleID.UTF8String);
        if (outReason) {
            *outReason = @"This app runs under its own dedicated sandbox profile — "
                         @"patching it would crash it on every launch, so CarSurf "
                         @"refuses to. It cannot be bridged.";
        }
        return CSApplyPatchResultFailed;
    }
    if ([entitlements[@"SBStarkCapable"] boolValue]) {
        // A prior attempt can have changed this entitlement then failed before
        // the trustcache, Info.plist, or LaunchServices steps. Do not treat the
        // entitlement bit alone as success; complete (or fail) every remaining
        // prerequisite on every retry.
        if (!CSTrustExecutable(executablePath) || !CSTrustFrameworks(bundlePath)) {
            if (outReason) *outReason = @"CarSurf could not add this app or one of its "
                                        @"embedded frameworks to the jailbreak trustcache.";
            return CSApplyPatchResultFailed;
        }
        if (!CSPrepareCarPlayInfo(infoPath, bundleID) || !CSReregister(bundlePath)) {
            if (outReason) *outReason = @"CarSurf could not register this app's CarPlay "
                                        @"launch configuration with the system.";
            return CSApplyPatchResultFailed;
        }
        CSLog("%s repaired and verified as CarPlay-qualified", bundleID.UTF8String);
        return CSApplyPatchResultPatched;
    }

    // --- back up first, always ---------------------------------------------
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *backupDirectory = CSBackupDirectory(bundleID);
    [fileManager createDirectoryAtPath:backupDirectory withIntermediateDirectories:YES
                           attributes:nil error:NULL];

    NSString *infoBackup = [backupDirectory stringByAppendingPathComponent:@"Info.plist"];
    NSString *entitlementsBackup =
        [backupDirectory stringByAppendingPathComponent:@"entitlements.plist"];
    [fileManager removeItemAtPath:infoBackup error:NULL];
    if (![fileManager copyItemAtPath:infoPath toPath:infoBackup error:NULL]) {
        CSLog("refusing to patch %s: could not back up Info.plist", bundleID.UTF8String);
        return CSApplyPatchResultFailed;
    }
    [entitlements writeToFile:entitlementsBackup atomically:YES];

    // --- entitlement -------------------------------------------------------
    NSMutableDictionary *patchedEntitlements = [entitlements mutableCopy];
    patchedEntitlements[@"SBStarkCapable"] = @YES;
    NSString *temporary = CSScratchPath(@"entitlements-sign", @"plist");
    if (![patchedEntitlements writeToFile:temporary atomically:YES]) {
        CSLog("cannot patch %s: failed to write temporary entitlements at %s",
              bundleID.UTF8String, temporary.UTF8String);
        if (outReason) {
            *outReason = @"CarSurf could not write the temporary entitlement file. "
                         @"Open Live Patch Log for the path and error details.";
        }
        return CSApplyPatchResultFailed;
    }

    BOOL signed_ = CSSignWithEntitlements(executablePath, temporary);
    [fileManager removeItemAtPath:temporary error:NULL];
    if (!signed_) return CSApplyPatchResultFailed;

    // The main executable is now a platform process — see CSTrustFrameworks.
    if (!CSTrustFrameworks(bundlePath)) {
        if (outReason) *outReason = @"CarSurf could not add an embedded framework to "
                                    @"the jailbreak trustcache.";
        return CSApplyPatchResultFailed;
    }
    if (!CSPrepareCarPlayInfo(infoPath, bundleID) || !CSReregister(bundlePath)) {
        if (outReason) *outReason = @"CarSurf could not register this app's CarPlay "
                                    @"launch configuration with the system.";
        return CSApplyPatchResultFailed;
    }
    CSLog("qualified %s for CarPlay", bundleID.UTF8String);
    return CSApplyPatchResultPatched;
}

static void CSRevertPatch(NSString *bundleID) {
    // Nothing was ever patched here, and "reverting" would re-sign the binary —
    // which cannot restore Apple's original CMS signature and leaves the app
    // ad-hoc signed. On RootHide that is fatal: the trustcache refuses app
    // bundles, so the app stops launching entirely.
    if (CSUsesRuntimeCarPlayAdmission()) return;

    NSString *backupDirectory = CSBackupDirectory(bundleID);
    NSString *infoBackup = [backupDirectory stringByAppendingPathComponent:@"Info.plist"];
    NSString *entitlementsBackup =
        [backupDirectory stringByAppendingPathComponent:@"entitlements.plist"];

    NSString *bundlePath = CSBundlePathForIdentifier(bundleID);
    if (!bundlePath) return;
    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSString *executablePath = CSExecutablePath(bundlePath);

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if ([fileManager fileExistsAtPath:infoBackup]) {
        [fileManager removeItemAtPath:infoPath error:NULL];
        [fileManager copyItemAtPath:infoBackup toPath:infoPath error:NULL];
    }
    if (executablePath && [fileManager fileExistsAtPath:entitlementsBackup]) {
        CSSignWithEntitlements(executablePath, entitlementsBackup);
    }

    CSReregister(bundlePath);
    CSLog("reverted %s to its original signature and Info.plist", bundleID.UTF8String);
}

#pragma mark - Reconcile

static void CSRecordProtectedFailure(NSString *bundleID) {
    CSPatchLogAppend(@"========== PATCH %@ ==========", bundleID);
    CSLog("%s is protected and will not be modified", bundleID.UTF8String);
    CSPatchStateRecordFailure(bundleID, kCSProtectedPatchReason);
    CSPatchLogAppend(@"========== FAILED %@ ==========", bundleID);
}

/// Attempts one app and records a terminal result for every path. Settings
/// polls this per-app state, so even a refusal must be recorded as a failure
/// rather than merely written to the transcript.
static void CSAttemptAndRecordPatch(NSString *bundleID) {
    if ([CSProtectedBundleIdentifiers() containsObject:bundleID]) {
        CSRecordProtectedFailure(bundleID);
        return;
    }

    CSPatchLogAppend(@"========== PATCH %@ ==========", bundleID);
    NSString *reason = nil;
    CSApplyPatchResult result = CSApplyPatch(bundleID, &reason);
    NSString *version = CSAppVersion(bundleID);
    switch (result) {
        case CSApplyPatchResultPatched:
            CSPatchStateRecordSuccess(bundleID, version);
            CSPatchLogAppend(@"========== SUCCESS %@ ==========", bundleID);
            break;
        case CSApplyPatchResultNative:
            CSPatchStateRecordNative(bundleID, version);
            CSPatchLogAppend(@"========== NATIVE %@ ==========", bundleID);
            break;
        case CSApplyPatchResultNativeBridged:
            CSPatchStateRecordNativeBridged(bundleID, version);
            CSPatchLogAppend(@"========== NATIVE BRIDGED %@ ==========", bundleID);
            break;
        case CSApplyPatchResultFailed:
            CSPatchStateRecordFailure(bundleID, reason ?:
                @"patch attempt failed — open Live Patch Log in CarSurf Settings");
            CSPatchLogAppend(@"========== FAILED %@ ==========", bundleID);
            break;
    }
}

/// Mirrors the preferences to a path a sandboxed app can actually read.
///
/// An app sandbox refuses /var/mobile/Library/Preferences outright, so without
/// this file CSConfig finds nothing, every app tweak decides it is not enabled,
/// and the car scene is never bridged — the app reaches the CarPlay dashboard on
/// the strength of its on-disk patch alone and then renders a blank screen.
///
/// CSRelay.m does the same job from SpringBoard, but only from SpringBoard: a
/// fresh install that has not resprung yet has no relay at all, which is exactly
/// how the blank-screen failure was reproduced on RootHide. This daemon runs from
/// boot and re-runs on every preference change, so writing it here as well makes
/// the relay independent of SpringBoard's injection state.
static void CSWriteRelay(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!preferences) {
        CSLog("no preferences at %s; leaving relay untouched", kPrefsPath.UTF8String);
        return;
    }

    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:preferences
                                                             format:NSPropertyListBinaryFormat_v1_0
                                                            options:0
                                                              error:&error];
    if (!data) {
        CSLog("relay serialization failed: %s", error.localizedDescription.UTF8String);
        return;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    [fileManager createDirectoryAtPath:kStateDirectory
           withIntermediateDirectories:YES
                            attributes:@{ NSFilePosixPermissions : @(0755) }
                                 error:NULL];
    // The directory may predate this code (or have been created by the package's
    // postinst) with tighter permissions; an app that cannot traverse it cannot
    // read the relay no matter how the file itself is chmodded.
    chmod(kStateDirectory.fileSystemRepresentation, 0755);

    // Write-then-rename so a reader never observes a half-written file.
    NSString *temporary = [kRelayPath stringByAppendingPathExtension:@"tmp"];
    if (![data writeToFile:temporary atomically:NO]) {
        CSLog("relay write to %s failed", temporary.UTF8String);
        return;
    }
    chmod(temporary.fileSystemRepresentation, 0644);

    [fileManager removeItemAtPath:kRelayPath error:NULL];
    if (![fileManager moveItemAtPath:temporary toPath:kRelayPath error:&error]) {
        CSLog("relay rename failed: %s", error.localizedDescription.UTF8String);
        [fileManager removeItemAtPath:temporary error:NULL];
        return;
    }

    CSLog("relay updated at %s (%lu bytes)", kRelayPath.UTF8String,
          (unsigned long)data.length);
}

static void CSReconcile(void) {
    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    BOOL globallyEnabled = [preferences[@"enabled"] boolValue];

    NSMutableSet<NSString *> *desired = [NSMutableSet new];
    NSDictionary *apps = preferences[@"apps"];
    if (globallyEnabled && [apps isKindOfClass:NSDictionary.class]) {
        [apps enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, id entry, BOOL *stop) {
            if (![bundleID isKindOfClass:NSString.class]) return;
            if (![entry isKindOfClass:NSDictionary.class]) return;
            if (![entry[@"enabled"] boolValue]) return;
            if ([CSProtectedBundleIdentifiers() containsObject:bundleID]) {
                CSRecordProtectedFailure(bundleID);
                return;
            }
            [desired addObject:bundleID];
        }];
    }

    // Every desired bundle is re-verified on every reconcile pass, not just the
    // ones missing from the indicator. CSApplyPatch reads the binary's live
    // entitlements first and is a cheap no-op when SBStarkCapable is already
    // set, so this costs almost nothing when nothing changed on disk — but it is
    // the only way to notice an App Store update silently stripped the patch.
    for (NSString *bundleID in desired) {
        CSAttemptAndRecordPatch(bundleID);
    }

    NSArray<NSString *> *patched = CSPatchStateAllPatchedIdentifiers();
    for (NSString *bundleID in patched) {
        if ([desired containsObject:bundleID]) continue;
        CSRevertPatch(bundleID);
        CSPatchStateRemove(bundleID);
    }

    CSLog("reconciled: %lu enabled", (unsigned long)desired.count);
}

/// Handles a manual "Patch Now" request from Settings. This must write one
/// terminal result for each requested bundle and must not run a full reconcile:
/// the Settings screen is waiting on the selected app's state timestamp.
static void CSHandlePatchRequest(void) {
    NSArray<NSString *> *requested = CSPatchRequestTakeAll();
    if (requested.count == 0) return;
    CSLog("patch-now request for: %s", [requested componentsJoinedByString:@", "].UTF8String);

    NSDictionary *preferences = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    BOOL globallyEnabled = [preferences[@"enabled"] boolValue];
    NSDictionary *apps = preferences[@"apps"];
    for (NSString *bundleID in requested) {
        NSDictionary *entry = [apps isKindOfClass:NSDictionary.class] ? apps[bundleID] : nil;
        if (!globallyEnabled || ![entry isKindOfClass:NSDictionary.class] ||
            ![entry[@"enabled"] boolValue]) {
            NSString *reason = @"Enable this app in CarSurf before patching it.";
            CSPatchLogAppend(@"========== PATCH %@ ==========", bundleID);
            CSLog("refusing manual patch for %s: app is not enabled", bundleID.UTF8String);
            CSPatchStateRecordFailure(bundleID, reason);
            CSPatchLogAppend(@"========== FAILED %@ ==========", bundleID);
            continue;
        }
        CSAttemptAndRecordPatch(bundleID);
    }
    CSLog("manual patch complete: %lu requested", (unsigned long)requested.count);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CSPatchLogAppend(@"========== HELPER STARTED ==========");
        CSLog("helper started (uid %d)", getuid());

        [NSFileManager.defaultManager createDirectoryAtPath:kStateDirectory
                               withIntermediateDirectories:YES attributes:nil error:NULL];

        // Publish the app-readable config before patching anything: an app that
        // launches during a long reconcile should still find a current relay.
        CSWriteRelay();

        int reloadToken = 0;

        // Where admission happens at runtime there is nothing to patch, and the
        // daemon exists for one job only: writing the relay. It cannot simply be
        // dropped from the package — a sandboxed app cannot read the preferences
        // plist, and SpringBoard's own copy of this writer (CSRelay.m) fails on
        // RootHide, so without this process every app tweak reads enabled=0 and
        // renders a blank CarPlay screen. Registering no patch handlers also means
        // a stray "patch now" request from an older Settings build cannot touch a
        // bundle.
        if (CSUsesRuntimeCarPlayAdmission()) {
            CSLog("runtime admission release — relay only, no patching");
            notify_register_dispatch(kChangeNotification.UTF8String, &reloadToken,
                                     dispatch_get_main_queue(), ^(int t) {
                CSLog("preferences changed");
                CSWriteRelay();
            });
            dispatch_main();
            return 0;
        }

        // Reconcile once at load, so a change made while the daemon was down (or a
        // reboot) still converges.
        CSReconcile();

        notify_register_dispatch(kChangeNotification.UTF8String, &reloadToken,
                                 dispatch_get_main_queue(), ^(int t) {
            CSLog("preferences changed");
            CSWriteRelay();
            CSReconcile();
        });

        int patchNowToken = 0;
        notify_register_dispatch(CSPatchRequestNotification.UTF8String, &patchNowToken,
                                 dispatch_get_main_queue(), ^(int t) {
            CSHandlePatchRequest();
        });

        int clearLogToken = 0;
        notify_register_dispatch(CSPatchLogClearNotification.UTF8String,
                                 &clearLogToken, dispatch_get_main_queue(),
                                 ^(int t) {
            CSPatchLogClear();
        });

        dispatch_main();
    }
    return 0;
}
