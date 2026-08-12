#define CS_TAG "policy"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSPatchState.h"
#import "CSRuntime.h"
#import <objc/message.h>

// Gate G1 as it exists on iOS 18.x.
//
// The CARApplication / CARAppEntitlements pair that CarBridge-era tweaks patched
// is gone: CarPlaySupport.framework is now purely template *rendering* (all CPS*
// classes). App admission moved into CarKit, which asks
// -[CRCarPlayAppPolicyEvaluator effectivePolicyForAppDeclaration:] for a
// CRCarPlayAppPolicy per installed app. That policy object carries the decision:
//
//   -canDisplayOnCarScreen   whether the app may appear on the car display
//   -isCarPlayCapable        whether the app is considered a CarPlay app
//   -isCarPlaySupported      whether CarPlay support is available for it
//   -launchUsingTemplateUI   whether CarPlay should drive it as a template app
//
// Hooking the evaluator is a much better chokepoint than the old entitlement
// blanket-patch: the declaration hands us the exact bundle identifier, so the
// user's allowlist is applied precisely rather than best-effort.
//
// Promotion additionally requires CSPatchStateIsPatched: carsurf-helperd.m is
// what actually grants SBStarkCapable on disk, and its outcome — not the user's
// enabled toggle — is the ground truth for whether the entitlement is really
// there. An app can be enabled in preferences and still not be promoted if the
// daemon's last patch attempt failed, or (more commonly) if an App Store update
// silently re-signed the binary and stripped the entitlement since the daemon
// last checked. That keeps this hook from promoting a policy for a declaration
// CarKit was never going to build in the first place — see the tracing note
// below — and gives the Settings UI something concrete to show the user instead
// of the app just quietly not appearing.
//
// launchUsingTemplateUI is forced *off* for a bundle we actually patched: a
// bridged app has no CPTemplateApplicationSceneDelegate and cannot answer the
// template protocol, so telling CarPlay not to expect one is what lets the
// scene-role rewrite in CSSceneBridge.m present a plain UIWindowScene instead.
//
// A CSPatchStatusNative bundle must NOT go through CSPromotePolicy at all —
// it already has a real CPTemplateApplicationSceneDelegate and CSApp.m
// installs no bridge hooks for it, so forcing launchUsingTemplateUI off would
// tell CarKit to expect a plain window scene that never gets built: a blank
// CarPlay screen with neither the app's own template UI nor a bridge behind
// it. Confirmed the hard way on YouTube Music. Leave CarKit's own policy
// alone for these; it already admits them correctly on its own.

