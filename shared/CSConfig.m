#define CS_TAG "config"

#import "CSConfig.h"
#import "CSLog.h"
#import <dlfcn.h>
#import <notify.h>

static NSString *const kPrefsPath =
    @"/var/mobile/Library/Preferences/com.pavunato.carsurf.plist";
static NSString *const kKillSwitchPath =
    @"/var/mobile/Library/Preferences/.carsurf-disable";
/// SpringBoard mirrors the effective config to a relay file for processes whose
/// sandbox refuses the Preferences directory.
///
/// Location matters more than permissions here: both the preference plist and the
/// old /var/tmp relay were already mode 0644 and still unreadable from an app,
/// because the app sandbox — not the filesystem — was refusing them. The jailbreak
/// root is the one place known to be reachable, since every tweak dylib is itself
/// loaded out of /var/jb/Library/MobileSubstrate inside these same sandboxes.
/// /var/tmp is kept last for compatibility with older installs.
static NSString *const kRelayPaths[] = {
    @"/var/jb/Library/CarSurf/relay.plist",
    @"/Library/CarSurf/relay.plist",
    @"/var/tmp/.carsurf-relay.plist",
};

static NSString *const kChangeNotification = @"com.pavunato.carsurf/reload";

#pragma mark - Options

@implementation CSAppOptions

- (instancetype)initWithBundleIdentifier:(NSString *)bundleID
                              dictionary:(NSDictionary *)dict {
    if ((self = [super init])) {
        _bundleIdentifier = [bundleID copy];

        NSInteger mode = [dict[@"mode"] integerValue];
        _mode = (mode >= CSBridgeModeAuto && mode <= CSBridgeModeMirror)
                    ? (CSBridgeMode)mode
                    : CSBridgeModeAuto;

        CGFloat scale = dict[@"scale"] ? [dict[@"scale"] doubleValue] : 1.0;
        if (!isfinite(scale)) scale = 1.0;
        _scale = MIN(MAX(scale, 0.5), 2.0);

        // iPhone spoofing helps far more apps than it hurts, so it remains the
        // default. Read the former boolean when upgrading an existing plist.
        if (dict[@"idiomMode"]) {
            NSInteger idiomMode = [dict[@"idiomMode"] integerValue];
            _idiomMode = (idiomMode >= CSIdiomModeAuto &&
                          idiomMode <= CSIdiomModePad)
                             ? (CSIdiomMode)idiomMode
                             : CSIdiomModePhone;
        } else if (dict[@"forceIdiomPhone"]) {
            _idiomMode = [dict[@"forceIdiomPhone"] boolValue]
                             ? CSIdiomModePhone : CSIdiomModeAuto;
        } else {
            _idiomMode = CSIdiomModePhone;
        }
        _spoofMainScreen = [dict[@"spoofMainScreen"] boolValue];
        if (dict[@"layoutMode"]) {
            NSInteger layoutMode = [dict[@"layoutMode"] integerValue];
            _layoutMode = (layoutMode >= CSLayoutModeAuto &&
                           layoutMode <= CSLayoutModeVertical)
                              ? (CSLayoutMode)layoutMode
                              : CSLayoutModeHorizontal;
        } else {
            // Compatibility with the short-lived boolean Vertical option.
            _layoutMode = [dict[@"portraitLayout"] boolValue]
                              ? CSLayoutModeVertical
                              : CSLayoutModeHorizontal;
        }
        _allowIndependentRotation = [dict[@"allowIndependentRotation"] boolValue];
    }
    return self;
}

@end

#pragma mark - Config

@implementation CSConfig {
    NSDictionary *_root;
    NSMutableDictionary<NSString *, CSAppOptions *> *_optionsCache;
    dispatch_queue_t _queue;
    BOOL _safeMode;
}

+ (NSString *)changeNotificationName { return kChangeNotification; }

+ (CSConfig *)sharedConfig {
    static CSConfig *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[CSConfig alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.pavunato.carsurf.config", DISPATCH_QUEUE_CONCURRENT);
        _optionsCache = [NSMutableDictionary new];

        const char *safe = getenv("CS_SAFE");
        _safeMode = (safe && *safe && *safe != '0');
        if (_safeMode) CSLog("CS_SAFE set — tweak inactive in this process");

        [self grantPreferencesAccessIfNeeded];
        [self reload];
        [self observeChanges];
    }
    return self;
}

