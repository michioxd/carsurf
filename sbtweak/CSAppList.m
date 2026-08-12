#define CS_TAG "applist"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"
#import <objc/message.h>

// Once the entitlement spoof is in place, CarPlay's own queries return *every*
// installed app. That is not what we want on the dashboard, so these hooks run
// the query twice — once suppressed (the genuinely CarPlay-capable apps) and once
// spoofed (everything) — and keep the union of the genuine set with the user's
// allowlist.

static NSArray *(*orig_allInstalledApplications)(Class, SEL);
static NSDictionary *(*orig_allInstalledApplicationsByBundleIdentifier)(Class, SEL);

static NSString *CSBundleIdentifierOfCARApplication(id application) {
    static const char *const kSelectors[] = { "bundleIdentifier", "_bundleIdentifier" };
    for (size_t i = 0; i < sizeof(kSelectors) / sizeof(*kSelectors); i++) {
        SEL sel = sel_getUid(kSelectors[i]);
        if (![application respondsToSelector:sel]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(application, sel);
        if ([value isKindOfClass:NSString.class] && [value length]) return value;
    }

    SEL proxySel = sel_getUid("applicationProxy");
    if ([application respondsToSelector:proxySel]) {
        id proxy = ((id (*)(id, SEL))objc_msgSend)(application, proxySel);
        SEL identifier = sel_getUid("applicationIdentifier");
        if ([proxy respondsToSelector:identifier]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(proxy, identifier);
            if ([value isKindOfClass:NSString.class] && [value length]) return value;
        }
    }
    return nil;
}

/// Bundle identifiers CarPlay would have shown without the tweak.
static NSSet<NSString *> *CSGenuineBundleIdentifiers(Class cls, SEL sel) {
    NSMutableSet *genuine = [NSMutableSet new];
    CSRunWithSpoofSuppressed(^{
        NSArray *applications = orig_allInstalledApplications
                                    ? orig_allInstalledApplications(cls, sel) : nil;
        for (id application in applications) {
            NSString *bundleID = CSBundleIdentifierOfCARApplication(application);
            if (bundleID) [genuine addObject:bundleID];
        }
    });
    return genuine;
}

static BOOL CSShouldListBundle(NSString *bundleID, NSSet *genuine, CSConfig *config) {
    if (!bundleID) return YES;                       // can't classify: leave it be
    if ([genuine containsObject:bundleID]) return YES;
    return [config isBundleEnabled:bundleID];
}

static NSArray *cs_allInstalledApplications(Class self, SEL _cmd) {
    NSArray *spoofed = orig_allInstalledApplications(self, _cmd);

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return spoofed;

    NSSet *genuine = CSGenuineBundleIdentifiers(self, _cmd);

    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:spoofed.count];
    for (id application in spoofed) {
        NSString *bundleID = CSBundleIdentifierOfCARApplication(application);
        if (CSShouldListBundle(bundleID, genuine, config)) [filtered addObject:application];
    }

    CSVLog("app list: %lu installed -> %lu listed (%lu genuine CarPlay apps)",
             (unsigned long)spoofed.count, (unsigned long)filtered.count,
             (unsigned long)genuine.count);
    return filtered;
}

static NSDictionary *cs_allInstalledApplicationsByBundleIdentifier(Class self, SEL _cmd) {
    NSDictionary *spoofed = orig_allInstalledApplicationsByBundleIdentifier(self, _cmd);

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return spoofed;

    // Derive the genuine set from the array API when it exists; otherwise fall
    // back to re-running this same query suppressed.
    NSSet *genuine = nil;
    if (orig_allInstalledApplications) {
        genuine = CSGenuineBundleIdentifiers(self, sel_getUid("_allInstalledApplications"));
    } else {
        NSMutableSet *keys = [NSMutableSet new];
        CSRunWithSpoofSuppressed(^{
            NSDictionary *real = orig_allInstalledApplicationsByBundleIdentifier(self, _cmd);
            [keys addObjectsFromArray:real.allKeys];
        });
        genuine = keys;
    }

    NSMutableDictionary *filtered = [NSMutableDictionary dictionaryWithCapacity:spoofed.count];
    [spoofed enumerateKeysAndObjectsUsingBlock:^(NSString *bundleID, id application, BOOL *stop) {
        if (CSShouldListBundle(bundleID, genuine, config)) filtered[bundleID] = application;
    }];

    CSVLog("app map: %lu installed -> %lu listed", (unsigned long)spoofed.count,
             (unsigned long)filtered.count);
    return filtered;
}

void CSInstallAppListFilter(void) {
    Class application = CSLookupClass("CARApplication");
    if (!application) {
        CSVLog("CARApplication absent — skipping app list filter");
        return;
    }

    BOOL any = NO;
    any |= CSSwizzleClassMethod(application, @selector(_allInstalledApplications),
                                  (IMP)cs_allInstalledApplications,
                                  (IMP *)&orig_allInstalledApplications);
    any |= CSSwizzleClassMethod(application, @selector(_allInstalledApplicationsByBundleIdentifier),
                                  (IMP)cs_allInstalledApplicationsByBundleIdentifier,
                                  (IMP *)&orig_allInstalledApplicationsByBundleIdentifier);

    if (!any) {
        CSLog("WARNING: neither CARApplication app-list selector exists. Every "
                "installed app will reach the dashboard unfiltered — run "
                "tools/carsurf-audit to find the current selector names.");
    }
}
