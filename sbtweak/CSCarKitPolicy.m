#define CS_TAG "policy"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSPatchState.h"
#import "CSRuntime.h"
#import "CSAppFilter.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <notify.h>
#import <UIKit/UIKit.h>

static __strong id gLastVehicleIdentifier;
static __strong id gLastSBSIconService;
static __strong id gLastSBSIconVehicleIdentifier;
// The vehicle identifier CRSIconLayoutService actually uses on setIconState:/
// fetchIconStateForVehicleID: (a per-vehicle UUID string on iOS 18.5). Captured
// from those hooks so the live hiddenIcons sync can address the same vehicle.
static __strong id gLastIconLayoutVehicleID;
// The most recent NON-empty CRSIconLayoutState we saw fetched or written. Used to
// reject the degenerate 0-icon state DashBoard writes during connect churn, which
// is what emptied the Settings > Customize list.
static __strong id gLastGoodIconState;
static NSUInteger gLastGoodIconCount;
// Keep the last non-degenerate state per vehicle. DashBoard can issue an empty
// setState during connect/relaunch before asking for the state it will use to
// populate Customize; a single process-wide fallback could accidentally serve
// another vehicle's layout.
static NSMutableDictionary<NSString *, id> *gLastGoodIconStates;

// Cache of the synthetic DBApplicationInfo objects Carsurf injects into the
// CarPlay roster for enabled-but-filtered apps. Building one walks LaunchServices
// and constructs a CarPlay declaration, which is expensive; the dashboard calls
// allInstalledApplications on nearly every layout pass, so reconstructing them
// per call rebuilt every enabled app's declaration on the main thread and made
// animations hitch (and the whole grid re-animate on enable). Build once, reuse
// until the enabled set changes or the library is invalidated.
static NSMutableDictionary<NSString *, id> *gExpandedRosterCache;
static id gExpandedRosterCacheLock;
// Permanent strong references to every synthetic DBApplicationInfo we ever
// inject into the CarPlay roster. DashBoard keeps its own (non-retaining or
// unsafe) references to these entries while it resolves the icon-layout state;
// freeing them on cache invalidation left those references dangling and CarPlay
// crashed later with EXC_BAD_ACCESS / PAC failure in
// -[DBIconLayoutVehicleDataProvider getIconStateWithCompletion:]. Pinning them
// alive for the process lifetime removes the use-after-free. The set is tiny
// (one entry per enabled app), so the leak is deliberate and bounded.
static NSMutableArray *gPinnedRosterInfos;
static void CSInvalidateExpandedRosterCache(void) {
    if (!gExpandedRosterCache) return;
    @synchronized (gExpandedRosterCacheLock) {
        [gExpandedRosterCache removeAllObjects];
    }
}

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
static BOOL CSRuntimePolicyEligible(NSString *bundleID);
static void CSLogAdmittedDeclarationShape(id declaration, NSString *bundleID);

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
/// candidate. Confirming that before changing a return value is worth one
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
    static BOOL loggedFirstPolicy;
    static BOOL loggedFirstPolicyEnd;
    if (!loggedFirstPolicy) {
        loggedFirstPolicy = YES;
        CSTimingLog("first effectivePolicyForAppDeclaration begin");
    }
    id policy = orig_effectivePolicyForAppDeclaration(self, _cmd, declaration);
    if (!loggedFirstPolicyEnd) {
        loggedFirstPolicyEnd = YES;
        CSTimingLog("first effectivePolicyForAppDeclaration original returned");
    }

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
        CSRuntimePolicyEligible(bundleID)) {
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
    static BOOL loggedFirstInVehicle;
    static BOOL loggedFirstInVehicleEnd;
    if (!loggedFirstInVehicle) {
        loggedFirstInVehicle = YES;
        CSTimingLog("first effectivePolicyInVehicle begin");
    }
    if (certificateSerial && certificateSerial != [NSNull null]) {
        // CarKit supplies the vehicle certificate serial on every in-vehicle
        // policy query. It is also the identifier accepted by CRS icon-state
        // APIs when the service's private connection table is empty.
        gLastVehicleIdentifier = certificateSerial;
        CSLog("CarPlay in-vehicle certificate serial observed %s",
              [[certificateSerial description] UTF8String]);
    }
    id policy = orig_effectivePolicyInVehicle(self, _cmd, declaration, certificateSerial);
    if (!loggedFirstInVehicleEnd) {
        loggedFirstInVehicleEnd = YES;
        CSTimingLog("first effectivePolicyInVehicle original returned");
    }

    CSConfig *config = CSConfig.sharedConfig;
    if (CSSpoofSuppressed() || !config.isEnabled) return policy;

    NSString *bundleID = CSDeclarationBundleIdentifier(declaration);
    if (!bundleID) return policy;

    CSVLog("in-vehicle policy request for %s", bundleID.UTF8String);
    if ([config isBundleEnabled:bundleID] &&
        (CSPatchStateIsPatched(bundleID) || CSPatchStateIsNativeBridged(bundleID) ||
         CSRuntimePolicyEligible(bundleID))) {
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
    NSMethodSignature *signature = [_target methodSignatureForSelector:sel];
    if (signature) return signature;

    // CarPlay's FBSApplicationInfo returns an immutable NSDictionary for
    // -entitlements, while SpringBoard returns LSBundleInfoCachedValues.  The
    // latter has boolForKey:/typed objectForKey: methods; NSDictionary does
    // not.  Supplying matching signatures lets the proxy absorb those calls
    // instead of forwarding an unsupported selector into the dictionary.
    const char *name = sel_getName(sel);
    if (strcmp(name, "boolForKey:") == 0) return
        [NSMethodSignature signatureWithObjCTypes:"B@:@"];
    if (strcmp(name, "objectForKey:ofClass:valuesOfClass:") == 0 ||
        strcmp(name, "objectForKey:checkingKeyClass:checkingValueClass:") == 0)
        return [NSMethodSignature signatureWithObjCTypes:"@@:@##"];
    if (strcmp(name, "objectForKey:ofClass:") == 0)
        return [NSMethodSignature signatureWithObjCTypes:"@@:@#"];
    if (strcmp(name, "objectForKey:ofType:") == 0)
        return [NSMethodSignature signatureWithObjCTypes:"@@:@q"];
    if (strcmp(name, "objectForKey:") == 0)
        return [NSMethodSignature signatureWithObjCTypes:"@@:@"];
    return nil;
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

        // If the real object has this selector, preserve its exact behavior.
        // Otherwise (the FBS dictionary-backed case) answer from ordinary
        // -objectForKey: without ever sending boolForKey: to NSDictionary.
        if (![_target respondsToSelector:invocation.selector]) {
            id value = [_target respondsToSelector:@selector(objectForKey:)]
                ? [_target objectForKey:key] : nil;
            if (isBoolLookup) {
                BOOL answer = [value respondsToSelector:@selector(boolValue)]
                    ? [value boolValue] : NO;
                [invocation setReturnValue:&answer];
            } else {
                Class expected = Nil;
                if (strcmp(name, "objectForKey:ofClass:") == 0) {
                    __unsafe_unretained Class requested = Nil;
                    [invocation getArgument:&requested atIndex:3];
                    expected = requested;
                } else if (strcmp(name, "objectForKey:ofClass:valuesOfClass:") == 0 ||
                           strcmp(name, "objectForKey:checkingKeyClass:checkingValueClass:") == 0) {
                    __unsafe_unretained Class requested = Nil;
                    [invocation getArgument:&requested atIndex:3];
                    expected = requested;
                }
                if (expected && value && ![value isKindOfClass:expected]) value = nil;
                [invocation setReturnValue:&value];
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

/// SpringBoard may construct a declaration while CarPlay evaluates it in a
/// separate process, so the in-memory admission set is not sufficient. Once an
/// enabled non-native declaration reaches this hook, it has already passed the
/// declaration factory; promote it in this process as well. This is the
/// cross-process half of runtime admission and does not alter the app bundle.
static BOOL CSRuntimePolicyEligible(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    CSConfig *config = CSConfig.sharedConfig;
    if (!config.isEnabled || ![config isBundleEnabled:bundleID]) return NO;
    if (CSPatchStateIsNative(bundleID)) return NO;
    return CSIsRuntimeAdmitted(bundleID) || !CSPatchStateIsPatched(bundleID);
}

static void CSRecordRuntimeAdmission(NSString *bundleID) {
    @synchronized(CSRuntimeAdmittedBundles()) {
        [CSRuntimeAdmittedBundles() addObject:bundleID];
    }
}

static void CSLogAdmittedDeclarationShape(id declaration, NSString *bundleID) {
    if (!declaration) return;
    BOOL templates = [declaration respondsToSelector:@selector(supportsTemplates)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(declaration, @selector(supportsTemplates)) : NO;
    BOOL playable = [declaration respondsToSelector:@selector(supportsPlayableContent)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(declaration, @selector(supportsPlayableContent)) : NO;
    BOOL system = [declaration respondsToSelector:@selector(isSystemApp)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(declaration, @selector(isSystemApp)) : NO;
    CSLog("admitted declaration shape %s (templates=%d playable=%d system=%d)",
          bundleID.UTF8String, templates, playable, system);
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
typedef id (^CSFactoryRetryBlock)(id standIn);

static id CSFinishFactoryAdmission(NSString *identifier, id result, id entitlements,
                                   CSFactoryRetryBlock retry, const char *variant) {
    if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
        CSLog("factory %s enabled bundle %s -> %s", variant, identifier.UTF8String,
              result ? "declaration" : "nil");
        if (result) CSLogAdmittedDeclarationShape(result, identifier);
    }

    if (CSRuntimeAdmissionIsObserveOnly() || result) return result;
    if (!CSShouldAdmitAtRuntime(identifier)) {
        if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
            CSLog("not admitting %s (suppressed=%d globalEnabled=%d native=%d)",
                  identifier.UTF8String, CSSpoofSuppressed(),
                  CSConfig.sharedConfig.isEnabled, CSPatchStateIsNative(identifier));
        }
        return result;
    }
    if (!entitlements || !retry) {
        CSLog("runtime admission skipped for %s: factory %s supplied no entitlement object",
              identifier.UTF8String, variant);
        return result;
    }

    CSAdmittingEntitlements *standIn =
        [[CSAdmittingEntitlements alloc] initWithTarget:entitlements];
    id admitted = retry(standIn);
    if (!admitted) {
        CSLog("runtime admission produced no declaration for %s via %s — CarKit did not "
              "consult the stand-in, or wants more than the entitlement",
              identifier.UTF8String, variant);
        return result;
    }

    CSRecordRuntimeAdmission(identifier);
    CSLogAdmittedDeclarationShape(admitted, identifier);
    CSLog("%s admitted at runtime via %s — no on-disk patch required",
          identifier.UTF8String, variant);
    return admitted;
}

// CarPlay's FBS path can hand the factory a frozen NSDictionary instead of the
// LSBundleInfoCachedValues object seen in SpringBoard.  The original factory
// sends boolForKey: immediately, so waiting for a nil result is too late — the
// first call itself aborts CarPlay.  Replace that argument before the first
// call when it lacks the typed cached-values interface.
static BOOL CSFactoryNeedsEntitlementPreflight(NSString *identifier, id entitlements) {
    return !CSRuntimeAdmissionIsObserveOnly() &&
           CSShouldAdmitAtRuntime(identifier) && entitlements &&
           ![entitlements respondsToSelector:@selector(boolForKey:)];
}

static id CSFinishPreflightAdmission(NSString *identifier, id result,
                                      const char *variant) {
    if (!result) {
        CSLog("runtime admission produced no declaration for %s via preflight %s",
              identifier.UTF8String, variant);
        return nil;
    }
    CSRecordRuntimeAdmission(identifier);
    CSLogAdmittedDeclarationShape(result, identifier);
    CSLog("%s admitted at runtime via preflight %s — no on-disk patch required",
          identifier.UTF8String, variant);
    return result;
}

static id cs_declarationForBundleInfoEnts(Class self, SEL _cmd, id bundleID, id info,
                                          id entitlements) {
    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    BOOL preflight = CSFactoryNeedsEntitlementPreflight(identifier, entitlements);
    id initialEntitlements = preflight
        ? [[CSAdmittingEntitlements alloc] initWithTarget:entitlements] : entitlements;
    id result = orig_declarationForBundleInfoEnts(self, _cmd, bundleID, info,
                                                   initialEntitlements);
    static BOOL sawFirstCall = NO;
    if (!sawFirstCall) {
        sawFirstCall = YES;
        CSLog("declaration factory reached (first call: %s -> %s)",
              [bundleID description].UTF8String, result ? "declaration" : "nil");
    }
    if (preflight) return CSFinishPreflightAdmission(identifier, result, "info:entitlements:");
    return CSFinishFactoryAdmission(identifier, result, entitlements,
        ^id(id standIn) {
            return orig_declarationForBundleInfoEnts(self, _cmd, bundleID, info, standIn);
        }, "info:entitlements:");
}

// CarPlay.app uses the property-list factory variants rather than the
// LaunchServices-object variant used by SpringBoard.  Hooking only the latter
// admits FPT in SpringBoard but leaves CarPlay with no declaration to evaluate.
static id (*orig_declarationForBundleEntInfoPlist)(Class, SEL, id, id, id);
static id cs_declarationForBundleEntInfoPlist(Class self, SEL _cmd, id bundleID,
                                              id entitlements, id infoPlist) {
    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    BOOL preflight = CSFactoryNeedsEntitlementPreflight(identifier, entitlements);
    id initialEntitlements = preflight
        ? [[CSAdmittingEntitlements alloc] initWithTarget:entitlements] : entitlements;
    id result = orig_declarationForBundleEntInfoPlist(self, _cmd, bundleID,
                                                       initialEntitlements, infoPlist);
    if (preflight) return CSFinishPreflightAdmission(identifier, result,
                                                      "entitlements:infoPlist:");
    return CSFinishFactoryAdmission(identifier, result, entitlements,
        ^id(id standIn) {
            return orig_declarationForBundleEntInfoPlist(self, _cmd, bundleID,
                                                          standIn, infoPlist);
        }, "entitlements:infoPlist:");
}

static id (*orig_declarationForBundleInfoEntsPath)(Class, SEL, id, id, id, id);
static id cs_declarationForBundleInfoEntsPath(Class self, SEL _cmd, id bundleID,
                                              id info, id entitlements, id bundlePath) {
    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    BOOL preflight = CSFactoryNeedsEntitlementPreflight(identifier, entitlements);
    id initialEntitlements = preflight
        ? [[CSAdmittingEntitlements alloc] initWithTarget:entitlements] : entitlements;
    id result = orig_declarationForBundleInfoEntsPath(self, _cmd, bundleID, info,
                                                       initialEntitlements, bundlePath);
    if (preflight) return CSFinishPreflightAdmission(identifier, result,
                                                      "info:entitlements:bundlePath:");
    return CSFinishFactoryAdmission(identifier, result, entitlements,
        ^id(id standIn) {
            return orig_declarationForBundleInfoEntsPath(self, _cmd, bundleID, info,
                                                          standIn, bundlePath);
        }, "info:entitlements:bundlePath:");
}

static id (*orig_declarationForBundlePropertyLists)(Class, SEL, id, id, id);
static id cs_declarationForBundlePropertyLists(Class self, SEL _cmd, id bundleID,
                                                id infoPlist, id entitlementsPlist) {
    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    BOOL preflight = CSFactoryNeedsEntitlementPreflight(identifier, entitlementsPlist);
    id initialEntitlements = preflight
        ? [[CSAdmittingEntitlements alloc] initWithTarget:entitlementsPlist]
        : entitlementsPlist;
    id result = orig_declarationForBundlePropertyLists(self, _cmd, bundleID,
                                                        infoPlist, initialEntitlements);
    if (preflight) return CSFinishPreflightAdmission(identifier, result,
                                                      "infoPropertyList:entitlementsPropertyList:");
    return CSFinishFactoryAdmission(identifier, result, entitlementsPlist,
        ^id(id standIn) {
            return orig_declarationForBundlePropertyLists(self, _cmd, bundleID,
                                                           infoPlist, standIn);
        }, "infoPropertyList:entitlementsPropertyList:");
}

static id (*orig_declarationForBundlePropertyListsPath)(Class, SEL, id, id, id, id);
static id cs_declarationForBundlePropertyListsPath(Class self, SEL _cmd, id bundleID,
                                                    id infoPlist, id entitlementsPlist,
                                                    id bundlePath) {
    NSString *identifier = [bundleID isKindOfClass:NSString.class] ? bundleID : nil;
    BOOL preflight = CSFactoryNeedsEntitlementPreflight(identifier, entitlementsPlist);
    id initialEntitlements = preflight
        ? [[CSAdmittingEntitlements alloc] initWithTarget:entitlementsPlist]
        : entitlementsPlist;
    id result = orig_declarationForBundlePropertyListsPath(self, _cmd, bundleID,
                                                            infoPlist, initialEntitlements,
                                                            bundlePath);
    if (preflight) return CSFinishPreflightAdmission(identifier, result,
                                                      "infoPropertyList:entitlementsPropertyList:bundlePath:");
    return CSFinishFactoryAdmission(identifier, result, entitlementsPlist,
        ^id(id standIn) {
            return orig_declarationForBundlePropertyListsPath(self, _cmd, bundleID,
                                                               infoPlist, standIn, bundlePath);
        }, "infoPropertyList:entitlementsPropertyList:bundlePath:");
}

static NSString *CSFactoryObjectBundleIdentifier(id object) {
    SEL selectors[] = {
        @selector(bundleIdentifier), @selector(un_applicationBundleIdentifier),
        @selector(applicationIdentifier)
    };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        if (![object respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if ([value isKindOfClass:NSString.class]) return value;
    }
    return nil;
}

static id (*orig_declarationForAppProxy)(Class, SEL, id);
static id cs_declarationForAppProxy(Class self, SEL _cmd, id appProxy) {
    id result = orig_declarationForAppProxy(self, _cmd, appProxy);
    NSString *identifier = CSFactoryObjectBundleIdentifier(appProxy);
    if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
        CSLog("factory appProxy bundle %s -> %s", identifier.UTF8String,
              result ? "declaration" : "nil");
    }
    return result;
}

static id (*orig_declarationForAppRecord)(Class, SEL, id);
static id cs_declarationForAppRecord(Class self, SEL _cmd, id appRecord) {
    id result = orig_declarationForAppRecord(self, _cmd, appRecord);
    NSString *identifier = CSFactoryObjectBundleIdentifier(appRecord);
    if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
        CSLog("factory appRecord bundle %s -> %s", identifier.UTF8String,
              result ? "declaration" : "nil");
    }
    return result;
}

static id CSApplicationProxyForIdentifier(NSString *identifier) {
    Class proxyClass = CSLookupClass("LSApplicationProxy");
    SEL proxySelector = @selector(applicationProxyForIdentifier:);
    return proxyClass && [proxyClass respondsToSelector:proxySelector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, proxySelector, identifier)
        : nil;
}

static id CSCreateDBApplicationInfoFromProxy(id proxy) {
    Class dbClass = CSLookupClass("DBApplicationInfo");
    SEL initSelector = @selector(initWithApplicationProxy:);
    if (!dbClass || !proxy || ![dbClass instancesRespondToSelector:initSelector]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)([dbClass alloc], initSelector, proxy);
}

// The previous FBS subclass insertion is permanently disabled.  The tested
// DBApplicationInfo initializer is the only candidate allowed to reach the
// experimental roster path.
static BOOL CSAllowExperimentalRosterInsertion(void) {
    return YES;
}

static id (*orig_allInstalledApplications)(id, SEL);
static void (*orig_applicationsDidUninstall)(id, SEL, id);
static NSHashTable *gCarPlayApplicationLibraries;
static NSHashTable *gIconLayoutControllers;
static NSHashTable *gIconLayoutServices;
// Keep the live service strongly reachable while CarPlay is rebuilding its
// private connection graph; UIApplication's accessor can briefly return nil.
static __strong id gLastIconLayoutService;
static __strong id gLastIconLayoutController;
static NSSet *gRuntimeEnabledIdentifiers;
static NSMutableSet<NSString *> *gUninstalledRuntimeIdentifiers;
static NSMutableSet<NSString *> *gDashboardRemovedIdentifiers;
static NSString *CSFactoryObjectBundleIdentifier(id object);
static NSArray *CSUninstallApplicationIdentifiers(id applications);
static void CSRemoveDashboardApplications(NSArray<NSString *> *identifiers);
static id CSFilterIconLayoutState(id state);
static void CSSBSRefreshIconState(void);

static BOOL CSIsIconLayoutProcess(void) {
    NSString *processName = NSProcessInfo.processInfo.processName;
    return [processName isEqualToString:@"SpringBoard"] ||
           [processName isEqualToString:@"CarPlay"] ||
           [processName isEqualToString:@"CarPlayTemplateUIHost"];
}

static NSSet *CSRuntimeEnabledIdentifierSet(void) {
    return [NSSet setWithArray:CSConfig.sharedConfig.enabledBundleIdentifiers ?: @[]];
}

static void CSRememberRuntimeEnabledIdentifiers(void) {
    @synchronized ([CSConfig class]) {
        gRuntimeEnabledIdentifiers = CSRuntimeEnabledIdentifierSet();
    }
}

static void CSRememberInitialRuntimeEnabledIdentifiers(void) {
    @synchronized ([CSConfig class]) {
        if (!gRuntimeEnabledIdentifiers) {
            gRuntimeEnabledIdentifiers = CSRuntimeEnabledIdentifierSet();
        }
    }
}

static NSSet *CSPreviousRuntimeEnabledIdentifiers(void) {
    @synchronized ([CSConfig class]) {
        return [gRuntimeEnabledIdentifiers copy] ?: [NSSet set];
    }
}

static void CSRememberApplicationLibrary(id library) {
    if (!library) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCarPlayApplicationLibraries = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (gCarPlayApplicationLibraries) {
        [gCarPlayApplicationLibraries addObject:library];
    }
}

static void CSRememberIconLayoutController(id controller) {
    if (!controller) return;
    gLastIconLayoutController = controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIconLayoutControllers = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (gIconLayoutControllers) {
        [gIconLayoutControllers addObject:controller];
    }
}

static void CSRememberIconLayoutService(id service) {
    if (!service) return;
    gLastIconLayoutService = service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIconLayoutServices = [NSHashTable weakObjectsHashTable];
    });
    @synchronized (gIconLayoutServices) {
        [gIconLayoutServices addObject:service];
    }
}

static void CSMarkRuntimeApplicationsUninstalled(NSArray<NSString *> *identifiers) {
    if (identifiers.count == 0) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gUninstalledRuntimeIdentifiers = [NSMutableSet new];
    });
    @synchronized (gUninstalledRuntimeIdentifiers) {
        [gUninstalledRuntimeIdentifiers addObjectsFromArray:identifiers];
    }
    // A cached synthetic roster entry for a now-uninstalled app must not survive.
    CSInvalidateExpandedRosterCache();
    static dispatch_once_t removedOnce;
    dispatch_once(&removedOnce, ^{ gDashboardRemovedIdentifiers = [NSMutableSet new]; });
    @synchronized (gDashboardRemovedIdentifiers) {
        [gDashboardRemovedIdentifiers addObjectsFromArray:identifiers];
    }
}

static void CSMarkRuntimeApplicationsInstalled(NSArray<NSString *> *identifiers) {
    if (identifiers.count == 0) return;
    if (gUninstalledRuntimeIdentifiers) {
        @synchronized (gUninstalledRuntimeIdentifiers) {
            [gUninstalledRuntimeIdentifiers minusSet:[NSSet setWithArray:identifiers]];
        }
    }
    if (gDashboardRemovedIdentifiers) {
        @synchronized (gDashboardRemovedIdentifiers) {
            [gDashboardRemovedIdentifiers minusSet:[NSSet setWithArray:identifiers]];
        }
    }
}

static void CSRestorePersistedDashboardDisabledIdentifiers(void) {
    NSArray<NSString *> *identifiers = CSConfig.sharedConfig.dashboardDisabledBundleIdentifiers;
    if (identifiers.count == 0) return;
    static dispatch_once_t removedOnce;
    dispatch_once(&removedOnce, ^{ gDashboardRemovedIdentifiers = [NSMutableSet new]; });
    @synchronized (gDashboardRemovedIdentifiers) {
        [gDashboardRemovedIdentifiers addObjectsFromArray:identifiers];
    }
    CSLog("restored %lu persisted disabled-dashboard tombstone(s)",
          (unsigned long)identifiers.count);
}

static BOOL CSRuntimeApplicationWasUninstalled(NSString *identifier) {
    if (identifier.length == 0 || !gUninstalledRuntimeIdentifiers) return NO;
    @synchronized (gUninstalledRuntimeIdentifiers) {
        return [gUninstalledRuntimeIdentifiers containsObject:identifier];
    }
}

static BOOL CSRuntimeApplicationWasRemovedFromDashboard(NSString *identifier) {
    if (identifier.length == 0 || !gDashboardRemovedIdentifiers) return NO;
    @synchronized (gDashboardRemovedIdentifiers) {
        return [gDashboardRemovedIdentifiers containsObject:identifier];
    }
}

/// CSConfig reloads on the shared preference notification, but FBSApplicationLibrary
/// keeps its filtered application array cached.  Invalidate only the live CarPlay
/// library objects so the next dashboard query observes enable/disable/uninstall
/// changes without restarting SpringBoard or CarPlay.
static void CSInvalidateCarPlayApplicationLibraries(void) {
    CSTimingLog("reload invalidation begin");
    // The enabled set may have changed, so the cached synthetic roster entries
    // are stale. Drop them; the next roster query rebuilds only what is needed.
    CSInvalidateExpandedRosterCache();
    NSArray *libraries = nil;
    @synchronized (gCarPlayApplicationLibraries) {
        libraries = gCarPlayApplicationLibraries.allObjects;
    }
    NSUInteger invalidated = 0;
    for (id library in libraries) {
        SEL invalidate = @selector(invalidate);
        if (![library respondsToSelector:invalidate]) continue;
        ((void (*)(id, SEL))objc_msgSend)(library, invalidate);
        invalidated++;
    }
    CSLog("CarPlay application-library cache invalidated (%lu object(s))",
          (unsigned long)invalidated);
    CSTimingLog("reload invalidation end objects=%lu", (unsigned long)invalidated);
}

// --- DBApplication carPlayDeclaration bridge -----------------------------------
// The in-place dashboard mutation below loads a runtime-admitted app through
// -[DBApplicationController _loadApplicationWithInfo:], which drives
// -_updatePolicyForApplication:. On iOS 18.5 that sends -carPlayDeclaration to
// the DBApplication, but the class does not implement it — only its -info (a
// DBApplicationInfo) does — so the load aborted with
//   -[DBApplication carPlayDeclaration]: unrecognized selector
// and CarPlay crash-looped. Answer the selector by forwarding to the app's own
// -info, which returns the exact declaration the runtime-admission factory built.
//
// This is the deliberate exception to CSRuntime's "never class_addMethod" rule:
// the framework DOES send this selector and crashes when it is absent, so the
// method is one the framework expects. class_getInstanceMethod guards it — if
// the system ever provides the method (now or via a later-loaded category) we
// install nothing and native behavior is kept.
static id cs_dbApplicationCarPlayDeclaration(id self, SEL _cmd) {
    SEL infoSelector = @selector(info);
    if (![self respondsToSelector:infoSelector]) return nil;
    id info = ((id (*)(id, SEL))objc_msgSend)(self, infoSelector);
    SEL declarationSelector = @selector(carPlayDeclaration);
    if (!info || ![info respondsToSelector:declarationSelector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(info, declarationSelector);
}

static void CSInstallDBApplicationDeclarationBridge(void) {
    static BOOL installed = NO;
    if (installed) return;
    // DBApplication only exists in the CarPlay UI process; absent elsewhere.
    Class dbApplication = objc_getClass("DBApplication");
    if (!dbApplication) return;
    SEL selector = @selector(carPlayDeclaration);
    if (class_getInstanceMethod(dbApplication, selector)) {
        installed = YES; // the system provides it — do not shadow it
        return;
    }
    if (class_addMethod(dbApplication, selector,
                        (IMP)cs_dbApplicationCarPlayDeclaration, "@@:")) {
        installed = YES;
        CSLog("installed DBApplication carPlayDeclaration bridge (forwards to -info)");
    }
}

// Pin a dashboard object (DBApplicationInfo, or the DBApplication built from it)
// for the process lifetime. DashBoard references these non-retained while it
// resolves policy/icons; freeing them left dangling references and CarPlay
// crashed with EXC_BAD_ACCESS / PAC failure. Shares gPinnedRosterInfos with the
// FBS roster injection; all callers run on the main queue, so a plain nil-check
// is sufficient. Bounded (one entry per enabled app).
static void CSPinDashboardObject(id object) {
    if (!object) return;
    if (!gPinnedRosterInfos) gPinnedRosterInfos = [NSMutableArray new];
    if (![gPinnedRosterInfos containsObject:object]) {
        [gPinnedRosterInfos addObject:object];
    }
}

/// Applies the enable/disable delta to DBApplicationController and notifies its
/// observers so the CarPlay home grid updates in place. Returns YES when the
/// change was fully handled incrementally (every enabled app inserted and every
/// disabled app removed with an observer callback), so the caller can skip the
/// whole-library invalidation that otherwise makes the dashboard reload and
/// re-animate. Returns NO when a heavy rebuild is still needed (non-CarPlay
/// process, missing controller, or an addition that could not be resolved).
static BOOL CSRefreshDashboardApplicationController(NSSet *previous) {
    previous = previous ?: [NSSet set];
    NSSet *current = CSRuntimeEnabledIdentifierSet();
    NSMutableSet *removed = [previous mutableCopy];
    [removed minusSet:current];
    NSMutableSet *added = [current mutableCopy];
    [added minusSet:previous];

    // A deliberate re-enable is the safe positive signal for clearing a
    // removed-ID tombstone. The install swizzle is intentionally absent; do
    // not clear it merely because LaunchServices still returns a stale proxy
    // during the uninstall transaction.
    CSMarkRuntimeApplicationsInstalled(added.allObjects);

    static dispatch_once_t removedOnce;
    dispatch_once(&removedOnce, ^{ gDashboardRemovedIdentifiers = [NSMutableSet new]; });
    @synchronized (gDashboardRemovedIdentifiers) {
        [gDashboardRemovedIdentifiers unionSet:removed];
        [gDashboardRemovedIdentifiers minusSet:added];
    }
    // Record the new baseline in every CarPlay UI process. TemplateUIHost
    // returns before the DBApplicationController work below, but it must still
    // forget a removed-ID tombstone after a deliberate re-enable.
    CSRememberRuntimeEnabledIdentifiers();

    // CarPlayTemplateUIHost owns the icon-layout service, while CarPlay owns
    // DBApplicationController. Keep the removed-ID state in sync in both
    // processes, but only touch the dashboard roster where its controller
    // actually exists.
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) return NO;
    CSTimingLog("dashboard roster refresh begin");

    Class controllerClass = CSLookupClass("DBApplicationController");
    SEL sharedSelector = @selector(sharedInstance);
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return NO;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    if (!controller) return NO;

    // Mutate DBApplicationController in place and notify its observers so the
    // grid re-renders WITHOUT a whole-library invalidation (which re-sorted the
    // icons and reloaded the screen). The earlier attempt crashed because
    // -_updatePolicyForApplication: sends -carPlayDeclaration to the
    // DBApplication, which does not implement it; the bridge installed below
    // forwards that to the app's own -info (which returns the declaration the
    // runtime-admission factory built), so the load now succeeds.
    CSInstallDBApplicationDeclarationBridge();

    SEL loadSelector = @selector(_loadApplicationWithInfo:);
    SEL appForIDSelector = @selector(applicationWithBundleIdentifier:);
    SEL removeSelector = @selector(_removeApplicationWithBundleIdentifier:);
    SEL didAddSelector = @selector(_didAddApplications:);
    SEL didRemoveSelector = @selector(_didRemoveApplications:);
    BOOL canLoad = [controller respondsToSelector:loadSelector];
    BOOL canQuery = [controller respondsToSelector:appForIDSelector];
    BOOL canRemove = [controller respondsToSelector:removeSelector];

    // Add: load each newly enabled app's DBApplicationInfo, then collect the
    // resulting DBApplication objects for the observer notification.
    NSMutableArray *addedApps = [NSMutableArray new];
    NSUInteger addsHandled = 0;
    if (canLoad && canQuery) {
        for (NSString *identifier in added) {
            if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) continue;
            if (CSRuntimeApplicationWasUninstalled(identifier)) continue;
            id existing = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                                                              appForIDSelector, identifier);
            if (existing) {           // a natural roster rebuild already placed it
                CSPinDashboardObject(existing);
                addsHandled++;
                continue;
            }
            id proxy = CSApplicationProxyForIdentifier(identifier);
            if (!proxy) {
                CSLog("dashboard add skipped %s (no application proxy)", identifier.UTF8String);
                continue;
            }
            id info = CSCreateDBApplicationInfoFromProxy(proxy);
            if (!info) {
                CSLog("dashboard add skipped %s (no DBApplicationInfo)", identifier.UTF8String);
                continue;
            }
            ((void (*)(id, SEL, id))objc_msgSend)(controller, loadSelector, info);
            id application = ((id (*)(id, SEL, id))objc_msgSend)(controller,
                                                                 appForIDSelector, identifier);
            if (!application) {
                CSLog("dashboard add %s produced no DBApplication", identifier.UTF8String);
                continue;
            }
            CSPinDashboardObject(info);
            CSPinDashboardObject(application);
            [addedApps addObject:application];
            addsHandled++;
            CSLog("dashboard added %s in place", identifier.UTF8String);
        }
    }

    // Remove: capture the DBApplication before removal so the notifier carries it.
    NSMutableArray *removedApps = [NSMutableArray new];
    NSUInteger removesHandled = 0;
    if (canRemove) {
        for (NSString *identifier in removed) {
            if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) continue;
            id application = canQuery
                ? ((id (*)(id, SEL, id))objc_msgSend)(controller, appForIDSelector, identifier)
                : nil;
            ((void (*)(id, SEL, id))objc_msgSend)(controller, removeSelector, identifier);
            if (application) [removedApps addObject:application];
            removesHandled++;
            CSLog("dashboard removed %s in place", identifier.UTF8String);
        }
    }

    // The mutation alone never redraws the grid — the observer callback does
    // (08-14 fact 1). Fire it with the changed applications.
    if (addedApps.count > 0 && [controller respondsToSelector:didAddSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, didAddSelector, addedApps);
        CSLog("dashboard notified _didAddApplications (%lu)", (unsigned long)addedApps.count);
    }
    if (removedApps.count > 0 && [controller respondsToSelector:didRemoveSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, didRemoveSelector, removedApps);
        CSLog("dashboard notified _didRemoveApplications (%lu)", (unsigned long)removedApps.count);
    }

    BOOL fullyHandled = (addsHandled == added.count) && (removesHandled == removed.count);
    CSTimingLog("dashboard roster refresh end added=%lu/%lu removed=%lu/%lu (in-place)",
                (unsigned long)addsHandled, (unsigned long)added.count,
                (unsigned long)removesHandled, (unsigned long)removed.count);
    return fullyHandled;
}

