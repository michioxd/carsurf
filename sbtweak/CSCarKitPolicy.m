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

/// Defined with the runtime-admission hooks below; the policy hooks are declared
/// first because CarKit installs them in that order.
static BOOL CSIsRuntimeAdmitted(NSString *bundleID);

/// Where runtime admission may install.
///
/// Both SpringBoard and CarPlay.app build their own declarations — CarPlay.app
/// is the one whose policy decisions reach the dashboard, so admitting only in
/// SpringBoard produces a declaration nobody asks about, which is exactly what
/// happened first time round.
///
/// carkitd is excluded by name and must stay that way: it negotiates the CarPlay
/// link, and an earlier build that hooked a hot CoreServices accessor there put
/// the head unit into an endless "connecting" retry loop. The hook installed
/// here is a single low-frequency CarKit class method, not a hot path, but the
/// daemon gets nothing regardless.
static BOOL CSMayInstallRuntimeAdmission(void) {
    NSString *process = NSProcessInfo.processInfo.processName;
    return [process isEqualToString:@"SpringBoard"] ||
           [process isEqualToString:@"CarPlay"] ||
           [process isEqualToString:@"CarPlayTemplateUIHost"] ||
           [process isEqualToString:@"carkitd"];
}

/// carkitd is observed, never altered. SpringBoard admits FPT Play on every
/// enumeration and the dashboard still does not list it, while CarPlay.app never
/// calls the factory at all (0 calls against SpringBoard's 70) — so something
/// else owns the list the dashboard uses, and carkitd is the remaining
/// candidate. Confirming that before changing a return value there is worth one
/// respring: a hot-path hook in this daemon already cost a CarPlay link tonight.
static BOOL CSRuntimeAdmissionIsObserveOnly(void) {
    return [NSProcessInfo.processInfo.processName isEqualToString:@"carkitd"];
}

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

    if (CSPatchStateIsPatched(bundleID) || CSPatchStateIsNativeBridged(bundleID) ||
        CSIsRuntimeAdmitted(bundleID)) {
        // Same requirement either way: CSApp.m is bridging this app's scene —
        // re-signed, runtime-admitted, or not — so CarKit needs to be told not
        // to expect a template delegate. See CSPatchStatusNativeBridged.
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
        (CSPatchStateIsPatched(bundleID) || CSPatchStateIsNativeBridged(bundleID) ||
         CSIsRuntimeAdmitted(bundleID))) {
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

#pragma mark - Runtime admission (gate G0)

// Qualifying an app without touching its bundle.
//
// The on-disk patch grants SBStarkCapable by re-signing the binary, which
// invalidates Apple's signature and therefore needs a trustcache entry to stay
// launchable. That entry is what makes the app a platform binary, and a platform
// binary cannot register a mach exception port — so every app carrying an
// in-process crash reporter is SIGKILLed on launch (EXC_GUARD /
// SET_EXCEPTION_BEHAVIOR). Measured on FPT Play: even its *untouched*
// Apple-signed binary dies the moment its cdhash is trusted.
//
// CSSystem.m used to assert that runtime admission is impossible on iOS 18
// because entitlements are read at app-registration time. That was measured
// against LSBundleProxy accessors, which is not the path CarKit uses. A probe
// showed CarKit building every declaration inside SpringBoard, which CSSystem is
// injected into:
//
//   +[CRCarPlayAppDeclaration declarationForBundleIdentifier:info:entitlements:]
//     -> declaration for an app holding one of +requiredEntitlementKeys
//     -> nil for everything else            (492 calls, 66 admitted, on 18.5)
//
// So the gate is reachable, and answering it is enough: the entitlements
// argument is an LSBundleInfoCachedValues, and CarKit asks it for each required
// key. Rather than synthesise a declaration — which would mean guessing at
// fields CarKit populates itself — the original factory is re-run with a
// stand-in for that one argument, so CarKit builds a declaration it is entirely
// happy with.
//
// The stand-in is a proxy, NOT a swizzle. An earlier version of this file hooked
// -[LSBundleInfoCachedValues objectForKey:] and friends, which put an extra
// frame on a hot CoreServices path inside carkitd — the daemon that negotiates
// the CarPlay link — and the head unit dropped into an endless "connecting"
// retry loop. That is the same trap CSSceneManifestSpoof.m documents for
// LSBundleProxy. Nothing here patches a system class: the substitution exists
// only on the argument we ourselves pass to the retry, so no other caller in any
// process can reach it.

static NSString *const kCSRuntimeAdmissionKey = @"SBStarkCapable";

/// Forwards every message to the real entitlements object except a lookup of the
/// one key that decides CarPlay admission. NSProxy rather than a subclass so
/// that -isKindOfClass:, -respondsToSelector: and any CarKit type check are
/// answered by the genuine object.
@interface CSAdmittingEntitlements : NSProxy
@property (nonatomic, strong) id target;
@end

@implementation CSAdmittingEntitlements

- (instancetype)initWithTarget:(id)target {
    _target = target;
    return self;
}

- (BOOL)cs_isAdmissionKey:(id)key {
    return [key isKindOfClass:NSString.class] && [key isEqualToString:kCSRuntimeAdmissionKey];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [_target methodSignatureForSelector:sel];
}

// LSBundleInfoCachedValues vends six different objectForKey: shapes
// (-ofClass:, -ofType:, -checkingKeyClass:checkingValueClass:, …) and CarKit
// picks one of them. Overriding them individually means guessing right, and
// guessing wrong is silent — the message forwards to the real object and the
// app is simply not admitted. Intercepting here covers every shape regardless
// of arity, because they all take the key first and return an object.
- (void)forwardInvocation:(NSInvocation *)invocation {
    const char *name = sel_getName(invocation.selector);

    // Census: which selectors does CarKit actually send the entitlements object?
    // Answering the wrong one is silent — the message forwards and the app is
    // simply not admitted — so this records each distinct selector once.
    static NSMutableSet *seen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
    NSString *selectorName = @(name);
    @synchronized(seen) {
        if (![seen containsObject:selectorName]) {
            [seen addObject:selectorName];
            CSLog("stand-in received -%s", name);
        }
    }

    // Measured: CarKit asks -boolForKey: and -objectForKey:ofClass:. The two
    // differ in return type — a raw BOOL and an object — so the return value has
    // to match the signature the caller expects, exactly as
    // CSSceneManifestSpoof.m warns.
    BOOL isObjectLookup = strncmp(name, "objectForKey:", strlen("objectForKey:")) == 0;
    BOOL isBoolLookup = strcmp(name, "boolForKey:") == 0;

    if (isObjectLookup || isBoolLookup) {
        __unsafe_unretained id key = nil;
        [invocation getArgument:&key atIndex:2];
        if ([self cs_isAdmissionKey:key]) {
            CSLog("admission key answered via -%s", name);
            if (isBoolLookup) {
                BOOL affirmative = YES;
                [invocation setReturnValue:&affirmative];
            } else {
                id affirmative = @YES;
                [invocation setReturnValue:&affirmative];
            }
            return;
        }
    }
    [invocation invokeWithTarget:_target];
}

@end

/// Bundles admitted at runtime this boot. The policy hook promotes these exactly
/// as it promotes a patched bundle — from CarKit's point of view they are
/// indistinguishable, and CSApp.m bridges both the same way.
static NSMutableSet<NSString *> *CSRuntimeAdmittedBundles(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet new]; });
    return set;
}

