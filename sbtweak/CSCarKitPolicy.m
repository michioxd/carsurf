#define CS_TAG "policy"

#import "CSSystemInternal.h"
#import "CSConfig.h"
#import "CSLog.h"
#import "CSPatchState.h"
#import "CSRuntime.h"
#import <objc/message.h>
#import <objc/runtime.h>

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
    id policy = orig_effectivePolicyInVehicle(self, _cmd, declaration, certificateSerial);

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

// DBApplicationInfo is private to DashBoard and is not present in the
// standalone diagnostic process.  Dump the contract from inside CarPlay,
// where the class and its real instances are already loaded.  This is
// deliberately read-only: the result is used only to identify the complete
// selector/initializer surface required by Dashboard before attempting any
// future roster construction.
static void CSDumpDashboardRosterContract(id roster) {
    static BOOL dumped = NO;
    if (dumped || ![NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) return;
    dumped = YES;

    id sample = [roster isKindOfClass:NSArray.class] ? [roster firstObject] : nil;
    Class cls = sample ? object_getClass(sample) : CSLookupClass("DBApplicationInfo");
    if (!cls) {
        CSLog("Dashboard roster contract unavailable (DBApplicationInfo not loaded)");
        return;
    }

    CSLog("Dashboard roster sample class=%s", class_getName(cls));
    for (Class current = cls; current; current = class_getSuperclass(current)) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(current, &methodCount);
        CSLog("Dashboard roster methods class=%s count=%u",
              class_getName(current), methodCount);
        for (unsigned int i = 0; i < methodCount; i++) {
            CSLog("  dashboard method -%s types=%s",
                  sel_getName(method_getName(methods[i])),
                  method_getTypeEncoding(methods[i]));
        }
        free(methods);

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(current, &ivarCount);
        for (unsigned int i = 0; i < ivarCount; i++) {
            CSLog("  dashboard ivar %s type=%s",
                  ivar_getName(ivars[i]), ivar_getTypeEncoding(ivars[i]));
        }
        free(ivars);
    }

    Class meta = object_getClass(cls);
    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(meta, &classMethodCount);
    CSLog("Dashboard roster class methods class=%s count=%u",
          class_getName(cls), classMethodCount);
    for (unsigned int i = 0; i < classMethodCount; i++) {
        CSLog("  dashboard method +%s types=%s",
              sel_getName(method_getName(classMethods[i])),
              method_getTypeEncoding(classMethods[i]));
    }
    free(classMethods);
}

static id CSCreateDBApplicationInfo(NSString *identifier) {
    Class dbClass = CSLookupClass("DBApplicationInfo");
    Class proxyClass = CSLookupClass("LSApplicationProxy");
    SEL proxySelector = @selector(applicationProxyForIdentifier:);
    SEL initSelector = @selector(initWithApplicationProxy:);
    if (!dbClass || !proxyClass || ![proxyClass respondsToSelector:proxySelector] ||
        ![dbClass instancesRespondToSelector:initSelector]) {
        return nil;
    }

    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
        proxyClass, proxySelector, identifier);
    id candidate = proxy
        ? ((id (*)(id, SEL, id))objc_msgSend)([dbClass alloc], initSelector, proxy)
        : nil;
    return candidate;
}