static NSArray *CSIconLayoutVehicleIdentifiers(id service) {
    if (!service || ![service respondsToSelector:@selector(connections)]) return @[];
    id connections = ((id (*)(id, SEL))objc_msgSend)(service, @selector(connections));
    CSLog("CarPlay icon-layout connections class=%s",
          connections ? object_getClassName(connections) : "(nil)");
    NSMutableArray *identifiers = [NSMutableArray new];
    if ([connections isKindOfClass:NSDictionary.class]) {
        for (id key in [(NSDictionary *)connections allKeys]) {
            if (key && key != [NSNull null]) [identifiers addObject:key];
        }
    } else if ([connections isKindOfClass:NSArray.class]) {
        for (id connection in (NSArray *)connections) {
            SEL selectors[] = { sel_getUid("vehicleID"),
                                sel_getUid("vehicleIdentifier"),
                                sel_getUid("identifier") };
            for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(*selectors); i++) {
                SEL selector = selectors[i];
                if (![connection respondsToSelector:selector]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(connection, selector);
                if (value && value != [NSNull null]) {
                    [identifiers addObject:value];
                    break;
                }
            }
        }
    } else if ([connections respondsToSelector:@selector(allKeys)]) {
        for (id key in ((id (*)(id, SEL))objc_msgSend)(connections, @selector(allKeys))) {
            if (key && key != [NSNull null]) [identifiers addObject:key];
        }
    } else if ([connections isKindOfClass:NSHashTable.class] &&
               [connections respondsToSelector:@selector(allObjects)]) {
        // On iOS 18 this is an NSHashTable rather than a dictionary/map. Its
        // elements are the live vehicle connection objects, so inspect the
        // same identifier selectors used by CRSIconLayoutController.
        NSArray *objects = ((id (*)(id, SEL))objc_msgSend)(connections,
                                                            @selector(allObjects));
        CSLog("CarPlay icon-layout hash connections count=%lu",
              (unsigned long)objects.count);
        for (id connection in objects) {
            SEL selectors[] = { @selector(vehicleID), @selector(vehicleIdentifier),
                                @selector(identifier), sel_getUid("certificateSerial"),
                                sel_getUid("serial") };
            for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(*selectors); i++) {
                SEL selector = selectors[i];
                if (![connection respondsToSelector:selector]) continue;
                id value = ((id (*)(id, SEL))objc_msgSend)(connection, selector);
                if (value && value != [NSNull null]) {
                    [identifiers addObject:value];
                    break;
                }
            }
        }
    } else if ([connections respondsToSelector:@selector(keyEnumerator)]) {
        // CRSIconLayoutService has used map-like connection stores across
        // releases. NSMapTable exposes keyEnumerator instead of allKeys; the
        // vehicle identifier is the map key in that representation.
        NSEnumerator *enumerator =
            ((id (*)(id, SEL))objc_msgSend)(connections, @selector(keyEnumerator));
        for (id key in enumerator) {
            if (key && key != [NSNull null]) [identifiers addObject:key];
        }
    }
    return identifiers;
}