static BOOL CSIsRuntimeAdmitted(NSString *bundleID) {
    if (!bundleID) return NO;
    @synchronized(CSRuntimeAdmittedBundles()) {
        return [CSRuntimeAdmittedBundles() containsObject:bundleID];
    }
}

static void CSRecordRuntimeAdmission(NSString *bundleID) {
    @synchronized(CSRuntimeAdmittedBundles()) {
        [CSRuntimeAdmittedBundles() addObject:bundleID];
    }
}

// --- The gate ------------------------------------------------------------------

static BOOL CSShouldAdmitAtRuntime(NSString *bundleID) {
    if (bundleID.length == 0) return NO;

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return NO;
    if (![config isBundleEnabled:bundleID]) return NO;

    // A natively-capable app already has its own declaration and its own
    // template delegate; admitting it again would be a no-op at best. Only
    // reachable when CarKit returned nil, but cheap insurance.
    if (CSPatchStateIsNative(bundleID)) return NO;

    return YES;
}

static id (*orig_declarationForBundleInfoEnts)(Class, SEL, id, id, id);
static id cs_declarationForBundleInfoEnts(Class self, SEL _cmd, id bundleID, id info,
                                          id entitlements) {
    id result = orig_declarationForBundleInfoEnts(self, _cmd, bundleID, info, entitlements);

    // One line per process, so "no admissions" can be told apart from "the
    // enumeration ran before this hook was installed" — the two look identical
    // in the log otherwise, and they need opposite fixes.
    static BOOL sawFirstCall = NO;
    if (!sawFirstCall) {
        sawFirstCall = YES;
        CSLog("declaration factory reached (first call: %s -> %s)",
              [bundleID description].UTF8String, result ? "declaration" : "nil");
    }

    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;

    // Bounded to the user's allowlist — a handful of apps, not the ~490 the
    // enumeration walks — so this stays readable while the path is being
    // brought up.
    if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
        CSLog("enumerated enabled bundle %s -> %s", identifier.UTF8String,
              result ? "declaration" : "nil");
    }

    if (CSRuntimeAdmissionIsObserveOnly()) return result;

    if (result) return result;
    if (!CSShouldAdmitAtRuntime(identifier)) {
        if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
            CSLog("not admitting %s (suppressed=%d globalEnabled=%d native=%d)",
                  identifier.UTF8String, CSSpoofSuppressed(),
                  CSConfig.sharedConfig.isEnabled, CSPatchStateIsNative(identifier));
        }
        return result;
    }

    CSAdmittingEntitlements *standIn =
        [[CSAdmittingEntitlements alloc] initWithTarget:entitlements];
    id admitted = orig_declarationForBundleInfoEnts(self, _cmd, bundleID, info, standIn);

    if (!admitted) {
        CSLog("runtime admission produced no declaration for %s — CarKit did not "
              "consult the stand-in, or wants more than the entitlement",
              identifier.UTF8String);
        return result;
    }

    CSRecordRuntimeAdmission(identifier);
    CSLog("%s admitted at runtime — no on-disk patch required",
          identifier.UTF8String);
    return admitted;
}

static void CSInstallRuntimeAdmission(Class declaration) {
    if (!CSMayInstallRuntimeAdmission()) {
        CSVLog("runtime admission not installed in this process");
        return;
    }

    BOOL factory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:info:entitlements:),
        (IMP)cs_declarationForBundleInfoEnts, (IMP *)&orig_declarationForBundleInfoEnts);

    if (!factory) {
        CSLog("WARNING: declarationForBundleIdentifier:info:entitlements: is absent; "
              "runtime admission unavailable, falling back to the on-disk patch");
        return;
    }

    CSLog("runtime admission installed in %s (%s, no system class patched)", NSProcessInfo.processInfo.processName.UTF8String, CSRuntimeAdmissionIsObserveOnly() ? "observe-only" : "admitting");
}

static void CSInstallDeclarationTrace(void) {
    Class declaration = CSLookupClass("CRCarPlayAppDeclaration");
    if (!declaration) return;

    CSSwizzleInstanceMethod(declaration, @selector(setBundleIdentifier:),
                              (IMP)cs_setBundleIdentifier,
                              (IMP *)&orig_setBundleIdentifier);

    CSInstallRuntimeAdmission(declaration);
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