static NSString *CSDeclarationBundleIdentifier(id declaration) {
    SEL sel = @selector(bundleIdentifier);
    if (![declaration respondsToSelector:sel]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(declaration, sel);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

/// Sends a BOOL setter if the class actually has it, so a renamed setter on a
/// future release degrades to "that flag stays as CarPlay set it".
static BOOL CSSetPolicyFlag(id policy, const char *selectorName, BOOL value) {
    SEL sel = sel_getUid(selectorName);
    if (![policy respondsToSelector:sel]) {
        CSVLog("policy has no %s", selectorName);
        return NO;
    }
    ((void (*)(id, SEL, BOOL))objc_msgSend)(policy, sel, value);
    return YES;
}

static void CSPromotePolicy(id policy, NSString *bundleID) {
    if (!policy) return;

    BOOL display  = CSSetPolicyFlag(policy, "setCanDisplayOnCarScreen:", YES);
    BOOL capable  = CSSetPolicyFlag(policy, "setCarPlayCapable:", YES);
    BOOL supported = CSSetPolicyFlag(policy, "setCarPlaySupported:", YES);
    // Not a template app: see the note above.
    BOOL template = CSSetPolicyFlag(policy, "setLaunchUsingTemplateUI:", NO);

    CSLog("promoted %s (display=%d capable=%d supported=%d templateUI-off=%d)",
            bundleID.UTF8String, display, capable, supported, template);
}

#pragma mark - Hooks

static id (*orig_effectivePolicyForAppDeclaration)(id, SEL, id);

static id cs_effectivePolicyForAppDeclaration(id self, SEL _cmd, id declaration) {
    id policy = orig_effectivePolicyForAppDeclaration(self, _cmd, declaration);

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return policy;

    NSString *bundleID = CSDeclarationBundleIdentifier(declaration);
    if (!bundleID) {
        CSVLog("policy request with no resolvable bundle identifier");
        return policy;
    }

    CSVLog("policy request for %s", bundleID.UTF8String);
    if (![config isBundleEnabled:bundleID]) return policy;

    if (CSPatchStateIsPatched(bundleID) || CSPatchStateIsNativeBridged(bundleID)) {
        // Same requirement either way: CSApp.m is bridging this app's scene —
        // re-signed or not — so CarKit needs to be told not to expect a
        // template delegate. See CSPatchStatusNativeBridged.
        CSPromotePolicy(policy, bundleID);
    } else if (CSPatchStateIsNative(bundleID)) {
        // Leave CarKit's own policy untouched. It already admits this app and
        // already set launchUsingTemplateUI correctly for its real
        // CPTemplateApplicationSceneDelegate; forcing that off here — which
        // this hook used to do for every enabled bundle, native or not — left
        // CarKit expecting a template UI from an app CSApp.m does not bridge
        // (multiple concurrent CarPlay scenes — see CSPatchStatusNative).
        // Net effect was a blank CarPlay screen for a genuinely-supported app.
        CSVLog("%s is native CarPlay (multi-scene) — leaving CarKit's own "
               "policy in place", bundleID.UTF8String);
    } else {
        CSVLog("%s is enabled but not patched — not promoting", bundleID.UTF8String);
    }

    return policy;
}

static id (*orig_effectivePolicyInVehicle)(id, SEL, id, id);

static id cs_effectivePolicyInVehicle(id self, SEL _cmd, id declaration, id certificateSerial) {
    id policy = orig_effectivePolicyInVehicle(self, _cmd, declaration, certificateSerial);

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return policy;

    NSString *bundleID = CSDeclarationBundleIdentifier(declaration);
    if (!bundleID) return policy;

    CSVLog("in-vehicle policy request for %s", bundleID.UTF8String);
    if ([config isBundleEnabled:bundleID] &&
        (CSPatchStateIsPatched(bundleID) || CSPatchStateIsNativeBridged(bundleID))) {
        CSPromotePolicy(policy, bundleID);
    }

    return policy;
}

#pragma mark - Declaration tracing

// Promoting a policy is not sufficient on its own: CarPlay only asks for a policy
// for apps that already have a CRCarPlayAppDeclaration, and declarations are
// built upstream from CarPlay's Info.plist keys. Nothing in CarKit produces them,
// so this records the call stack for the first declaration in the process to name
// the producer. Verbose logging only, once per process — a full backtrace per app
// would bury the log.

static void (*orig_setBundleIdentifier)(id, SEL, NSString *);

static void cs_setBundleIdentifier(id self, SEL _cmd, NSString *bundleID) {
    orig_setBundleIdentifier(self, _cmd, bundleID);

    if (!CSVerboseEnabled()) return;

    static BOOL logged = NO;
    if (logged) {
        CSVLog("declaration built for %s", bundleID.UTF8String);
        return;
    }
    logged = YES;

    CSLog("first declaration built for %s — producer backtrace:", bundleID.UTF8String);
    for (NSString *frame in NSThread.callStackSymbols) {
        CSLog("    %s", frame.UTF8String);
    }
}

static void CSInstallDeclarationTrace(void) {
    Class declaration = CSLookupClass("CRCarPlayAppDeclaration");
    if (!declaration) return;

    CSSwizzleInstanceMethod(declaration, @selector(setBundleIdentifier:),
                              (IMP)cs_setBundleIdentifier,
                              (IMP *)&orig_setBundleIdentifier);
}

#pragma mark - Install

void CSInstallCarKitPolicyHook(void) {
    Class evaluator = CSLookupClass("CRCarPlayAppPolicyEvaluator");
    if (!evaluator) {
        CSVLog("CRCarPlayAppPolicyEvaluator absent — not an iOS 18-era CarKit");
        return;
    }

    BOOL plain = CSSwizzleInstanceMethod(
        evaluator, @selector(effectivePolicyForAppDeclaration:),
        (IMP)cs_effectivePolicyForAppDeclaration,
        (IMP *)&orig_effectivePolicyForAppDeclaration);

    BOOL inVehicle = CSSwizzleInstanceMethod(
        evaluator, @selector(effectivePolicyForAppDeclaration:inVehicleWithCertificateSerial:),
        (IMP)cs_effectivePolicyInVehicle,
        (IMP *)&orig_effectivePolicyInVehicle);

    CSInstallDeclarationTrace();

    CSLog("CarKit policy hook installed (plain=%d, inVehicle=%d)", plain, inVehicle);

    if (!plain && !inVehicle) {
        CSLog("WARNING: neither policy selector exists; apps will not reach the "
                "dashboard. Run carsurf-classes --methods CRCarPlayAppPolicyEvaluator.");
    }
}