static NSArray *CSIconLayoutControllerVehicleIdentifiers(id controller) {
    if (!controller || ![controller respondsToSelector:@selector(connection)]) return @[];
    id connection = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(connection));
    if (!connection) return @[];
    SEL selectors[] = { @selector(vehicleID), @selector(vehicleIdentifier),
                        @selector(identifier), sel_getUid("certificateSerial"),
                        sel_getUid("serial") };
    NSMutableArray *identifiers = [NSMutableArray new];
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        if (![connection respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(connection, selector);
        if (value && value != [NSNull null]) [identifiers addObject:value];
    }
    return identifiers;
}

static void CSRefreshDashboardIconLayoutController(id controller) {
    if (!controller) return;
    NSArray *vehicleIdentifiers = CSIconLayoutControllerVehicleIdentifiers(controller);
    CSLog("CarPlay icon-layout controller class=%s vehicle-identifiers=%s",
          object_getClassName(controller),
          [[vehicleIdentifiers componentsJoinedByString:@", "] UTF8String] ?: "(none)");
    SEL resetSelector = @selector(resetIconStateForVehicleID:);
    SEL fetchSelector = @selector(fetchIconStateForVehicleID:completion:);
    SEL setSelector = @selector(setIconState:forVehicleID:);
    if (vehicleIdentifiers.count == 0 ||
        ![controller respondsToSelector:fetchSelector] ||
        ![controller respondsToSelector:setSelector]) return;
    for (id vehicleID in vehicleIdentifiers) {
        if ([controller respondsToSelector:resetSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, resetSelector, vehicleID);
        }
        void (^completion)(id, id) = ^(id state, id error) {
            if (!state || error) return;
            id filtered = CSFilterIconLayoutState(state);
            if (filtered == state) return;
            ((void (*)(id, SEL, id, id))objc_msgSend)(controller, setSelector,
                                                       filtered, vehicleID);
            CSLog("CarPlay icon-layout controller wrote filtered state vehicle=%s",
                  [[vehicleID description] UTF8String]);
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, fetchSelector,
                                                   vehicleID, completion);
    }
}

