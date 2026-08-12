#define CS_TAG "system"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <mach-o/loader.h>
#import <objc/runtime.h>

static BOOL CSIsSpringBoard(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
}

static void CSInstallCarPlayHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    // iOS 18-era path first; the two below are no-ops when their classes are
    // absent, so both generations are covered by one build.
    // Gate G1's admission check is +[CRCarPlayAppDeclaration requiredEntitlementKeys]:
    // an app qualifies by holding CARCapableApp, SBStarkCapable, or one of the
    // com.apple.developer.carplay-* entitlements. Those are code-signed and
    // evaluated at app-registration time, outside any process we inject into —
    // measured directly, by hooking every LSBundleProxy entitlement accessor and
    // observing that none is ever consulted for a non-CarPlay app. So no runtime
    // hook can add a bundle to the candidate roster, and the former manifest and
    // entitlement spoofs (CSSceneManifestSpoof.m, no longer built) were dead
    // code on hot Foundation paths. Qualification is now the installer's job; this
    // hook still promotes the policy once a declaration exists.
    CSInstallCarKitPolicyHook();
    CSInstallEntitlementSpoof();
    CSInstallAppListFilter();
}

/// Fires for every image the process maps. CarPlaySupport is loaded lazily, well
/// after the tweak is injected, so this is where the hooks actually go in.
static void CSImageLoaded(const struct mach_header *header) {
    // CarKit on iOS 18, CarPlaySupport on older releases. Either arriving is the
    // cue to install.
    if (!objc_getClass("CRCarPlayAppPolicyEvaluator") && !objc_getClass("CARApplication")) return;
    CSLog("CarPlay framework is now loaded — installing hooks");
    CSInstallCarPlayHooks();
}

__attribute__((constructor))
static void CSSystemInit(void) {
    @autoreleasepool {
        CSConfig *config = CSConfig.sharedConfig;

        CSLog("loaded into %s (enabled=%d, %lu app(s) allowlisted)",
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

        if (objc_getClass("CRCarPlayAppPolicyEvaluator") || objc_getClass("CARApplication")) {
            CSInstallCarPlayHooks();
        } else {
            objc_addLoadImageFunc(CSImageLoaded);
        }
    }
}