// Construction probe: Dashboard's concrete object inherits the normal
// FBSApplicationInfo initializer.  This also serves as the only roster
// construction path used below; no fabricated subclass is involved.
static void CSTestDBApplicationInfoConstruction(void) {
    static BOOL tested = NO;
    if (tested || ![NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) return;
    tested = YES;

    id candidate = CSCreateDBApplicationInfo(@"ftel.rad.fptplay");
    if (!candidate) {
        CSLog("DBApplicationInfo construction probe returned nil");
        return;
    }

    BOOL hidden = [candidate respondsToSelector:@selector(isHidden)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(candidate, @selector(isHidden)) : NO;
    BOOL valid = [candidate respondsToSelector:@selector(isValid)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(candidate, @selector(isValid)) : NO;
    BOOL installed = [candidate respondsToSelector:@selector(isInstalled)]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(candidate, @selector(isInstalled)) : NO;
    id declaration = [candidate respondsToSelector:@selector(carPlayDeclaration)]
        ? ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(carPlayDeclaration)) : nil;
    CSLog("DBApplicationInfo construction probe class=%s hidden=%d valid=%d installed=%d declaration=%s",
          object_getClassName(candidate), hidden, valid, installed,
          declaration ? "present" : "nil");
}

// The previous FBS subclass insertion is permanently disabled.  The tested
// DBApplicationInfo initializer is the only candidate allowed to reach the
// experimental roster path.
static BOOL CSAllowExperimentalRosterInsertion(void) {
    return YES;
}

static BOOL (*orig_supportsCarPlayDashboardScene)(id, SEL);
static BOOL cs_supportsCarPlayDashboardScene(id self, SEL _cmd) {
    BOOL result = orig_supportsCarPlayDashboardScene(self, _cmd);
    NSString *identifier = CSFactoryObjectBundleIdentifier(self);
    if (identifier && [CSConfig.sharedConfig isBundleEnabled:identifier]) {
        CSLog("record supportsCarPlayDashboardScene %s -> %d",
              identifier.UTF8String, result);
    }
    return result;
}

static void CSInstallRecordTrace(void) {
    Class record = CSLookupClass("LSApplicationRecord");
    if (!record) return;
    CSSwizzleInstanceMethod(record, @selector(supportsCarPlayDashboardScene),
                             (IMP)cs_supportsCarPlayDashboardScene,
                             (IMP *)&orig_supportsCarPlayDashboardScene);
}

static id (*orig_allInstalledApplications)(id, SEL);
static id cs_allInstalledApplications(id self, SEL _cmd) {
    id result = orig_allInstalledApplications(self, _cmd);
    CSDumpDashboardRosterContract(result);
    CSTestDBApplicationInfoConstruction();
    static BOOL loggedStack = NO;
    if (!loggedStack && [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        loggedStack = YES;
        CSLog("FBSApplicationLibrary allInstalledApplications CarPlay caller:");
        for (NSString *frame in NSThread.callStackSymbols) CSLog("    %s", frame.UTF8String);
    }
    if ([result isKindOfClass:NSArray.class]) {
        BOOL foundFPT = NO;
        for (id application in result) {
            NSString *identifier = CSFactoryObjectBundleIdentifier(application);
            if (identifier && ([CSConfig.sharedConfig isBundleEnabled:identifier] ||
                                [identifier isEqualToString:@"com.google.ios.youtube"])) {
                CSLog("FBS roster item %s class=%s carPlayDeclaration=%d",
                      identifier.UTF8String, object_getClassName(application),
                      [application respondsToSelector:@selector(carPlayDeclaration)]);
            }
            if ([identifier isEqualToString:@"ftel.rad.fptplay"]) {
                foundFPT = YES;
                break;
            }
        }
        CSLog("FBSApplicationLibrary allInstalledApplications count=%lu fpt=%d",
              (unsigned long)[result count], foundFPT);

        // CarPlay receives a filtered FBS library (34 entries on iOS 18.5),
        // while SpringBoard's library still contains FPT.  Construct the
        // concrete Dashboard object that CarPlay uses for every existing
        // entry.  It inherits FBSApplicationInfo's proxy initializer but adds
        // Dashboard's private state and selector contract.
        if (CSAllowExperimentalRosterInsertion() && !foundFPT &&
            [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"] &&
            [CSConfig.sharedConfig isBundleEnabled:@"ftel.rad.fptplay"]) {
            id info = CSCreateDBApplicationInfo(@"ftel.rad.fptplay");
            if (info && [info respondsToSelector:@selector(carPlayDeclaration)] &&
                [info respondsToSelector:@selector(isValid)] &&
                [info respondsToSelector:@selector(isInstalled)] &&
                !((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isHidden))) {
                BOOL valid = ((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isValid));
                BOOL installed = ((BOOL (*)(id, SEL))objc_msgSend)(info, @selector(isInstalled));
                id declaration = ((id (*)(id, SEL))objc_msgSend)(
                    info, @selector(carPlayDeclaration));
                CSLog("FPT DBApplicationInfo roster candidate valid=%d installed=%d declaration=%s class=%s",
                      valid, installed, declaration ? "present" : "nil",
                      object_getClassName(info));
                if (!valid || !installed || !declaration) return result;
                NSMutableArray *expanded = [result mutableCopy];
                [expanded addObject:info];
                CSLog("CarPlay FBS roster admitted DBApplicationInfo ftel.rad.fptplay in memory (%lu -> %lu)",
                      (unsigned long)[result count], (unsigned long)[expanded count]);
                return expanded;
            }
            CSLog("CarPlay FBS roster could not construct a valid DBApplicationInfo for FPT");
        }
    }
    return result;
}

static id (*orig_installedApplicationsForBundleIdentifier)(id, SEL, NSString *);
static id cs_installedApplicationsForBundleIdentifier(id self, SEL _cmd, NSString *bundleID) {
    id result = orig_installedApplicationsForBundleIdentifier(self, _cmd, bundleID);
    if ([bundleID isEqualToString:@"ftel.rad.fptplay"] &&
        [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        CSLog("FBS installedApplicationsForBundleIdentifier FPT -> %s (%s)",
              result ? "value" : "nil", object_getClassName(result));
    }
    return result;
}

static id (*orig_installedApplicationWithBundleIdentifier)(id, SEL, NSString *);
static id cs_installedApplicationWithBundleIdentifier(id self, SEL _cmd, NSString *bundleID) {
    id result = orig_installedApplicationWithBundleIdentifier(self, _cmd, bundleID);
    if ([bundleID isEqualToString:@"ftel.rad.fptplay"] &&
        [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        CSLog("FBS installedApplicationWithBundleIdentifier FPT -> %s (%s)",
              result ? "value" : "nil", object_getClassName(result));
    }
    return result;
}

static id (*orig_applicationInfoForBundleIdentifier)(id, SEL, NSString *);
static id cs_applicationInfoForBundleIdentifier(id self, SEL _cmd, NSString *bundleID) {
    id result = orig_applicationInfoForBundleIdentifier(self, _cmd, bundleID);
    if ([bundleID isEqualToString:@"ftel.rad.fptplay"] &&
        [NSProcessInfo.processInfo.processName isEqualToString:@"CarPlay"]) {
        CSLog("FBS applicationInfoForBundleIdentifier FPT -> %s (%s)",
              result ? "value" : "nil", object_getClassName(result));
    }
    return result;
}

static void CSInstallApplicationLibraryTrace(void) {
    Class library = CSLookupClass("FBSApplicationLibrary");
    if (!library) return;
    CSSwizzleInstanceMethod(library, @selector(allInstalledApplications),
                             (IMP)cs_allInstalledApplications,
                             (IMP *)&orig_allInstalledApplications);
    CSSwizzleInstanceMethod(library, @selector(installedApplicationsForBundleIdentifier:),
                             (IMP)cs_installedApplicationsForBundleIdentifier,
                             (IMP *)&orig_installedApplicationsForBundleIdentifier);
    CSSwizzleInstanceMethod(library, @selector(installedApplicationWithBundleIdentifier:),
                             (IMP)cs_installedApplicationWithBundleIdentifier,
                             (IMP *)&orig_installedApplicationWithBundleIdentifier);
    CSSwizzleInstanceMethod(library, @selector(applicationInfoForBundleIdentifier:),
                             (IMP)cs_applicationInfoForBundleIdentifier,
                             (IMP *)&orig_applicationInfoForBundleIdentifier);
}

// Read-only roster diagnostics.  These methods are called by SpringBoard's
// CarPlay icon service while it builds the head-unit app library; logging the
// exact bundle IDs lets us distinguish a missing declaration from a denylist or
// icon-state filter without changing any system return value.
static BOOL (*orig_denylistContains)(id, SEL, NSString *);
static BOOL cs_denylistContains(id self, SEL _cmd, NSString *bundleID) {
    BOOL result = orig_denylistContains(self, _cmd, bundleID);
    if (bundleID && ([CSConfig.sharedConfig isBundleEnabled:bundleID] ||
                     [bundleID isEqualToString:@"com.google.ios.youtube"])) {
        CSLog("denylist contains %s -> %d", bundleID.UTF8String, result);
    }
    return result;
}

static void (*orig_fetchIconInfo)(id, SEL, NSString *, BOOL, id);
static void cs_fetchIconInfo(id self, SEL _cmd, NSString *bundleID, BOOL inVehicle, id completion) {
    if (bundleID && ([CSConfig.sharedConfig isBundleEnabled:bundleID] ||
                     [bundleID isEqualToString:@"com.google.ios.youtube"])) {
        CSLog("icon info request %s (inVehicle=%d)", bundleID.UTF8String, inVehicle);
    }
    orig_fetchIconInfo(self, _cmd, bundleID, inVehicle, completion);
}

static void CSInstallRosterTrace(void) {
    Class denylist = CSLookupClass("CRCarPlayAppDenylist");
    if (denylist) CSSwizzleInstanceMethod(denylist, @selector(containsBundleIdentifier:),
                                           (IMP)cs_denylistContains,
                                           (IMP *)&orig_denylistContains);
    Class service = CSLookupClass("SBSApplicationCarPlayService");
    if (service) CSSwizzleInstanceMethod(service,
                                          @selector(fetchApplicationIconInformationForBundleIdentifier:inVehicle:withCompletion:),
                                          (IMP)cs_fetchIconInfo,
                                          (IMP *)&orig_fetchIconInfo);
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
    CSInstallRosterTrace();
    CSInstallRecordTrace();
    CSInstallApplicationLibraryTrace();

    CSLog("CarKit policy hook installed (plain=%d, inVehicle=%d)", plain, inVehicle);

    if (!plain && !inVehicle) {
        CSLog("WARNING: neither policy selector exists; apps will not reach the "
                "dashboard. Run carsurf-classes --methods CRCarPlayAppPolicyEvaluator.");
    }
}