static void CSRefreshDashboardIconLayout(void) {
    // Disabled: proactively resetting and rewriting the per-vehicle icon state
    // is what corrupted the dashboard on a real connection. DBApplicationController
    // drives the enable/disable sync; leave the vehicle's own icon state alone.
    static const BOOL kIconLayoutRefreshDisabled = YES;
    if (kIconLayoutRefreshDisabled) return;
    if (!CSIsIconLayoutProcess()) return;
    CSTimingLog("dashboard icon refresh begin");
    // SBSApplicationCarPlayService is the persisted dashboard icon owner on
    // iOS 18. Reconcile it first; CRSIconLayoutService is only a secondary
    // UI-side cache and may have no vehicle connection at this point.
    CSSBSRefreshIconState();

    id dashboard = UIApplication.sharedApplication;
    SEL serviceSelector = @selector(iconLayoutService);
    id service = [dashboard respondsToSelector:serviceSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(dashboard, serviceSelector) : nil;
    if (!service && gIconLayoutServices) {
        @synchronized (gIconLayoutServices) {
            service = gIconLayoutServices.allObjects.firstObject;
        }
        if (service) CSLog("CarPlay icon-layout service recovered from live instance");
    }
    if (!service && gLastIconLayoutService) {
        service = gLastIconLayoutService;
        CSLog("CarPlay icon-layout service recovered from strong instance");
    }
    if ([service respondsToSelector:@selector(invalidate)]) {
        ((void (*)(id, SEL))objc_msgSend)(service, @selector(invalidate));
        CSLog("CarPlay CRS icon-layout service invalidated");
    }

    NSArray *vehicleIdentifiers = CSIconLayoutVehicleIdentifiers(service);
    if (vehicleIdentifiers.count == 0 && gLastVehicleIdentifier) {
        vehicleIdentifiers = @[ gLastVehicleIdentifier ];
        CSLog("CarPlay icon-layout using cached in-vehicle identifier %s",
              [[gLastVehicleIdentifier description] UTF8String]);
    }
    if (vehicleIdentifiers.count > 0) {
        CSLog("CarPlay icon-layout active vehicle count=%lu",
              (unsigned long)vehicleIdentifiers.count);
        SEL resetForVehicleSelector = @selector(resetIconStateForVehicleID:);
        SEL fetchForVehicleSelector = @selector(fetchIconStateForVehicleID:completion:);
        SEL setForVehicleSelector = @selector(setIconState:forVehicleID:);
        for (id vehicleID in vehicleIdentifiers) {
            if ([service respondsToSelector:resetForVehicleSelector]) {
                ((void (*)(id, SEL, id))objc_msgSend)(service,
                                                       resetForVehicleSelector, vehicleID);
            }
            if ([service respondsToSelector:fetchForVehicleSelector] &&
                [service respondsToSelector:setForVehicleSelector]) {
                void (^completion)(id, id) = ^(id state, id error) {
                    if (!state || error) return;
                    id filtered = CSFilterIconLayoutState(state);
                    if (filtered == state) return;
                    ((void (*)(id, SEL, id, id))objc_msgSend)(service,
                                                               setForVehicleSelector,
                                                               filtered, vehicleID);
                    CSLog("CarPlay icon-layout filtered state written for vehicle %s",
                          [[vehicleID description] UTF8String]);
                };
                ((void (*)(id, SEL, id, id))objc_msgSend)(service,
                                                           fetchForVehicleSelector,
                                                           vehicleID, completion);
            }
        }
    } else {
        CSLog("CarPlay icon-layout service has no active vehicle connections");
    }

    // Some vehicles do not expose iconLayoutDataProviders, but the service
    // still owns the persisted state returned to the dashboard. Fetch that
    // state and write the filtered version back so an injected app removed
    // from DBApplicationController cannot remain as a stale home-screen icon.
    SEL fetchStateSelector = @selector(fetchIconStateForVehicleID:completion:);
    SEL setStateSelector = @selector(setIconState:forVehicleID:);
    if (!gLastVehicleIdentifier && [service respondsToSelector:fetchStateSelector] &&
        [service respondsToSelector:setStateSelector]) {
        void (^completion)(id, id) = ^(id state, id error) {
            if (!state || error) return;
            id filtered = CSFilterIconLayoutState(state);
            if (filtered == state) return;
            ((void (*)(id, SEL, id, id))objc_msgSend)(service, setStateSelector,
                                                       filtered, nil);
            CSLog("CarPlay icon-layout service wrote filtered stale state");
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(service, fetchStateSelector,
                                                   nil, completion);
    }

    // On iOS 18 the host can keep the vehicle connection on a controller and
    // leave CRSIconLayoutService.connections empty. Query both the tracked
    // controllers and the strong fallback so roster changes still reach the
    // vehicle-owned icon state.
    NSMutableArray *controllers = [NSMutableArray new];
    if (gIconLayoutControllers) {
        @synchronized (gIconLayoutControllers) {
            [controllers addObjectsFromArray:gIconLayoutControllers.allObjects];
        }
    }
    if (gLastIconLayoutController && ![controllers containsObject:gLastIconLayoutController]) {
        [controllers addObject:gLastIconLayoutController];
    }
    for (id controller in controllers) {
        CSRefreshDashboardIconLayoutController(controller);
    }

    id displayManager = [dashboard respondsToSelector:@selector(displayManager)]
        ? ((id (*)(id, SEL))objc_msgSend)(dashboard, @selector(displayManager)) : nil;
    SEL providerSelector = @selector(iconLayoutDataProviderForVehicleIdentifier:);
    id vehicleProvider = [displayManager respondsToSelector:providerSelector]
        ? ((id (*)(id, SEL, id))objc_msgSend)(displayManager, providerSelector, nil) : nil;
    if (vehicleProvider) {
        CSLog("CarPlay vehicle icon provider class=%s", object_getClassName(vehicleProvider));
        if ([vehicleProvider respondsToSelector:@selector(resetIconState)]) {
            ((void (*)(id, SEL))objc_msgSend)(vehicleProvider, @selector(resetIconState));
            CSLog("CarPlay vehicle icon provider reset");
        }
    } else {
        CSLog("CarPlay vehicle icon provider unavailable");
    }

    SEL providersSelector = @selector(iconLayoutDataProviders);
    if (![dashboard respondsToSelector:providersSelector]) {
        CSTimingLog("dashboard icon refresh end providers-selector-absent");
        return;
    }
    id providers = ((id (*)(id, SEL))objc_msgSend)(dashboard, providersSelector);
    NSArray *objects = nil;
    if ([providers isKindOfClass:NSDictionary.class]) {
        objects = [((NSDictionary *)providers).allValues copy];
    }
    else if ([providers isKindOfClass:NSArray.class]) objects = [providers copy];
    else if (providers) objects = @[ providers ];

    NSUInteger refreshed = 0;
    for (id provider in objects) {
        SEL resetSelector = @selector(resetIconState);
        if (![provider respondsToSelector:resetSelector]) continue;
        ((void (*)(id, SEL))objc_msgSend)(provider, resetSelector);
        refreshed++;
    }
    CSLog("CarPlay icon-layout state refreshed (%lu provider(s))",
          (unsigned long)refreshed);
    CSTimingLog("dashboard icon refresh end providers=%lu", (unsigned long)refreshed);
}

static NSString *CSIconBundleIdentifier(id icon) {
    if ([icon isKindOfClass:NSString.class]) return icon;
    SEL selectors[] = { @selector(bundleIdentifier), @selector(applicationIdentifier),
                        @selector(un_applicationBundleIdentifier),
                        sel_getUid("applicationBundleIdentifier"),
                        sel_getUid("appIdentifier"), sel_getUid("identifier") };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        if (![icon respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(icon, selector);
        if ([value isKindOfClass:NSString.class]) return value;
    }
    return nil;
}

// Total visible icons across all pages of a CRSIconLayoutState. Used to detect
// the degenerate 0-icon state DashBoard writes during connect churn.
static NSUInteger CSIconStateVisibleCount(id state) {
    if (![state respondsToSelector:@selector(pages)]) return 0;
    id pages = ((id (*)(id, SEL))objc_msgSend)(state, @selector(pages));
    if (![pages isKindOfClass:NSArray.class]) return 0;
    NSUInteger total = 0;
    for (id page in pages) {
        id icons = [page respondsToSelector:@selector(icons)]
            ? ((id (*)(id, SEL))objc_msgSend)(page, @selector(icons))
            : ([page isKindOfClass:NSArray.class] ? page : nil);
        if ([icons respondsToSelector:@selector(count)]) total += [icons count];
    }
    return total;
}

static NSString *CSIconStateVehicleKey(id vehicleID) {
    if (!vehicleID || vehicleID == [NSNull null]) return @"(default)";
    return [vehicleID description].length ? [vehicleID description] : @"(default)";
}

static void CSRememberGoodIconState(id state, id vehicleID) {
    NSUInteger count = CSIconStateVisibleCount(state);
    if (count == 0) return;
    if (!gLastGoodIconStates) gLastGoodIconStates = [NSMutableDictionary new];
    NSString *key = CSIconStateVehicleKey(vehicleID);
    gLastGoodIconStates[key] = state;
    // Keep the legacy single-state diagnostics in sync for existing log/tools.
    gLastGoodIconState = state;
    gLastGoodIconCount = count;
    CSLog("icon-layout remembered good state key=%s vehicle-class=%s state=%s count=%lu "
          "entries=%lu",
          key.UTF8String ?: "(nil)",
          vehicleID ? object_getClassName(vehicleID) : "(nil)",
          object_getClassName(state), (unsigned long)count,
          (unsigned long)gLastGoodIconStates.count);
}

static id CSLastGoodIconStateForVehicle(id vehicleID) {
    return gLastGoodIconStates[CSIconStateVehicleKey(vehicleID)];
}

static void CSCopyIconStateMetadata(id dst, id src);

// DashBoard persists the authoritative per-vehicle order independently of the
// CRS object graph. On a fresh CarPlay process the first setIconState call can
// therefore contain an empty CRS state even though this plist still has the
// complete layout. Rebuild native CRS objects from that persisted order so the
// writer receives a coherent state on the first call after relaunch.
static id CSPersistedIconStateForVehicle(id template, id vehicleID) {
    NSString *key = CSIconStateVehicleKey(vehicleID);
    NSString *path = [@"/var/mobile/Library/SpringBoard"
                      stringByAppendingPathComponent:
                      [key stringByAppendingString:@"-CarDisplayIconState.plist"]];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    NSArray *iconLists = [plist[ @"iconLists" ] isKindOfClass:NSArray.class]
        ? plist[ @"iconLists" ] : nil;
    Class iconClass = CSLookupClass("CRSApplicationIcon");
    Class pageClass = CSLookupClass("CRSIconLayoutPage");
    Class stateClass = object_getClass(template);
    SEL iconInit = @selector(initWithBundleIdentifier:);
    SEL pageInit = @selector(initWithIcons:);
    SEL stateInit = @selector(initWithPages:hiddenIcons:);
    if (iconLists.count == 0 || !iconClass || !pageClass || !stateClass ||
        ![iconClass instancesRespondToSelector:iconInit] ||
        ![pageClass instancesRespondToSelector:pageInit] ||
        ![stateClass instancesRespondToSelector:stateInit]) return nil;

    NSMutableArray *pages = [NSMutableArray new];
    for (NSArray *bundleIDs in iconLists) {
        if (![bundleIDs isKindOfClass:NSArray.class]) continue;
        NSMutableArray *icons = [NSMutableArray new];
        for (NSString *bundleID in bundleIDs) {
            if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) continue;
            id icon = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc],
                                                            iconInit, bundleID);
            if (icon) [icons addObject:icon];
        }
        id page = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit, icons);
        if (page) [pages addObject:page];
    }

    NSMutableArray *hidden = [NSMutableArray new];
    NSDictionary *metadata = [plist[ @"metadata" ] isKindOfClass:NSDictionary.class]
        ? plist[ @"metadata" ] : nil;
    for (NSString *bundleID in metadata[@"hiddenIcons"]) {
        if (![bundleID isKindOfClass:NSString.class] || bundleID.length == 0) continue;
        id icon = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc],
                                                        iconInit, bundleID);
        if (icon) [hidden addObject:icon];
    }
    if (pages.count == 0) return nil;
    id restored = ((id (*)(id, SEL, id, id))objc_msgSend)([stateClass alloc],
                                                            stateInit, pages, hidden);
    if (!restored) return nil;
    CSCopyIconStateMetadata(restored, template);
    CSLog("icon-layout restored persisted state key=%s pages=%lu visible=%lu",
          key.UTF8String ?: "(nil)", (unsigned long)pages.count,
          (unsigned long)CSIconStateVisibleCount(restored));
    return restored;
}

// Does a fetched CRSIconLayoutState already contain this bundle id, in a visible
// page or in hiddenIcons? Used to tell a re-enable (already in the layout, the
// hiddenIcons sync can un-hide it live) from a fresh enable (needs a roster
// rebuild to appear at all).
static BOOL CSLayoutStateContainsBundle(id state, NSString *bid) {
    if (!state || bid.length == 0) return NO;
    id pages = [state respondsToSelector:@selector(pages)]
        ? ((id (*)(id, SEL))objc_msgSend)(state, @selector(pages)) : nil;
    for (id page in ([pages isKindOfClass:NSArray.class] ? pages : @[])) {
        id icons = [page respondsToSelector:@selector(icons)]
            ? ((id (*)(id, SEL))objc_msgSend)(page, @selector(icons))
            : ([page isKindOfClass:NSArray.class] ? page : nil);
        for (id icon in ([icons isKindOfClass:NSArray.class] ? icons : @[])) {
            if ([CSIconBundleIdentifier(icon) isEqualToString:bid]) return YES;
        }
    }
    id hidden = [state respondsToSelector:@selector(hiddenIcons)]
        ? ((id (*)(id, SEL))objc_msgSend)(state, @selector(hiddenIcons)) : nil;
    for (id icon in ([hidden isKindOfClass:NSArray.class] ? hidden : @[])) {
        if ([CSIconBundleIdentifier(icon) isEqualToString:bid]) return YES;
    }
    return NO;
}

// Read-only instrumentation: dump the exact runtime shape of an icon-order /
// hidden-icons / icon-state argument so the safe hiddenIcons mutation path can be
// written against the confirmed contract rather than guessed from the persisted
// plist. Logs the container class, and for arrays the per-element class plus the
// resolved bundle identifier (unwrapping one level of page nesting). Never
// mutates anything. Gated behind verbose like every other CSLog.
static void CSDescribeIconShape(const char *label, id container) {
    if (!CSVerboseEnabled()) return;
    if (!container) {
        CSLog("SHAPE %s = (nil)", label);
        return;
    }
    CSLog("SHAPE %s class=%s", label, object_getClassName(container));

    // CRSIconLayoutState-like object: expose pages/icons/hiddenIcons surface.
    if ([container respondsToSelector:@selector(pages)] ||
        [container respondsToSelector:@selector(hiddenIcons)]) {
        id pages = [container respondsToSelector:@selector(pages)]
            ? ((id (*)(id, SEL))objc_msgSend)(container, @selector(pages)) : nil;
        id hidden = [container respondsToSelector:@selector(hiddenIcons)]
            ? ((id (*)(id, SEL))objc_msgSend)(container, @selector(hiddenIcons)) : nil;
        CSLog("SHAPE %s.pages class=%s count=%lu; .hiddenIcons class=%s count=%lu",
              label, pages ? object_getClassName(pages) : "(nil)",
              [pages respondsToSelector:@selector(count)] ? (unsigned long)[pages count] : 0UL,
              hidden ? object_getClassName(hidden) : "(nil)",
              [hidden respondsToSelector:@selector(count)] ? (unsigned long)[hidden count] : 0UL);
        if ([pages isKindOfClass:NSArray.class] && [pages count] > 0) {
            id page0 = [pages firstObject];
            id icons = [page0 respondsToSelector:@selector(icons)]
                ? ((id (*)(id, SEL))objc_msgSend)(page0, @selector(icons)) : nil;
            CSLog("SHAPE %s.pages[0] class=%s icons class=%s count=%lu",
                  label, object_getClassName(page0),
                  icons ? object_getClassName(icons) : "(nil)",
                  [icons respondsToSelector:@selector(count)] ? (unsigned long)[icons count] : 0UL);
            for (id icon in ([icons isKindOfClass:NSArray.class] ? icons : @[])) {
                CSLog("SHAPE %s.pages[0].icon class=%s bundle=%s",
                      label, object_getClassName(icon),
                      CSIconBundleIdentifier(icon).UTF8String ?: "(?)");
            }
        }
        if ([hidden isKindOfClass:NSArray.class]) {
            for (id icon in (NSArray *)hidden) {
                CSLog("SHAPE %s.hiddenIcons.icon class=%s bundle=%s",
                      label, object_getClassName(icon),
                      CSIconBundleIdentifier(icon).UTF8String ?: "(?)");
            }
        }
    }

    if ([container isKindOfClass:NSArray.class]) {
        NSArray *array = container;
        CSLog("SHAPE %s isArray count=%lu", label, (unsigned long)array.count);
        NSUInteger index = 0;
        for (id element in array) {
            if ([element isKindOfClass:NSArray.class]) {
                // A page: array of icons/strings.
                CSLog("SHAPE %s[%lu] nested-array count=%lu", label,
                      (unsigned long)index, (unsigned long)[element count]);
                for (id inner in (NSArray *)element) {
                    CSLog("SHAPE %s[%lu].icon class=%s bundle=%s", label,
                          (unsigned long)index, object_getClassName(inner),
                          CSIconBundleIdentifier(inner).UTF8String ?: "(?)");
                }
            } else {
                CSLog("SHAPE %s[%lu] class=%s bundle=%s", label, (unsigned long)index,
                      object_getClassName(element),
                      CSIconBundleIdentifier(element).UTF8String ?: "(?)");
            }
            index++;
        }
    }
}

__attribute__((unused))
static NSSet *CSCurrentDashboardBundleIdentifiers(void) {
    Class controllerClass = CSLookupClass("DBApplicationController");
    SEL sharedSelector = @selector(sharedInstance);
    SEL allSelector = @selector(allApplications);
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return [NSSet set];
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    if (![controller respondsToSelector:allSelector]) return [NSSet set];
    id applications = ((id (*)(id, SEL))objc_msgSend)(controller, allSelector);
    NSMutableSet *identifiers = [NSMutableSet set];
    for (id application in [applications isKindOfClass:NSArray.class] ? applications : @[]) {
        NSString *identifier = CSFactoryObjectBundleIdentifier(application);
        if (identifier) [identifiers addObject:identifier];
    }
    return identifiers;
}