/// App sandboxes deny the shared Preferences directory. libSandy, when present,
/// grants it; without libSandy we fall back to the relay file in -loadRoot.
- (void)grantPreferencesAccessIfNeeded {
    if (getuid() == 0) return; // SpringBoard / CarPlay.app: already unrestricted

    static const char *candidates[] = {
        "/var/jb/usr/lib/libsandy.dylib",
        "/usr/lib/libsandy.dylib",
        "/var/jb/usr/lib/libSandy.dylib",
    };
    for (size_t i = 0; i < sizeof(candidates) / sizeof(*candidates); i++) {
        void *handle = dlopen(candidates[i], RTLD_LAZY);
        if (!handle) continue;
        int (*applyProfile)(const char *) = dlsym(handle, "libSandy_applyProfile");
        if (applyProfile) {
            int result = applyProfile("SystemGroupContainers");
            CSVLog("libSandy_applyProfile -> %d (%s)", result, candidates[i]);
        }
        return;
    }
    CSVLog("libSandy unavailable; will try the relay file");
}

- (void)observeChanges {
    int token = 0;
    notify_register_dispatch(kChangeNotification.UTF8String, &token,
                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                             ^(int t) { [self reload]; });
}

- (NSDictionary *)loadRoot {
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:kPrefsPath];
    for (size_t i = 0; i < sizeof(kRelayPaths) / sizeof(*kRelayPaths); i++) {
        [candidates addObject:kRelayPaths[i]];
    }

    for (NSString *path in candidates) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict) {
            // Logged once, unconditionally: "config unreadable" presents as the
            // tweak silently doing nothing, which cost a long debugging detour.
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                CSLog("config loaded from %s (%lu keys)", path.UTF8String,
                        (unsigned long)dict.count);
            });
            return dict;
        }
    }

    static dispatch_once_t onceFailed;
    dispatch_once(&onceFailed, ^{
        CSLog("no readable config (tried %lu paths) — tweak inactive here",
                (unsigned long)candidates.count);
    });
    return @{};
}

- (void)reload {
    NSDictionary *root = [self loadRoot];
    BOOL killed = [[NSFileManager defaultManager] fileExistsAtPath:kKillSwitchPath];
    if (killed) CSLog("kill switch present at %s", kKillSwitchPath.UTF8String);

    dispatch_barrier_sync(_queue, ^{
        _root = killed ? @{} : root;
        [_optionsCache removeAllObjects];
    });
}

- (BOOL)isEnabled {
    if (_safeMode) return NO;
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        // Absent key means "not configured yet" -> off, so a fresh install is
        // inert until the user opts in.
        enabled = [_root[@"enabled"] boolValue];
    });
    return enabled;
}

- (NSArray<NSString *> *)enabledBundleIdentifiers {
    __block NSArray *result = @[];
    dispatch_sync(_queue, ^{
        NSDictionary *apps = _root[@"apps"];
        if (![apps isKindOfClass:NSDictionary.class]) return;
        NSMutableArray *ids = [NSMutableArray new];
        [apps enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] &&
                [value isKindOfClass:NSDictionary.class] &&
                [value[@"enabled"] boolValue]) {
                [ids addObject:key];
            }
        }];
        result = ids;
    });
    return result;
}

- (BOOL)isBundleEnabled:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0 || !self.isEnabled) return NO;
    __block BOOL enabled = NO;
    dispatch_sync(_queue, ^{
        NSDictionary *apps = _root[@"apps"];
        NSDictionary *entry = [apps isKindOfClass:NSDictionary.class]
                                  ? apps[bundleIdentifier] : nil;
        enabled = [entry isKindOfClass:NSDictionary.class] && [entry[@"enabled"] boolValue];
    });
    return enabled;
}

- (CSAppOptions *)optionsForBundle:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) bundleIdentifier = @"";
    __block CSAppOptions *cached = nil;
    dispatch_sync(_queue, ^{ cached = _optionsCache[bundleIdentifier]; });
    if (cached) return cached;

    // Per-app values win; anything the user did not override per app comes from
    // the global defaults, so the prefs UI can expose one set of sliders that
    // applies everywhere and still allow a single app to deviate.
    __block NSMutableDictionary *merged = [NSMutableDictionary new];
    dispatch_sync(_queue, ^{
        NSDictionary *defaults = _root[@"defaults"];
        if ([defaults isKindOfClass:NSDictionary.class]) [merged addEntriesFromDictionary:defaults];

        NSDictionary *apps = _root[@"apps"];
        if ([apps isKindOfClass:NSDictionary.class]) {
            id candidate = apps[bundleIdentifier];
            if ([candidate isKindOfClass:NSDictionary.class]) {
                [merged addEntriesFromDictionary:candidate];
            }
        }
    });

    CSAppOptions *options = [[CSAppOptions alloc] initWithBundleIdentifier:bundleIdentifier
                                                                   dictionary:merged];
    dispatch_barrier_async(_queue, ^{ _optionsCache[bundleIdentifier] = options; });
    return options;
}

@end
