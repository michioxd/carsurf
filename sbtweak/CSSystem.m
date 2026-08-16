#define CS_TAG "system"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import "CSPatchState.h"
#import <mach-o/loader.h>
#import <objc/runtime.h>

static BOOL CSIsSpringBoard(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
}

static void CSInstallCarPlayHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    CSTimingLog("hook installation begin");

    // iOS 16/17 admission: DashBoard's _proxyPassesInclusionFilter asks
    // LSBundleProxy for entitlements, so an app can be admitted at runtime with no
    // on-disk change. Required on RootHide, where the on-disk route is impossible —
    // jbctl refuses to trustcache anything under /var/containers/Bundle/Application,
    // so a re-signed app binary can never launch.
    //
    // Strictly version-gated. On iOS 18 CarKit never consults LaunchServices, so
    // these hooks cannot admit anything there — and they are not free to leave
    // installed: LSBundleProxy sits on hot Foundation paths, and an earlier
    // version of this file crash-looped SpringBoard into safe mode on 18.5.
    // Where they cannot help, they do not run.
    if (CSUsesRuntimeCarPlayAdmission()) {
        CSInstallSceneManifestSpoof();
    } else {
        CSLog("iOS 18+ — CarKit ignores LaunchServices; declaration-factory "
              "runtime admission is installed by the CarKit policy hook");
    }

    // iOS 18-era path; the two below are no-ops when their classes are
    // absent, so both generations are covered by one build.
    // Gate G1's admission check is +[CRCarPlayAppDeclaration requiredEntitlementKeys]:
    // an app qualifies by holding CARCapableApp, SBStarkCapable, or one of the
    // com.apple.developer.carplay-* entitlements. On iOS 18 the declaration
    // factory receives LSBundleInfoCachedValues; CSCarKitPolicy retries that
    // factory with a per-call proxy for enabled apps, so the bundle itself need
    // not be re-signed. The policy hook then promotes the resulting declaration.
    CSInstallCarKitPolicyHook();
    CSInstallEntitlementSpoof();
    CSInstallAppListFilter();
    CSTimingLog("hook installation end");
}

/// Fires for every image the process maps. CarPlaySupport is loaded lazily, well
/// after the tweak is injected, so this is where the hooks actually go in.
static void CSImageLoaded(const struct mach_header *header) {
    // CarKit on iOS 18, CarPlaySupport on older releases. Either arriving is the
    // cue to install.
    if (!objc_getClass("CRCarPlayAppPolicyEvaluator") && !objc_getClass("CARApplication") &&
        !objc_getClass("CRSIconLayoutService") && !objc_getClass("CRSIconLayoutController")) return;
    CSTimingLog("CarPlay framework image loaded — installing hooks");
    CSInstallCarPlayHooks();
}

__attribute__((constructor))
static void CSSystemInit(void) {
    @autoreleasepool {
        CSConfig *config = CSConfig.sharedConfig;

        // LaunchServices has the authoritative installed-app roster in
        // SpringBoard. Prune entries left behind by an uninstall before any
        // CarPlay roster admission or relay mirroring reads the config.
        if (CSIsSpringBoard()) {
            [config pruneMissingApplications];
        }

        CSTimingLog("system init begin process=%s enabled=%d allowlisted=%lu",
                NSProcessInfo.processInfo.processName.UTF8String,
                config.isEnabled,
                (unsigned long)config.enabledBundleIdentifiers.count);

        // The kill switch and CS_SAFE are honoured before a single hook goes in,
        // so a device that boot-loops can be recovered over SSH by touching
        // /var/mobile/Library/Preferences/.carsurf-disable.
        if (!config.isEnabled) {
            CSLog("inactive — no hooks installed");
            return;
        }

        if (CSIsSpringBoard()) {
            CSStartRelay();
        }

        if (objc_getClass("CRCarPlayAppPolicyEvaluator") || objc_getClass("CARApplication") ||
            objc_getClass("CRSIconLayoutService") || objc_getClass("CRSIconLayoutController")) {
            CSInstallCarPlayHooks();
        } else {
            objc_addLoadImageFunc(CSImageLoaded);
        }
        CSTimingLog("system init end");
    }
}