static id CSFilterIconLayoutState(id state) {
    if (!state) return state;
    // Icon-layout rewriting is disabled. Persisting a filtered per-vehicle icon
    // state corrupted the real dashboard once a car was actually connected —
    // it dropped legitimate system icons, emptied the Settings Customize list,
    // and left CarPlay unable to build a valid dashboard (failed connects, then
    // a SpringBoard crash). Enable/disable sync is handled entirely through
    // DBApplicationController, so this filter is now a pass-through.
    static const BOOL kIconLayoutFilteringDisabled = YES;
    if (kIconLayoutFilteringDisabled) return state;
    if (!CSIsIconLayoutProcess()) return state;
    SEL pagesSelector = @selector(pages);
    SEL hiddenSelector = @selector(hiddenIcons);
    if (![state respondsToSelector:pagesSelector] || ![state respondsToSelector:hiddenSelector]) {
        return state;
    }

    // Nothing to hide unless the user has disabled or uninstalled a Carsurf app.
    BOOL hasBlockedRuntimeApps = gUninstalledRuntimeIdentifiers.count > 0 ||
                                 gDashboardRemovedIdentifiers.count > 0;
    if (!hasBlockedRuntimeApps) return state;
    id pages = ((id (*)(id, SEL))objc_msgSend)(state, pagesSelector);
    Class pageClass = CSLookupClass("CRSIconLayoutPage");
    SEL iconsSelector = @selector(icons);
    SEL pageInit = @selector(initWithIcons:);
    if (!pageClass || ![pageClass instancesRespondToSelector:pageInit] ||
        ![pages isKindOfClass:NSArray.class]) return state;

    NSMutableArray *filteredPages = [NSMutableArray arrayWithCapacity:[pages count]];
    BOOL changed = NO;
    for (id page in pages) {
        id icons = [page respondsToSelector:iconsSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(page, iconsSelector) : nil;
        if (![icons isKindOfClass:NSArray.class]) {
            [filteredPages addObject:page];
            continue;
        }
        NSMutableArray *filteredIcons = [NSMutableArray arrayWithCapacity:[icons count]];
        for (id icon in icons) {
            NSString *identifier = CSIconBundleIdentifier(icon);
            // Only remove icons Carsurf is responsible for: apps the user
            // explicitly disabled (tombstoned) or Carsurf-managed apps that were
            // uninstalled. The old "not in DBApplicationController.allApplications"
            // rule also purged legitimate system CarPlay icons that list omits
            // (com.apple.cardisplay.OEM, com.apple.cardisplay.nowplaying, …),
            // which — once a real vehicle connection let this state persist —
            // emptied the dashboard and the Settings Customize list.
            if (identifier && (CSRuntimeApplicationWasUninstalled(identifier) ||
                               CSRuntimeApplicationWasRemovedFromDashboard(identifier))) {
                changed = YES;
                CSLog("CarPlay filtered disabled icon %s from icon-layout state",
                      identifier.UTF8String);
                continue;
            }
            [filteredIcons addObject:icon];
        }
        id filteredPage = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit,
                                                                filteredIcons);
        [filteredPages addObject:filteredPage ?: page];
    }
    if (!changed) return state;

    id hidden = ((id (*)(id, SEL))objc_msgSend)(state, hiddenSelector);
    Class stateClass = object_getClass(state);
    SEL stateInit = @selector(initWithPages:hiddenIcons:);
    if (![stateClass instancesRespondToSelector:stateInit]) return state;
    id filteredState = ((id (*)(id, SEL, id, id))objc_msgSend)([stateClass alloc], stateInit,
                                                                 filteredPages, hidden);
    if (!filteredState) return state;

    SEL getters[] = { @selector(rows), @selector(columns), @selector(displaysOEMIcon),
                     @selector(oemIconLabel) };
    SEL setters[] = { @selector(setRows:), @selector(setColumns:),
                     @selector(setDisplaysOEMIcon:), @selector(setOemIconLabel:) };
    if ([filteredState respondsToSelector:setters[0]] && [state respondsToSelector:getters[0]])
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(filteredState, setters[0],
            ((NSUInteger (*)(id, SEL))objc_msgSend)(state, getters[0]));
    if ([filteredState respondsToSelector:setters[1]] && [state respondsToSelector:getters[1]])
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(filteredState, setters[1],
            ((NSUInteger (*)(id, SEL))objc_msgSend)(state, getters[1]));
    if ([filteredState respondsToSelector:setters[2]] && [state respondsToSelector:getters[2]])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(filteredState, setters[2],
            ((BOOL (*)(id, SEL))objc_msgSend)(state, getters[2]));
    if ([filteredState respondsToSelector:setters[3]] && [state respondsToSelector:getters[3]])
        ((void (*)(id, SEL, id))objc_msgSend)(filteredState, setters[3],
            ((id (*)(id, SEL))objc_msgSend)(state, getters[3]));
    return filteredState;
}

static void (*orig_iconLayoutSetState)(id, SEL, id, id);
static id (*orig_iconLayoutServiceInitWithDelegate)(id, SEL, id);
static id cs_iconLayoutServiceInitWithDelegate(id self, SEL _cmd, id delegate) {
    id service = orig_iconLayoutServiceInitWithDelegate(self, _cmd, delegate);
    CSRememberIconLayoutService(service);
    CSLog("CarPlay icon-layout service initialized class=%s",
          service ? object_getClassName(service) : "(nil)");
    // The service is created before its vehicle connection is attached. Give
    // that private handshake time to complete, then reconcile while the same
    // physical CarPlay session remains connected.
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"] && service) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CSRefreshDashboardIconLayout();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CSRefreshDashboardIconLayout();
        });
    }
    return service;
}

static void CSApplyHiddenIconsDelta(NSSet<NSString *> *previous);
static NSSet *gPendingHiddenIconsDelta;

// Extract a per-vehicle identifier from a live connection object. The live
// icon-layout connection carries the vehicle UUID, which is the same id DashBoard
// passes to fetch/setIconState. Capturing it here — before the first fetch —
// closes the window where a toggle right after connect has no vehicle id.
static id CSVehicleIdentifierFromConnection(id connection) {
    if (!connection || connection == [NSNull null]) return nil;
    SEL selectors[] = { @selector(vehicleID), @selector(vehicleIdentifier),
                        @selector(identifier), sel_getUid("certificateSerial"),
                        sel_getUid("serial") };
    for (NSUInteger i = 0; i < sizeof(selectors) / sizeof(selectors[0]); i++) {
        SEL selector = selectors[i];
        if (![connection respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(connection, selector);
        if (value && value != [NSNull null]) return value;
    }
    return nil;
}

// Fall back to the persisted per-vehicle icon-state plist filename. Its name is
// "<vehicleUUID>-CarDisplayIconState.plist", so the UUID is readable even before
// the live CRS/SBS connection is established — the CRS connection is intermittent
// on the simulator, but the plist exists once a vehicle has connected at least
// once. Prefer the most recently modified plist (the active vehicle).
static NSString *CSPersistedVehicleIdentifier(void) {
    NSString *dir = @"/var/mobile/Library/SpringBoard";
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSString *suffix = @"-CarDisplayIconState.plist";
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *file in files) {
        if (![file hasSuffix:suffix]) continue;
        NSString *path = [dir stringByAppendingPathComponent:file];
        NSDate *date = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                        error:nil][NSFileModificationDate];
        if (!date) continue;
        if (!bestDate || [date compare:bestDate] == NSOrderedDescending) {
            bestDate = date;
            best = [file substringToIndex:file.length - suffix.length];
        }
    }
    return best;
}

static void CSApplyPendingHiddenIconsDelta(void) {
    if (!gPendingHiddenIconsDelta) return;
    NSSet *pending = gPendingHiddenIconsDelta;
    gPendingHiddenIconsDelta = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        CSApplyHiddenIconsDelta(pending);
    });
}

static void (*orig_iconLayoutServiceDidReceiveConnection)(id, SEL, id, id, id);
static void cs_iconLayoutServiceDidReceiveConnection(id self, SEL _cmd,
                                                     id listener, id connection, id context) {
    CSRememberIconLayoutService(self);
    id vehicleID = CSVehicleIdentifierFromConnection(connection);
    if (vehicleID) {
        gLastIconLayoutVehicleID = vehicleID;
        CSLog("CarPlay icon-layout captured vehicle id from connection %s",
              [vehicleID description].UTF8String ?: "(nil)");
    }
    CSLog("CarPlay icon-layout service received connection class=%s",
          connection ? object_getClassName(connection) : "(nil)");
    orig_iconLayoutServiceDidReceiveConnection(self, _cmd, listener, connection, context);
    CSApplyPendingHiddenIconsDelta();
}

static void (*orig_iconLayoutServiceAddConnection)(id, SEL, id);
static void cs_iconLayoutServiceAddConnection(id self, SEL _cmd, id connection) {
    CSRememberIconLayoutService(self);
    id vehicleID = CSVehicleIdentifierFromConnection(connection);
    if (vehicleID) {
        gLastIconLayoutVehicleID = vehicleID;
        CSLog("CarPlay icon-layout captured vehicle id from add-connection %s",
              [vehicleID description].UTF8String ?: "(nil)");
    }
    CSLog("CarPlay icon-layout service queue add connection class=%s",
          connection ? object_getClassName(connection) : "(nil)");
    orig_iconLayoutServiceAddConnection(self, _cmd, connection);
    CSApplyPendingHiddenIconsDelta();
}

static void (*orig_iconLayoutServiceRemoveConnection)(id, SEL, id);
static void cs_iconLayoutServiceRemoveConnection(id self, SEL _cmd, id connection) {
    CSLog("CarPlay icon-layout service queue remove connection class=%s",
          connection ? object_getClassName(connection) : "(nil)");
    for (NSString *frame in NSThread.callStackSymbols) CSLog("icon-layout remove caller %s",
                                                              frame.UTF8String);
    orig_iconLayoutServiceRemoveConnection(self, _cmd, connection);
}

static void (*orig_iconLayoutControllerSetConnection)(id, SEL, id);
static id (*orig_iconLayoutControllerInit)(id, SEL);
static id cs_iconLayoutControllerInit(id self, SEL _cmd) {
    id controller = orig_iconLayoutControllerInit(self, _cmd);
    CSRememberIconLayoutController(controller);
    CSLog("CarPlay icon-layout controller initialized class=%s",
          controller ? object_getClassName(controller) : "(nil)");
    if (controller && CSIsIconLayoutProcess()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CSRefreshDashboardIconLayout();
        });
    }
    return controller;
}

static void cs_iconLayoutControllerSetConnection(id self, SEL _cmd, id connection) {
    CSRememberIconLayoutController(self);
    orig_iconLayoutControllerSetConnection(self, _cmd, connection);
    NSArray *identifiers = CSIconLayoutControllerVehicleIdentifiers(self);
    CSLog("CarPlay icon-layout controller connection class=%s vehicle-identifiers=%s",
          connection ? object_getClassName(connection) : "(nil)",
          [[identifiers componentsJoinedByString:@", "] UTF8String] ?: "(none)");
}

static void cs_iconLayoutSetState(id self, SEL _cmd, id state, id vehicleID) {
    if (vehicleID && vehicleID != [NSNull null]) gLastIconLayoutVehicleID = vehicleID;
    CSApplyPendingHiddenIconsDelta();
    // Capture a valid state before DashBoard's later connect-time empty write.
    // The empty write itself still passes through untouched; the snapshot is
    // only used by the read-side fetch fallback below.
    if (CSIconStateVisibleCount(state) > 0) {
        CSRememberGoodIconState(state, vehicleID);
    }
    id stateToWrite = state;
    if (CSIconStateVisibleCount(state) == 0) {
        NSString *key = CSIconStateVehicleKey(vehicleID);
        id fallback = CSLastGoodIconStateForVehicle(vehicleID);
        CSLog("icon-layout empty set lookup key=%s vehicle-class=%s fallback=%s "
              "last-count=%lu entries=%lu",
              key.UTF8String ?: "(nil)",
              vehicleID ? object_getClassName(vehicleID) : "(nil)",
              fallback ? object_getClassName(fallback) : "(nil)",
              (unsigned long)gLastGoodIconCount,
              (unsigned long)gLastGoodIconStates.count);
        if (!fallback) fallback = CSPersistedIconStateForVehicle(state, vehicleID);
        NSUInteger fallbackCount = CSIconStateVisibleCount(fallback);
        if (fallback && fallbackCount > 0) {
            // Keep calling DashBoard's real writer so its model and persistence
            // stay synchronized; only replace the transient connect-time empty
            // payload with the valid state it just fetched for this vehicle.
            // Dropping the write was the earlier PAC/desynchronization path.
            stateToWrite = fallback;
            CSLog("CarPlay icon-layout replaced transient empty set state with "
                  "last good vehicle state (count=%lu)",
                  (unsigned long)fallbackCount);
        }
    }
    CSLog("CarPlay icon-layout set state process=%s vehicle=%s state=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)",
          state ? object_getClassName(state) : "(nil)");
    CSDescribeIconShape("setState.state", state);
    CSDescribeIconShape("setState.nativePayload", stateToWrite);
    for (NSString *frame in NSThread.callStackSymbols) CSLog("icon-layout set caller %s",
                                                              frame.UTF8String);

    // Do not block DashBoard's writer. The only intervention is the
    // object-preserving, per-vehicle fallback above for its transient empty
    // connect/relaunch payload; all ordinary user Customize writes pass through
    // unchanged. Enable/disable deltas remain separate.
    orig_iconLayoutSetState(self, _cmd, CSFilterIconLayoutState(stateToWrite), vehicleID);
}

static void (*orig_iconLayoutServiceFetchState)(id, SEL, id, id);
static void (*orig_iconLayoutControllerFetchState)(id, SEL, id, id);
static void (*orig_iconLayoutSetOrder)(id, SEL, id, id, id);
static void cs_iconLayoutFetchState(id self, SEL _cmd, id vehicleID, id completion,
                                    void (*original)(id, SEL, id, id)) {
    if (vehicleID && vehicleID != [NSNull null]) gLastIconLayoutVehicleID = vehicleID;
    CSApplyPendingHiddenIconsDelta();
    CSLog("CarPlay icon-layout fetch state process=%s vehicle=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)");
    if (!completion) {
        original(self, _cmd, vehicleID, completion);
        return;
    }
    void (^wrapped)(id, id) = ^(id state, id error) {
        // Dump the real per-vehicle state shape, and remember it as the last good
        // state (reference for the empty-overwrite guard) when it is non-empty.
        CSDescribeIconShape("fetchState.result", state);
        id deliveredState = state;
        if (!error) {
            NSUInteger count = CSIconStateVisibleCount(state);
            if (count > 0) {
                CSRememberGoodIconState(state, vehicleID);
            } else {
                // Read-side only: never block or replace setIconState. This
                // avoids desynchronizing DashBoard's writer while preventing
                // its transient connect-time empty state from making Customize
                // render as an empty list on the following fetch.
                id fallback = CSLastGoodIconStateForVehicle(vehicleID);
                if (fallback && gLastGoodIconCount > 0) {
                    deliveredState = fallback;
                    CSLog("CarPlay icon-layout fetch replaced transient empty state "
                          "with last good vehicle state (count=%lu)",
                          (unsigned long)gLastGoodIconCount);
                }
            }
        }
        ((void (^)(id, id))completion)(CSFilterIconLayoutState(deliveredState), error);
    };
    original(self, _cmd, vehicleID, wrapped);
}

static void cs_iconLayoutServiceFetchState(id self, SEL _cmd, id vehicleID, id completion) {
    cs_iconLayoutFetchState(self, _cmd, vehicleID, completion, orig_iconLayoutServiceFetchState);
}

static void cs_iconLayoutControllerFetchState(id self, SEL _cmd, id vehicleID, id completion) {
    cs_iconLayoutFetchState(self, _cmd, vehicleID, completion, orig_iconLayoutControllerFetchState);
}

static void cs_iconLayoutSetOrder(id self, SEL _cmd, id iconOrder, id hiddenIcons, id vehicleID) {
    // Pass the user's Customize arrangement through untouched. Rewriting the
    // hidden set here corrupted the persisted per-vehicle layout; disabled apps
    // are kept off the dashboard through DBApplicationController instead.
    //
    // Read-only instrumentation for the hiddenIcons mutation design: this is the
    // sanctioned native Customize writer. Dump the exact runtime shape of both
    // arguments (iconOrder pages, hiddenIcons) so the mutation build can call it
    // with the confirmed types instead of guessing from the persisted plist.
    CSLog("SETORDER process=%s vehicle=%s self=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)", object_getClassName(self));
    CSDescribeIconShape("setOrder.iconOrder", iconOrder);
    CSDescribeIconShape("setOrder.hiddenIcons", hiddenIcons);
    orig_iconLayoutSetOrder(self, _cmd, iconOrder, hiddenIcons, vehicleID);
}

static void CSInstallIconLayoutStateHooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class service = CSLookupClass("CRSIconLayoutService");
    if (service) {
        CSSwizzleInstanceMethod(service, @selector(initWithDelegate:),
                                 (IMP)cs_iconLayoutServiceInitWithDelegate,
                                 (IMP *)&orig_iconLayoutServiceInitWithDelegate);
        CSSwizzleInstanceMethod(service, @selector(listener:didReceiveConnection:withContext:),
                                 (IMP)cs_iconLayoutServiceDidReceiveConnection,
                                 (IMP *)&orig_iconLayoutServiceDidReceiveConnection);
        CSSwizzleInstanceMethod(service, sel_getUid("_connectionQueue_addConnection:"),
                                 (IMP)cs_iconLayoutServiceAddConnection,
                                 (IMP *)&orig_iconLayoutServiceAddConnection);
        CSSwizzleInstanceMethod(service, sel_getUid("_connectionQueue_removeConnection:"),
                                 (IMP)cs_iconLayoutServiceRemoveConnection,
                                 (IMP *)&orig_iconLayoutServiceRemoveConnection);
        CSSwizzleInstanceMethod(service, @selector(setIconState:forVehicleID:),
                                 (IMP)cs_iconLayoutSetState,
                                 (IMP *)&orig_iconLayoutSetState);
        // Isolation switch: the native fetch path is crashing before/around
        // the completion callback on the connected device. Leave the native
        // fetch untouched for one run to distinguish a CRS wrapper fault from
        // the underlying persisted state.
        static const BOOL kDisableFetchWrapperForIsolation = YES;
        if (!kDisableFetchWrapperForIsolation) {
            CSSwizzleInstanceMethod(service, @selector(fetchIconStateForVehicleID:completion:),
                                     (IMP)cs_iconLayoutServiceFetchState,
                                     (IMP *)&orig_iconLayoutServiceFetchState);
        }
    }
    Class controller = CSLookupClass("CRSIconLayoutController");
    if (controller) {
        CSSwizzleInstanceMethod(controller, @selector(init),
                                 (IMP)cs_iconLayoutControllerInit,
                                 (IMP *)&orig_iconLayoutControllerInit);
        CSSwizzleInstanceMethod(controller, @selector(setConnection:),
                                 (IMP)cs_iconLayoutControllerSetConnection,
                                 (IMP *)&orig_iconLayoutControllerSetConnection);
        CSSwizzleInstanceMethod(controller, @selector(setIconOrder:hiddenIcons:forVehicleID:),
                                 (IMP)cs_iconLayoutSetOrder,
                                 (IMP *)&orig_iconLayoutSetOrder);
        static const BOOL kDisableFetchWrapperForIsolation = YES;
        if (!kDisableFetchWrapperForIsolation) {
            CSSwizzleInstanceMethod(controller, @selector(fetchIconStateForVehicleID:completion:),
                                     (IMP)cs_iconLayoutControllerFetchState,
                                     (IMP *)&orig_iconLayoutControllerFetchState);
        }
    }
    if (service || controller) installed = YES;
}

// ---------------------------------------------------------------------------
// Surgical hiddenIcons live-sync (service path, object-preserving).
//
// Confirmed on iOS 18.5 with a connected head unit: the live per-vehicle layout
// is a CRSIconLayoutState whose .pages[N].icons are CRSApplicationIcon objects
// and whose .hiddenIcons is a parallel icon array. The writer is
// -[CRSIconLayoutService setIconState:forVehicleID:] (NOT the controller's
// setIconOrder:; the controller list is empty in the CarPlay UI process, which
// is why an earlier controller-targeted attempt computed a delta but never
// wrote). The Settings > Customize list is the union of visible + hidden icons.
//
// Hiding a disabled app therefore means rebuilding the state while MOVING that
// one app's existing CRSApplicationIcon object from its page into hiddenIcons —
// every other icon OBJECT (system icons included) is carried across unchanged,
// so Customize stays populated. This is the crucial difference from the old
// CSFilterIconLayoutState, which rebuilt pages from a derived/filtered list and
// dropped the icons it could not account for, emptying Customize.
static BOOL CSHiddenIconsSyncEnabled(void) { return YES; }

// Carry the CRSIconLayoutState metadata (grid + OEM icon) onto a rebuilt state,
// exactly as the previous filter did — only pages/hiddenIcons differ.
static void CSCopyIconStateMetadata(id dst, id src) {
    SEL getters[] = { @selector(rows), @selector(columns), @selector(displaysOEMIcon),
                     @selector(oemIconLabel) };
    SEL setters[] = { @selector(setRows:), @selector(setColumns:),
                     @selector(setDisplaysOEMIcon:), @selector(setOemIconLabel:) };
    if ([dst respondsToSelector:setters[0]] && [src respondsToSelector:getters[0]])
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(dst, setters[0],
            ((NSUInteger (*)(id, SEL))objc_msgSend)(src, getters[0]));
    if ([dst respondsToSelector:setters[1]] && [src respondsToSelector:getters[1]])
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(dst, setters[1],
            ((NSUInteger (*)(id, SEL))objc_msgSend)(src, getters[1]));
    if ([dst respondsToSelector:setters[2]] && [src respondsToSelector:getters[2]])
        ((void (*)(id, SEL, BOOL))objc_msgSend)(dst, setters[2],
            ((BOOL (*)(id, SEL))objc_msgSend)(src, getters[2]));
    if ([dst respondsToSelector:setters[3]] && [src respondsToSelector:getters[3]])
        ((void (*)(id, SEL, id))objc_msgSend)(dst, setters[3],
            ((id (*)(id, SEL))objc_msgSend)(src, getters[3]));
}

// Rebuild a CRSIconLayoutState with the enable/disable delta applied by moving
// existing icon objects between pages and hiddenIcons. Returns nil when nothing
// changed or the state surface is not as expected (caller then leaves it alone).
static id CSStateWithHiddenDelta(id state, NSSet<NSString *> *disabled,
                                 NSSet<NSString *> *enabled) {
    Class stateClass = object_getClass(state);
    Class pageClass = CSLookupClass("CRSIconLayoutPage");
    SEL pageInit = @selector(initWithIcons:);
    SEL stateInit = @selector(initWithPages:hiddenIcons:);
    if (!pageClass || ![pageClass instancesRespondToSelector:pageInit] ||
        ![stateClass instancesRespondToSelector:stateInit] ||
        ![state respondsToSelector:@selector(pages)]) {
        return nil;
    }
    id pages = ((id (*)(id, SEL))objc_msgSend)(state, @selector(pages));
    if (![pages isKindOfClass:NSArray.class]) return nil;
    id hiddenOrig = [state respondsToSelector:@selector(hiddenIcons)]
        ? ((id (*)(id, SEL))objc_msgSend)(state, @selector(hiddenIcons)) : nil;
    NSMutableArray *hidden = [hiddenOrig isKindOfClass:NSArray.class]
        ? [hiddenOrig mutableCopy] : [NSMutableArray new];

    NSMutableArray *newPages = [NSMutableArray arrayWithCapacity:[pages count]];
    BOOL changed = NO;

    // Disable: drop the app's icon object from its page, add it to hiddenIcons.
    for (id page in pages) {
        id icons = [page respondsToSelector:@selector(icons)]
            ? ((id (*)(id, SEL))objc_msgSend)(page, @selector(icons))
            : ([page isKindOfClass:NSArray.class] ? page : nil);
        NSMutableArray *keep = [NSMutableArray new];
        for (id icon in ([icons isKindOfClass:NSArray.class] ? icons : @[])) {
            NSString *bid = CSIconBundleIdentifier(icon);
            if (bid.length && [disabled containsObject:bid]) {
                if (![hidden containsObject:icon]) [hidden addObject:icon];
                changed = YES;
                CSLog("hiddenIcons sync: hiding %s", bid.UTF8String);
            } else {
                [keep addObject:icon];
            }
        }
        id newPage = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit, keep);
        [newPages addObject:newPage ?: page];
    }

    // Enable: pull the app's icon object back out of hiddenIcons into a page.
    NSMutableArray *unhide = [NSMutableArray new];
    for (id icon in [hidden copy]) {
        NSString *bid = CSIconBundleIdentifier(icon);
        if (bid.length && [enabled containsObject:bid]) {
            [unhide addObject:icon];
            [hidden removeObject:icon];
            changed = YES;
            CSLog("hiddenIcons sync: un-hiding %s", bid.UTF8String);
        }
    }
    if (unhide.count > 0) {
        if (newPages.count == 0) {
            id p = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit, unhide);
            if (p) [newPages addObject:p];
        } else {
            id lastPage = newPages.lastObject;
            id lastIcons = [lastPage respondsToSelector:@selector(icons)]
                ? ((id (*)(id, SEL))objc_msgSend)(lastPage, @selector(icons)) : nil;
            NSMutableArray *merged = [lastIcons isKindOfClass:NSArray.class]
                ? [lastIcons mutableCopy] : [NSMutableArray new];
            [merged addObjectsFromArray:unhide];
            id rebuilt = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit, merged);
            if (rebuilt) [newPages replaceObjectAtIndex:newPages.count - 1 withObject:rebuilt];
        }
    }

    // Fresh enable: an enabled app that is nowhere in the layout (not in any page,
    // not hidden) needs its icon OBJECT created and appended — the roster injection
    // alone leaves the grid without it, so hide/unhide would no-op. Build a
    // CRSApplicationIcon from the bundle identifier and add it to the last page.
    for (NSString *bid in enabled) {
        if (bid.length == 0 || CSLayoutStateContainsBundle(state, bid)) continue;
        Class iconClass = CSLookupClass("CRSApplicationIcon");
        SEL iconInit = @selector(initWithBundleIdentifier:);
        if (!iconClass || ![iconClass instancesRespondToSelector:iconInit]) continue;
        id icon = ((id (*)(id, SEL, id))objc_msgSend)([iconClass alloc], iconInit, bid);
        if (!icon) continue;
        NSMutableArray *allIcons = [NSMutableArray new];
        if (newPages.count > 0) {
            id lastPage = newPages.lastObject;
            id lastIcons = [lastPage respondsToSelector:@selector(icons)]
                ? ((id (*)(id, SEL))objc_msgSend)(lastPage, @selector(icons)) : nil;
            if ([lastIcons isKindOfClass:NSArray.class]) [allIcons addObjectsFromArray:lastIcons];
        }
        [allIcons addObject:icon];
        id rebuilt = ((id (*)(id, SEL, id))objc_msgSend)([pageClass alloc], pageInit, allIcons);
        if (!rebuilt) continue;
        if (newPages.count > 0) [newPages replaceObjectAtIndex:newPages.count - 1 withObject:rebuilt];
        else [newPages addObject:rebuilt];
        changed = YES;
        CSLog("hiddenIcons sync: adding %s (fresh enable)", bid.UTF8String);
    }

    if (!changed) return nil;
    id newState = ((id (*)(id, SEL, id, id))objc_msgSend)([stateClass alloc], stateInit,
                                                           newPages, hidden);
    if (!newState) return nil;
    CSCopyIconStateMetadata(newState, state);
    return newState;
}

// Fetch a vehicle's current layout, apply the delta object-preserving, and write
// it back through the service. Runs the whole cycle on the service that owns the
// live vehicle connection.
static void CSApplyHiddenDeltaToService(id service, id vehicleID,
                                        NSSet<NSString *> *disabled,
                                        NSSet<NSString *> *enabled) {
    SEL fetchSel = @selector(fetchIconStateForVehicleID:completion:);
    SEL setSel = @selector(setIconState:forVehicleID:);
    if (![service respondsToSelector:fetchSel] || ![service respondsToSelector:setSel]) {
        CSLog("hiddenIcons sync: service %s missing fetch/set selectors",
              object_getClassName(service));
        return;
    }
    void (^completion)(id, id) = ^(id state, id error) {
        if (!state || error) {
            CSLog("hiddenIcons sync: fetch failed vehicle=%s error=%s",
                  [vehicleID description].UTF8String ?: "(nil)",
                  error ? object_getClassName(error) : "nil-state");
            return;
        }
        id newState = CSStateWithHiddenDelta(state, disabled, enabled);
        if (!newState) {
            CSLog("hiddenIcons sync: no applicable change for vehicle=%s (state=%s)",
                  [vehicleID description].UTF8String ?: "(nil)",
                  object_getClassName(state));
            return;
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(service, setSel, newState, vehicleID);
        CSLog("hiddenIcons sync: wrote new state for vehicle=%s",
              [vehicleID description].UTF8String ?: "(nil)");
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, fetchSel, vehicleID, completion);
}

// DashBoard may reconcile the persisted icon state back to all-visible after a
// successful write. Re-assert the same object-preserving move a few times over
// the next minute, then stop; this covers the observed reconnect/customize
// reconciliation without creating a permanent write loop or a roster reload.
static void CSVerifyHiddenDeltaAfterDelay(id service, id vehicleID,
                                          NSSet<NSString *> *disabled,
                                          NSSet<NSString *> *enabled,
                                          NSUInteger attempt) {
    if (attempt >= 4 || !service || !vehicleID) return;
    static const NSTimeInterval delays[] = { 2.0, 10.0, 30.0, 60.0 };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(delays[attempt] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SEL fetchSel = @selector(fetchIconStateForVehicleID:completion:);
        SEL setSel = @selector(setIconState:forVehicleID:);
        if (![service respondsToSelector:fetchSel] || ![service respondsToSelector:setSel]) return;
        void (^completion)(id, id) = ^(id state, id error) {
            if (error || !state) return;
            id repaired = CSStateWithHiddenDelta(state, disabled, enabled);
            if (!repaired) return;
            ((void (*)(id, SEL, id, id))objc_msgSend)(service, setSel, repaired, vehicleID);
            CSLog("hiddenIcons sync: reasserted state for vehicle=%s attempt=%lu",
                  [vehicleID description].UTF8String ?: "(nil)",
                  (unsigned long)(attempt + 1));
            CSVerifyHiddenDeltaAfterDelay(service, vehicleID, disabled, enabled, attempt + 1);
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(service, fetchSel, vehicleID, completion);
    });
}

// Drive the hiddenIcons delta across the tracked icon-layout services (the live
// writer on iOS 18.5). Runs only in a CarPlay UI process that owns the graph.
static void CSApplyHiddenIconsDelta(NSSet<NSString *> *previous);
static NSUInteger gHiddenIconsSyncRetries;
// The first toggle right after connect sees no vehicle identifier (the live
// connection is still establishing, so gLastIconLayoutVehicleID /
// gLastVehicleIdentifier are nil and the service's connections hash is empty).
// Retry the same delta a few times so that first toggle is not silently lost.
static void CSRetryHiddenIconsDelta(NSSet<NSString *> *previous) {
    if (gHiddenIconsSyncRetries >= 6) { gHiddenIconsSyncRetries = 0; return; }
    gHiddenIconsSyncRetries++;
    CSLog("hiddenIcons sync: no vehicle id yet — retrying in 1.5s (%lu/6)",
          (unsigned long)gHiddenIconsSyncRetries);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CSApplyHiddenIconsDelta(previous);
    });
}

