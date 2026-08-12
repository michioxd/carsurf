#define CS_TAG "entitle"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"
#import <objc/message.h>
#import <ctype.h>

/// Selector-name fragments that identify a CarPlay *capability* getter. In
/// conservative mode (the default) only getters matching one of these are
/// forced to YES, which keeps unrelated booleans on the class — layout flags,
/// validation flags — behaving normally.
static const char *const kCapabilityFragments[] = {
    "audio", "navigation", "communication", "messaging", "voip", "calling",
    "parking", "charging", "fueling", "ordering", "driving", "task",
    "carplay", "dashboard", "entitle", "supported", "allowed", "capable",
    "enabled", "any",
};

static BOOL CSSelectorLooksLikeCapability(const char *name) {
    // Case-insensitive substring match; selectors are ASCII.
    char lowered[256];
    size_t length = strlen(name);
    if (length >= sizeof(lowered)) return NO;
    for (size_t i = 0; i <= length; i++) lowered[i] = (char)tolower((unsigned char)name[i]);

    for (size_t i = 0; i < sizeof(kCapabilityFragments) / sizeof(*kCapabilityFragments); i++) {
        if (strstr(lowered, kCapabilityFragments[i])) return YES;
    }
    return NO;
}

/// CARAppEntitlements does not publish which app it describes, so per-app
/// filtering at gate G1 is best-effort: try the obvious accessors, then scan
/// ivars for anything that can name a bundle. Returns nil when the owning app
/// cannot be determined, in which case the caller falls back to allowing the
/// capability (the app-side gate still decides what actually bridges).
static NSString *CSBundleIdentifierForEntitlements(id target) {
    if (!target) return nil;

    static const char *const kDirectSelectors[] = {
        "bundleIdentifier", "applicationIdentifier", "_bundleIdentifier",
    };
    for (size_t i = 0; i < sizeof(kDirectSelectors) / sizeof(*kDirectSelectors); i++) {
        SEL sel = sel_getUid(kDirectSelectors[i]);
        if (![target respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(target, sel);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }

    static const char *const kProxySelectors[] = {
        "applicationProxy", "_applicationProxy", "application",
    };
    for (size_t i = 0; i < sizeof(kProxySelectors) / sizeof(*kProxySelectors); i++) {
        SEL sel = sel_getUid(kProxySelectors[i]);
        if (![target respondsToSelector:sel]) continue;
        id proxy = ((id (*)(id, SEL))objc_msgSend)(target, sel);
        SEL identifier = sel_getUid("applicationIdentifier");
        if ([proxy respondsToSelector:identifier]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, identifier);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
        identifier = sel_getUid("bundleIdentifier");
        if ([proxy respondsToSelector:identifier]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, identifier);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }

    return nil;
}

void CSInstallEntitlementSpoof(void) {
    Class entitlements = CSLookupClass("CARAppEntitlements");
    if (!entitlements) {
        // Expected in SpringBoard, which does not load CarPlaySupport.
        CSVLog("CARAppEntitlements absent — skipping entitlement spoof");
        return;
    }

    // The default is deliberately conservative; the aggressive path exists because
    // Apple renames these getters between releases and a rename would otherwise
    // silently disable the tweak.
    BOOL aggressive = [[NSUserDefaults standardUserDefaults] boolForKey:@"CSAggressiveEntitlements"];

    __block NSUInteger patched = 0;
    __block NSUInteger skipped = 0;

    CSEnumerateBoolGetters(entitlements, ^BOOL(SEL sel, IMP original, IMP *outReplacement) {
        const char *name = sel_getName(sel);
        if (!aggressive && !CSSelectorLooksLikeCapability(name)) {
            skipped++;
            CSVLog("leaving -[CARAppEntitlements %s] alone", name);
            return NO;
        }

        // Capture `original` and `sel` so the replacement can defer to the real
        // implementation whenever spoofing is suppressed (see CSAppList.m,
        // which needs the truthful answer to compute the genuine app list).
        BOOL (*originalFn)(id, SEL) = (BOOL (*)(id, SEL))original;
        id block = ^BOOL(id target) {
            if (CSSpoofSuppressed()) return originalFn(target, sel);

            CSConfig *config = CSConfig.sharedConfig;
            if (!config.isEnabled) return originalFn(target, sel);

            // Already entitled for real: nothing to spoof.
            if (originalFn(target, sel)) return YES;

            NSString *bundleID = CSBundleIdentifierForEntitlements(target);
            if (bundleID) return [config isBundleEnabled:bundleID];

            // Owning app unknown — allow, and let CSAppList.m apply the
            // allowlist when it builds the dashboard's app list.
            return YES;
        };

        IMP replacement = imp_implementationWithBlock(block);
        if (!replacement) return NO;

        *outReplacement = replacement;
        patched++;
        return YES;
    });

    CSLog("entitlement spoof installed (%s): %lu getters patched, %lu left alone",
            aggressive ? "aggressive" : "conservative",
            (unsigned long)patched, (unsigned long)skipped);

    if (patched == 0) {
        CSLog("WARNING: no CARAppEntitlements getters matched. CarPlay's "
                "capability API has probably been renamed — set "
                "CSAggressiveEntitlements or run tools/carsurf-audit.");
    }
}