static void CSApplyHiddenIconsDelta(NSSet<NSString *> *previous) {
    if (!CSHiddenIconsSyncEnabled() || !CSIsIconLayoutProcess()) return;
    previous = previous ?: [NSSet set];
    NSSet *current = CSRuntimeEnabledIdentifierSet();
    NSMutableSet<NSString *> *disabled = [previous mutableCopy];
    [disabled minusSet:current];
    NSMutableSet<NSString *> *enabled = [current mutableCopy];
    [enabled minusSet:previous];
    if (disabled.count == 0 && enabled.count == 0) {
        CSLog("hiddenIcons sync: no delta (previous=%lu current=%lu prev=[%s] cur=[%s])",
              (unsigned long)previous.count, (unsigned long)current.count,
              [[previous.allObjects componentsJoinedByString:@","] UTF8String] ?: "",
              [[current.allObjects componentsJoinedByString:@","] UTF8String] ?: "");
        return;
    }
    CSLog("hiddenIcons sync: delta disabled=%lu enabled=%lu",
          (unsigned long)disabled.count, (unsigned long)enabled.count);

    // Collect the live services and the vehicle identifiers to address.
    NSMutableArray *services = [NSMutableArray new];
    if (gIconLayoutServices) {
        @synchronized (gIconLayoutServices) {
            [services addObjectsFromArray:gIconLayoutServices.allObjects];
        }
    }
    if (gLastIconLayoutService && ![services containsObject:gLastIconLayoutService]) {
        [services addObject:gLastIconLayoutService];
    }
    if (services.count == 0) {
        CSLog("hiddenIcons sync: no icon-layout service tracked in %s",
              NSProcessInfo.processInfo.processName.UTF8String);
        return;
    }
    BOOL applied = NO;
    for (id service in services) {
        NSArray *vehicleIdentifiers = CSIconLayoutVehicleIdentifiers(service);
        if (vehicleIdentifiers.count == 0 && gLastIconLayoutVehicleID) {
            vehicleIdentifiers = @[ gLastIconLayoutVehicleID ];
        }
        if (vehicleIdentifiers.count == 0 && gLastVehicleIdentifier) {
            vehicleIdentifiers = @[ gLastVehicleIdentifier ];
        }
        if (vehicleIdentifiers.count == 0) {
            NSString *persisted = CSPersistedVehicleIdentifier();
            if (persisted) {
                vehicleIdentifiers = @[ persisted ];
                CSLog("hiddenIcons sync: using persisted vehicle id %s",
                      persisted.UTF8String);
            }
        }
        if (vehicleIdentifiers.count == 0) {
            CSLog("hiddenIcons sync: service %s has no vehicle identifier",
                  object_getClassName(service));
            continue;
        }
        for (id vehicleID in vehicleIdentifiers) {
            CSApplyHiddenDeltaToService(service, vehicleID, disabled, enabled);
            CSVerifyHiddenDeltaAfterDelay(service, vehicleID, disabled, enabled, 0);
            applied = YES;
        }
    }
    if (applied) {
        gHiddenIconsSyncRetries = 0;
        gPendingHiddenIconsDelta = nil;
    } else {
        gPendingHiddenIconsDelta = previous;
        CSRetryHiddenIconsDelta(previous);
    }
}

static void CSInstallCarPlayApplicationLibraryRefresh(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    // CSPrefsStore posts the normal config notification and the explicit
    // application-library notification for one enable/disable transaction.
    // Both arrive on the CarPlay main queue; coalesce them so one preference
    // change cannot rebuild the dashboard twice (which caused duplicate roster
    // construction and visible CarPlay flicker in the device log).
    __block BOOL refreshScheduled = NO;
    void (^requestRefresh)(void) = ^{
        if (refreshScheduled) {
            CSTimingLog("dashboard refresh notification coalesced");
            return;
        }
        refreshScheduled = YES;
        CSTimingLog("dashboard refresh notification received");
        // Let CSConfig's own observer consume the plist write first. This is
        // the same short settling delay used for the normal reload event.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            refreshScheduled = NO;
            CSTimingLog("reload refresh dispatch begin");
            NSSet *previous = CSPreviousRuntimeEnabledIdentifiers();
            // The library invalidation forces DashBoard to rebuild its whole
            // roster, which reloads the CarPlay screen. That is only warranted
            // for a FRESH enable (a brand-new dashboard icon). For disables and
            // re-enables of apps already in the layout, the hiddenIcons live sync
            // below updates the grid in place — so skip the invalidation there and
            // the screen no longer reloads on every toggle.
            // The whole-library invalidation (screen reflow + alphabetical
            // re-sort) is retired for enable/disable toggles: the in-place
            // DBApplicationController mutation updates the grid without it. A
            // forced rebuild remains only for genuine uninstalls (handled in the
            // uninstall hook), never for a toggle.
            BOOL handledInPlace = CSRefreshDashboardApplicationController(previous);
            if (!handledInPlace) {
                CSLog("reload: in-place dashboard mutation incomplete — no forced "
                      "rebuild; the app lands on the next natural roster query");
            }
            // Move the disable/enable delta through the sanctioned Customize
            // writer (hiddenIcons): hides a disabled app / un-hides a re-enabled
            // one live, without emptying the Customize list. Sees the pre-baseline
            // `previous` set.
            CSApplyHiddenIconsDelta(previous);
            CSTimingLog("reload refresh dispatch end");
        });
    };

    int token = 0;
    notify_register_dispatch("com.pavunato.carsurf/reload", &token,
                             dispatch_get_main_queue(), ^(int t) {
        requestRefresh();
    });

    int applicationLibraryToken = 0;
    notify_register_dispatch("com.pavunato.carsurf/application-library-change",
                             &applicationLibraryToken,
                             dispatch_get_main_queue(), ^(int t) {
        CSLog("Carsurf enable/disable changed — requesting application-library refresh");
        requestRefresh();
    });
}

static NSArray *CSUninstallApplicationIdentifiers(id applications) {
    NSArray *items = nil;
    if ([applications isKindOfClass:NSArray.class]) {
        items = applications;
    } else if ([applications isKindOfClass:NSSet.class]) {
        items = [(NSSet *)applications allObjects];
    } else if (applications) {
        items = @[ applications ];
    }

    NSMutableArray<NSString *> *identifiers = [NSMutableArray new];
    for (id application in items) {
        NSString *identifier = CSFactoryObjectBundleIdentifier(application);
        if (identifier.length > 0) [identifiers addObject:identifier];
    }
    return identifiers;
}

static void cs_applicationsDidUninstall(id self, SEL _cmd, id applications) {
    orig_applicationsDidUninstall(self, _cmd, applications);

    NSArray *identifiers = CSUninstallApplicationIdentifiers(applications);
    CSMarkRuntimeApplicationsUninstalled(identifiers);
    CSLog("FBS application uninstall callback process=%s count=%lu ids=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          (unsigned long)identifiers.count,
          [[identifiers componentsJoinedByString:@", "] UTF8String] ?: "(unknown)");

    // The callback is delivered while SpringBoard is reconciling its
    // LaunchServices database. Prune immediately when possible, then retry
    // after the database transaction settles so the just-removed proxy cannot
    // leave a stale Carsurf allowlist entry behind. CSConfig gates this method
    // to SpringBoard; CarPlay's copy of the hook only invalidates its cache.
    if ([NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"]) {
        [CSConfig.sharedConfig pruneMissingApplications];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [CSConfig.sharedConfig pruneMissingApplications];
        });
    }
    // CarPlay can rebuild its filtered roster before the SpringBoard-side
    // preference notification reaches it. Remove the concrete dashboard rows
    // now and keep the IDs blocked from the in-memory admission loop until a
    // matching install callback clears them.
    CSRemoveDashboardApplications(identifiers);
    CSInvalidateCarPlayApplicationLibraries();
    BOOL isCarPlayUIProcess = CSIsIconLayoutProcess();
    if (isCarPlayUIProcess && identifiers.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CSRemoveDashboardApplications(identifiers);
            CSInvalidateCarPlayApplicationLibraries();
            CSRefreshDashboardIconLayout();
        });
    }
}

static void CSRemoveDashboardApplications(NSArray<NSString *> *identifiers) {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"] ||
        identifiers.count == 0) return;

    Class controllerClass = CSLookupClass("DBApplicationController");
    SEL sharedSelector = @selector(sharedInstance);
    SEL removeSelector = @selector(_removeApplicationWithBundleIdentifier:);
    if (!controllerClass || ![controllerClass respondsToSelector:sharedSelector]) return;
    id controller = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedSelector);
    if (!controller || ![controller respondsToSelector:removeSelector]) return;

    for (NSString *identifier in identifiers) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, removeSelector, identifier);
        CSLog("CarPlay Dashboard removed uninstalled app %s", identifier.UTF8String);
    }
}

/// Non-CarPlay apps that Carsurf inserts into the in-memory dashboard do not
/// necessarily appear in FBSApplicationLibrary's applicationsDidUninstall:
/// payload. Reconcile the small enabled set against LaunchServices as a
/// fallback, so those synthetic rows cannot survive an uninstall. This is
/// deliberately low frequency and only examines the user's enabled IDs.
static void CSInstallMissingApplicationMonitor(void) {
    static BOOL installed = NO;
    static dispatch_source_t timer;
    if (installed) return;
    installed = YES;

    if (![NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"] &&
        ![NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        return;
    }

    // Run the reconciliation off the main thread and at low frequency. This
    // used to be a 2 Hz main-queue timer, which polled LaunchServices for every
    // enabled app twice a second forever and made CarPlay animations hitch the
    // longer a session stayed connected. Uninstalls are handled promptly by the
    // applicationsDidUninstall: hook; this is only a slow fallback for synthetic
    // non-CarPlay rows that callback can miss, so a background 5 s sweep is
    // ample. The rare removal that follows a hit is marshalled back to main.
    BOOL isSpringBoard =
        [NSProcessInfo.processInfo.processName isEqualToString:@"SpringBoard"];
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              5 * NSEC_PER_SEC,
                              NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        NSArray<NSString *> *enabled = CSConfig.sharedConfig.enabledBundleIdentifiers;
        if (enabled.count == 0) return;

        NSMutableArray<NSString *> *missing = [NSMutableArray new];
        for (NSString *identifier in enabled) {
            if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) continue;
            id proxy = CSApplicationProxyForIdentifier(identifier);
            if (!proxy && !CSRuntimeApplicationWasUninstalled(identifier)) {
                [missing addObject:identifier];
            }
        }
        if (missing.count == 0) return;

        CSMarkRuntimeApplicationsUninstalled(missing);
        CSLog("LaunchServices reconciliation found %lu missing enabled app(s): %s",
              (unsigned long)missing.count,
              [[missing componentsJoinedByString:@", "] UTF8String]);
        if (isSpringBoard) {
            [CSConfig.sharedConfig pruneMissingApplications];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                CSRemoveDashboardApplications(missing);
                CSInvalidateCarPlayApplicationLibraries();
                CSRefreshDashboardIconLayout();
            });
        }
    });
    dispatch_resume(timer);
    CSLog("LaunchServices missing-app monitor installed for %s",
          NSProcessInfo.processInfo.processName.UTF8String);
}

static id cs_allInstalledApplications(id self, SEL _cmd) {
    CSTimingLog("FBS roster query begin");
    CSRememberApplicationLibrary(self);
    // Preserve the old set across the preference notification.  CarPlay may
    // query this method before the delayed controller refresh runs; replacing
    // the snapshot here would make the add/remove diff appear empty.
    CSRememberInitialRuntimeEnabledIdentifiers();
    id result = orig_allInstalledApplications(self, _cmd);
    CSTimingLog("FBS roster original returned class=%s count=%lu",
                object_getClassName(result),
                [result isKindOfClass:NSArray.class] ? (unsigned long)[result count] : 0UL);
    // The contract dump is a useful one-time investigation tool, but walking
    // every private Dashboard method and writing it to the async log on the
    // CarPlay main thread makes post-respring connection noticeably slower.
    // Keep the helper available for explicit diagnostics, not normal startup.
    // Do not run a fixed FPT construction probe here.  The preference entry can
    // outlive an uninstall, leaving an LSApplicationProxy without a display
    // name; probing that stale proxy traps inside FBSApplicationInfo before the
    // roster loop can apply its user-visible/install checks.  The guarded loop
    // below is the only construction path now.
    static BOOL loggedStack = NO;
    if (!loggedStack && [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        loggedStack = YES;
        CSLog("FBSApplicationLibrary allInstalledApplications CarPlay caller:");
        for (NSString *frame in NSThread.callStackSymbols) CSLog("    %s", frame.UTF8String);
    }
    if ([result isKindOfClass:NSArray.class]) {
        NSMutableSet<NSString *> *presentIdentifiers = [NSMutableSet set];
        for (id application in result) {
            NSString *identifier = CSFactoryObjectBundleIdentifier(application);
            if (identifier) [presentIdentifiers addObject:identifier];
            if (identifier && CSVerboseEnabled() &&
                ([CSConfig.sharedConfig isBundleEnabled:identifier] ||
                 [identifier isEqualToString:@"com.google.ios.youtube"])) {
                CSVLog("FBS roster item %s class=%s carPlayDeclaration=%d",
                       identifier.UTF8String, object_getClassName(application),
                       [application respondsToSelector:@selector(carPlayDeclaration)]);
            }
        }
        if (CSVerboseEnabled()) {
            NSUInteger enabledPresent = 0;
            for (NSString *identifier in CSConfig.sharedConfig.enabledBundleIdentifiers) {
                if ([presentIdentifiers containsObject:identifier]) enabledPresent++;
            }
            CSVLog("FBSApplicationLibrary allInstalledApplications count=%lu enabledPresent=%lu",
                   (unsigned long)[result count], (unsigned long)enabledPresent);
        }

        // CarPlay receives a filtered FBS library (34 entries on iOS 18.5),
        // while SpringBoard's library still contains enabled phone apps.
        // Construct the concrete Dashboard object that CarPlay uses for each
        // missing enabled app.  It inherits FBSApplicationInfo's proxy
        // initializer but adds Dashboard's private state and selector
        // contract.  Everything remains process-local.
        if (CSAllowExperimentalRosterInsertion() &&
            [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"] &&
            CSConfig.sharedConfig.isEnabled) {
            static dispatch_once_t cacheOnce;
            dispatch_once(&cacheOnce, ^{
                gExpandedRosterCacheLock = [NSObject new];
                gExpandedRosterCache = [NSMutableDictionary new];
            });
            NSMutableArray *expanded = [result mutableCopy];
            for (NSString *identifier in CSConfig.sharedConfig.enabledBundleIdentifiers) {
                if (![identifier isKindOfClass:NSString.class] ||
                    identifier.length == 0 || [presentIdentifiers containsObject:identifier]) {
                    continue;
                }
                if (CSRuntimeApplicationWasUninstalled(identifier)) {
                    CSLog("CarPlay roster blocked uninstalled enabled app %s",
                          identifier.UTF8String);
                    continue;
                }
                // An app that CarSurf already patched has a normal on-disk
                // CarPlay admission path.  It must not be reconstructed here:
                // the private FBS initializer asserts for some patched app
                // proxies when CarPlay builds its filtered library.  Runtime
                // roster insertion is reserved for enabled, unpatched apps
                // such as FPT Play.
                if (CSPatchStateIsPatched(identifier)) {
                    CSLog("CarPlay roster skipped enabled %s (already patched)",
                          identifier.UTF8String);
                    continue;
                }
                if (CSPatchStateIsNative(identifier) || CSPatchStateIsNativeBridged(identifier)) {
                    CSLog("CarPlay roster skipped enabled %s (already native/bridged)",
                          identifier.UTF8String);
                    continue;
                }

                // Reuse the previously constructed roster entry when we have one.
                // This skips the LaunchServices lookup and CarPlay declaration
                // build below, which is what made repeated dashboard queries
                // janky; the cache is dropped whenever the enabled set changes.
                id cachedInfo = nil;
                @synchronized (gExpandedRosterCacheLock) {
                    cachedInfo = gExpandedRosterCache[identifier];
                }
                if (cachedInfo) {
                    [expanded addObject:cachedInfo];
                    [presentIdentifiers addObject:identifier];
                    continue;
                }

                id proxy = CSApplicationProxyForIdentifier(identifier);
                NSString *applicationType = [proxy respondsToSelector:@selector(applicationType)]
                    ? ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(applicationType)) : nil;
                if ([applicationType isEqualToString:@"Internal"]) {
                    CSLog("CarPlay roster skipped enabled %s (applicationType=%s)",
                          identifier.UTF8String, applicationType.UTF8String);
                    continue;
                }
                if (!proxy) {
                    CSLog("CarPlay roster could not find enabled app %s", identifier.UTF8String);
                    continue;
                }
                NSString *visibilityReason = nil;
                if (!CSAppIsUserVisible(proxy, &visibilityReason)) {
                    CSLog("CarPlay roster skipped enabled %s (not user-visible: %s)",
                          identifier.UTF8String, visibilityReason.UTF8String ?: "unknown");
                    continue;
                }
                if (CSAppProxyHasNativeCarPlay(proxy)) {
                    CSLog("CarPlay roster skipped enabled %s (native CarPlay entitlement)",
                          identifier.UTF8String);
                    continue;
                }
                CSLog("CarPlay roster constructing enabled %s (applicationType=%s)",
                      identifier.UTF8String, applicationType.UTF8String ?: "unknown");
                id info = CSCreateDBApplicationInfoFromProxy(proxy);
                if (!info) {
                    CSLog("CarPlay roster could not construct DBApplicationInfo for %s",
                          identifier.UTF8String);
                    continue;
                }
                if (info && [info respondsToSelector:@selector(carPlayDeclaration)] &&
                    [info respondsToSelector:@selector(isValid)] &&
                    [info respondsToSelector:@selector(isInstalled)] &&
                    !((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isHidden))) {
                BOOL valid = ((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isValid));
                BOOL installed = ((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isInstalled));
                id declaration = ((id (*)(id, SEL))objc_msgSend)(
                    info, @selector(carPlayDeclaration));
                CSLog("%s DBApplicationInfo roster candidate valid=%d installed=%d declaration=%s class=%s",
                      identifier.UTF8String, valid, installed,
                      declaration ? "present" : "nil", object_getClassName(info));
                if (!valid || !installed || !declaration) continue;
                [expanded addObject:info];
                [presentIdentifiers addObject:identifier];
                @synchronized (gExpandedRosterCacheLock) {
                    gExpandedRosterCache[identifier] = info;
                    if (!gPinnedRosterInfos) gPinnedRosterInfos = [NSMutableArray new];
                    [gPinnedRosterInfos addObject:info];
                }
                CSLog("CarPlay FBS roster admitted DBApplicationInfo %s in memory (%lu -> %lu)",
                      identifier.UTF8String, (unsigned long)[result count],
                      (unsigned long)[expanded count]);
                continue;
            }
                CSLog("CarPlay roster rejected DBApplicationInfo for %s",
                      identifier.UTF8String);
            }
            if (expanded.count != [result count]) {
                CSTimingLog("FBS roster query end expanded=%lu", (unsigned long)expanded.count);
                return expanded;
            }
        }
    }
    CSTimingLog("FBS roster query end unchanged");
    return result;
}

static void CSInstallApplicationLibraryTrace(void) {
    CSTimingLog("application-library hook installation begin");
    Class library = CSLookupClass("FBSApplicationLibrary");
    if (!library) {
        CSTimingLog("application-library hook installation end class-absent");
        return;
    }
    CSSwizzleInstanceMethod(library, @selector(allInstalledApplications),
                             (IMP)cs_allInstalledApplications,
                             (IMP *)&orig_allInstalledApplications);
    CSSwizzleInstanceMethod(library, @selector(applicationsDidUninstall:),
                             (IMP)cs_applicationsDidUninstall,
                             (IMP *)&orig_applicationsDidUninstall);
    // Capture the process-local baseline before either CarPlay UI process
    // receives a preference notification. TemplateUIHost may not query
    // allInstalledApplications, but it still needs the enable/disable diff to
    // filter its icon-layout state.
    CSRestorePersistedDashboardDisabledIdentifiers();
    CSRememberInitialRuntimeEnabledIdentifiers();
    CSInstallCarPlayApplicationLibraryRefresh();
    CSInstallMissingApplicationMonitor();
    CSTimingLog("application-library hook installation end");
}

// Read-only roster diagnostics.  These methods are called by SpringBoard's
// CarPlay icon service while it builds the head-unit app library; logging the
// exact bundle IDs lets us distinguish a missing declaration from a denylist or
// icon-state filter without changing any system return value.
static void (*orig_sbsFetchIconState)(id, SEL, id, id);
static void cs_sbsFetchIconState(id self, SEL _cmd, id vehicleID, id completion) {
    gLastSBSIconService = self;
    if (vehicleID && vehicleID != [NSNull null]) gLastSBSIconVehicleIdentifier = vehicleID;
    CSLog("SBS icon-state fetch process=%s vehicle=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)");
    if (!completion) {
        orig_sbsFetchIconState(self, _cmd, vehicleID, completion);
        return;
    }
    void (^wrapped)(id, id) = ^(id state, id error) {
        id filtered = CSFilterIconLayoutState(state);
        CSLog("SBS icon-state fetch result vehicle=%s state=%s filtered=%d error=%s",
              [vehicleID description].UTF8String ?: "(nil)",
              state ? object_getClassName(state) : "(nil)",
              filtered != state,
              error ? object_getClassName(error) : "none");
        ((void (^)(id, id))completion)(filtered, error);
    };
    orig_sbsFetchIconState(self, _cmd, vehicleID, wrapped);
}

static void (*orig_sbsResetIconState)(id, SEL, id);
static void cs_sbsResetIconState(id self, SEL _cmd, id vehicleID) {
    gLastSBSIconService = self;
    if (vehicleID && vehicleID != [NSNull null]) gLastSBSIconVehicleIdentifier = vehicleID;
    CSLog("SBS icon-state reset process=%s vehicle=%s",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)");
    orig_sbsResetIconState(self, _cmd, vehicleID);
}

static void (*orig_sbsSetIconState)(id, SEL, id, id, id);
static void cs_sbsSetIconState(id self, SEL _cmd, id state, id hiddenIcons, id vehicleID) {
    gLastSBSIconService = self;
    if (vehicleID && vehicleID != [NSNull null]) gLastSBSIconVehicleIdentifier = vehicleID;
    id filtered = CSFilterIconLayoutState(state);
    CSLog("SBS icon-state set process=%s vehicle=%s state=%s filtered=%d hidden=%lu",
          NSProcessInfo.processInfo.processName.UTF8String,
          [vehicleID description].UTF8String ?: "(nil)",
          state ? object_getClassName(state) : "(nil)",
          filtered != state,
          [hiddenIcons respondsToSelector:@selector(count)] ? (unsigned long)[hiddenIcons count] : 0UL);
    orig_sbsSetIconState(self, _cmd, filtered, hiddenIcons, vehicleID);
}

static void CSSBSRefreshIconState(void) {
    id service = gLastSBSIconService;
    id vehicleID = gLastSBSIconVehicleIdentifier;
    if (!service || !vehicleID) {
        CSLog("SBS icon-state refresh unavailable service=%d vehicle=%d",
              service != nil, vehicleID != nil);
        return;
    }
    SEL resetSelector = @selector(resetIconStateForVehicleId:);
    SEL fetchSelector = @selector(fetchIconStateForVehicleId:withCompletion:);
    SEL setSelector = @selector(setIconState:hiddenIcons:forVehicleId:);
    CSLog("SBS icon-state refresh begin vehicle=%s",
          [vehicleID description].UTF8String);
    if ([service respondsToSelector:resetSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(service, resetSelector, vehicleID);
    }
    if (![service respondsToSelector:fetchSelector] ||
        ![service respondsToSelector:setSelector]) return;
    void (^completion)(id, id) = ^(id state, id error) {
        if (!state || error) {
            CSLog("SBS icon-state refresh fetch failed error=%s",
                  error ? object_getClassName(error) : "none");
            return;
        }
        id filtered = CSFilterIconLayoutState(state);
        if (filtered == state) {
            CSLog("SBS icon-state refresh no stale entries");
            return;
        }
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(service, setSelector,
                                                       filtered, @[], vehicleID);
        CSLog("SBS icon-state refresh wrote filtered state vehicle=%s",
              [vehicleID description].UTF8String);
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, fetchSelector,
                                               vehicleID, completion);
}

static void CSInstallRosterTrace(void) {
    static BOOL iconFetchHookInstalled;
    static BOOL iconResetHookInstalled;
    static BOOL iconSetHookInstalled;
    static BOOL retryScheduled;
    static NSUInteger retryCount;
    Class service = CSLookupClass("SBSApplicationCarPlayService");
    if (service) {
        if (!iconFetchHookInstalled) {
            iconFetchHookInstalled = CSSwizzleInstanceMethod(
                service, @selector(fetchIconStateForVehicleId:withCompletion:),
                (IMP)cs_sbsFetchIconState, (IMP *)&orig_sbsFetchIconState);
        }
        if (!iconResetHookInstalled) {
            iconResetHookInstalled = CSSwizzleInstanceMethod(
                service, @selector(resetIconStateForVehicleId:),
                (IMP)cs_sbsResetIconState, (IMP *)&orig_sbsResetIconState);
        }
        if (!iconSetHookInstalled) {
            iconSetHookInstalled = CSSwizzleInstanceMethod(
                service, @selector(setIconState:hiddenIcons:forVehicleId:),
                (IMP)cs_sbsSetIconState, (IMP *)&orig_sbsSetIconState);
        }
        if (iconFetchHookInstalled || iconResetHookInstalled || iconSetHookInstalled) {
            CSLog("SBS icon-state hooks installed process=%s fetch=%d reset=%d set=%d",
                  NSProcessInfo.processInfo.processName.UTF8String,
                  iconFetchHookInstalled, iconResetHookInstalled, iconSetHookInstalled);
        }
    }
    // CarPlayServices loads lazily after the policy evaluator. Retry once on
    // the main queue so the SBS icon-state methods are not missed at startup.
    if ((!iconFetchHookInstalled || !iconResetHookInstalled || !iconSetHookInstalled) &&
        !retryScheduled && retryCount < 5) {
        retryScheduled = YES;
        retryCount++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            retryScheduled = NO;
            CSInstallRosterTrace();
        });
    }
}

static void CSInstallRuntimeAdmission(Class declaration) {
    if (!CSMayInstallRuntimeAdmission()) {
        CSVLog("runtime admission not installed in this process");
        return;
    }

    BOOL factory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:info:entitlements:),
        (IMP)cs_declarationForBundleInfoEnts, (IMP *)&orig_declarationForBundleInfoEnts);

    BOOL propertyFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:entitlements:infoPlist:),
        (IMP)cs_declarationForBundleEntInfoPlist,
        (IMP *)&orig_declarationForBundleEntInfoPlist);
    BOOL pathFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:info:entitlements:bundlePath:),
        (IMP)cs_declarationForBundleInfoEntsPath,
        (IMP *)&orig_declarationForBundleInfoEntsPath);
    BOOL plistFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:infoPropertyList:entitlementsPropertyList:),
        (IMP)cs_declarationForBundlePropertyLists,
        (IMP *)&orig_declarationForBundlePropertyLists);
    BOOL plistPathFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForBundleIdentifier:infoPropertyList:entitlementsPropertyList:bundlePath:),
        (IMP)cs_declarationForBundlePropertyListsPath,
        (IMP *)&orig_declarationForBundlePropertyListsPath);
    BOOL appProxyFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForAppProxy:),
        (IMP)cs_declarationForAppProxy, (IMP *)&orig_declarationForAppProxy);
    BOOL appRecordFactory = CSSwizzleClassMethod(
        declaration, @selector(declarationForAppRecord:),
        (IMP)cs_declarationForAppRecord, (IMP *)&orig_declarationForAppRecord);

    if (!factory) {
        CSLog("WARNING: declarationForBundleIdentifier:info:entitlements: is absent; "
              "runtime admission unavailable, falling back to the on-disk patch");
        return;
    }

    CSLog("runtime admission installed in %s (%s, factories info=%d entInfoPlist=%d "
          "infoEntPath=%d plist=%d plistPath=%d appProxy=%d appRecord=%d, no system class patched)",
          NSProcessInfo.processInfo.processName.UTF8String,
          CSRuntimeAdmissionIsObserveOnly() ? "observe-only" : "admitting",
          factory, propertyFactory, pathFactory, plistFactory, plistPathFactory,
          appProxyFactory, appRecordFactory);
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
    CSTimingLog("CarKit policy hook installation begin");
    // The icon-layout classes live in a separate CarPlay UI image and may be
    // present in CarPlayTemplateUIHost without the policy evaluator. Install
    // these hooks before the evaluator gate so dashboard roster changes can be
    // reconciled in that host process too.
    CSInstallIconLayoutStateHooks();

    // CarPlayTemplateUIHost owns the icon-layout service but does not carry the
    // policy evaluator, so it used to fall out at the gate below before ever
    // registering the preference-reload handler. That left the one process that
    // owns the visible icon grid unable to react to an enable/disable toggle:
    // the app was added to / removed from DBApplicationController in CarPlay,
    // but the icon never appeared or disappeared live in the host. Register the
    // reactive refresh (and capture the enable/disable baseline it diffs
    // against) before the gate so every injected CarPlay UI process live-syncs
    // the dashboard when the CarSurf switch changes. All three are idempotent,
    // so the CSInstallApplicationLibraryTrace call past the gate stays a no-op.
    CSRestorePersistedDashboardDisabledIdentifiers();
    CSRememberInitialRuntimeEnabledIdentifiers();
    CSInstallCarPlayApplicationLibraryRefresh();

    Class evaluator = CSLookupClass("CRCarPlayAppPolicyEvaluator");
    if (!evaluator) {
        CSVLog("CRCarPlayAppPolicyEvaluator absent — not an iOS 18-era CarKit");
        CSTimingLog("CarKit policy hook installation end evaluator-absent");
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
    CSInstallRosterTrace();
    CSInstallApplicationLibraryTrace();
    CSInstallIconLayoutStateHooks();

    CSLog("CarKit policy hook installed (plain=%d, inVehicle=%d)", plain, inVehicle);

    if (!plain && !inVehicle) {
        CSLog("WARNING: neither policy selector exists; apps will not reach the "
                "dashboard. Run carsurf-classes --methods CRCarPlayAppPolicyEvaluator.");
    }
    CSTimingLog("CarKit policy hook installation end plain=%d inVehicle=%d", plain, inVehicle);
}
