// carsurf-audit — verifies, on the device, that the private API CarSurf hooks
// actually exists on this iOS build. Run it over SSH before filing a bug:
//
//     carsurf-audit
//
// Every line is either OK or MISSING. A MISSING line names a hook that will not
// install; the tweak skips those rather than crashing, but the ones marked
// [required] have to be present for bridging to work at all.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static int gFailures = 0;
static int gRequiredFailures = 0;

static void Header(NSString *title) {
    printf("\n== %s ==\n", title.UTF8String);
}

static void Report(BOOL ok, BOOL required, NSString *what) {
    if (!ok) {
        gFailures++;
        if (required) gRequiredFailures++;
    }
    printf("  [%s]%s %s\n", ok ? "OK     " : "MISSING",
           required ? " [required]" : "           ", what.UTF8String);
}

static Class CheckClass(const char *name, BOOL required) {
    Class cls = objc_getClass(name);
    Report(cls != Nil, required, [NSString stringWithFormat:@"class %s", name]);
    return cls;
}

static void CheckInstanceMethod(Class cls, const char *selectorName, BOOL required) {
    SEL sel = sel_getUid(selectorName);
    BOOL present = cls && class_getInstanceMethod(cls, sel);
    Report(present, required,
           [NSString stringWithFormat:@"-[%s %s]",
                                      cls ? class_getName(cls) : "?", selectorName]);
}

static void CheckClassMethod(Class cls, const char *selectorName, BOOL required) {
    SEL sel = sel_getUid(selectorName);
    BOOL present = cls && class_getClassMethod(cls, sel);
    Report(present, required,
           [NSString stringWithFormat:@"+[%s %s]",
                                      cls ? class_getName(cls) : "?", selectorName]);
}

/// Prints every zero-argument BOOL getter on a class — the exact set the
/// entitlement spoof enumerates at runtime. If this list is empty, gate G1 cannot
/// be patched and the selector names have moved.
static void DumpBoolGetters(Class cls) {
    if (!cls) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    printf("  zero-argument BOOL getters on %s:\n", class_getName(cls));
    int found = 0;
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (strchr(name, ':')) continue;

        char *returnType = method_copyReturnType(methods[i]);
        if (!returnType) continue;
        BOOL isBool = (strcmp(returnType, "B") == 0 || strcmp(returnType, "c") == 0);
        free(returnType);
        if (!isBool) continue;

        printf("    - %s\n", name);
        found++;
    }
    free(methods);

    if (found == 0) printf("    (none — gate G1 cannot be patched)\n");
}

static void LoadFrameworks(void) {
    // Try both the rootless and legacy paths; the shared cache serves whichever
    // resolves. CarPlay.app loads these lazily, so a bare CLI has to ask.
    static const char *const paths[] = {
        "/System/Library/PrivateFrameworks/CarKit.framework/CarKit",
        "/System/Library/PrivateFrameworks/CarPlaySupport.framework/CarPlaySupport",
        "/System/Library/PrivateFrameworks/CarPlayUI.framework/CarPlayUI",
        "/System/Library/Frameworks/CarPlay.framework/CarPlay",
    };
    Header(@"Framework loading");
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths); i++) {
        void *handle = dlopen(paths[i], RTLD_LAZY);
        Report(handle != NULL, i == 0, [NSString stringWithUTF8String:paths[i]]);
        if (!handle) printf("           dlerror: %s\n", dlerror() ?: "(none)");
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        printf("carsurf-audit — CarSurf symbol audit\n");
        printf("iOS %s on %s\n", UIDevice.currentDevice.systemVersion.UTF8String,
               UIDevice.currentDevice.model.UTF8String);

        LoadFrameworks();

        // iOS 18.x: admission moved from CarPlaySupport's CARApplication /
        // CARAppEntitlements into CarKit's policy evaluator. Either generation
        // satisfies G1, so each is optional on its own and the summary below
        // reports failure only when both are absent.
        Header(@"Gate G1 (iOS 18.x) — CarKit app policy");
        Class evaluator = CheckClass("CRCarPlayAppPolicyEvaluator", NO);
        CheckInstanceMethod(evaluator, "effectivePolicyForAppDeclaration:", NO);
        CheckInstanceMethod(evaluator,
                            "effectivePolicyForAppDeclaration:inVehicleWithCertificateSerial:", NO);

        Class policy = CheckClass("CRCarPlayAppPolicy", NO);
        CheckInstanceMethod(policy, "setCanDisplayOnCarScreen:", NO);
        CheckInstanceMethod(policy, "setCarPlayCapable:", NO);
        CheckInstanceMethod(policy, "setCarPlaySupported:", NO);
        CheckInstanceMethod(policy, "setLaunchUsingTemplateUI:", NO);

        Class declaration = CheckClass("CRCarPlayAppDeclaration", NO);
        CheckInstanceMethod(declaration, "bundleIdentifier", NO);

        BOOL carKitPathUsable = evaluator && policy && declaration &&
            class_getInstanceMethod(evaluator, sel_getUid("effectivePolicyForAppDeclaration:")) &&
            class_getInstanceMethod(policy, sel_getUid("setCanDisplayOnCarScreen:"));

        Header(@"Gate G1 (iOS 13-17) — CarPlaySupport entitlements");
        Class entitlements = CheckClass("CARAppEntitlements", NO);
        DumpBoolGetters(entitlements);

        Class application = CheckClass("CARApplication", NO);
        CheckClassMethod(application, "_allInstalledApplications", NO);
        CheckClassMethod(application, "_allInstalledApplicationsByBundleIdentifier", NO);
        CheckInstanceMethod(application, "bundleIdentifier", NO);
        CheckInstanceMethod(application, "applicationProxy", NO);
        CheckInstanceMethod(application, "entitlements", NO);

        Header(@"Gate G2 — scene role rewriting");
        Class configuration = CheckClass("UISceneConfiguration", YES);
        CheckInstanceMethod(configuration, "initWithName:sessionRole:", YES);
        CheckInstanceMethod(configuration, "setSceneClass:", NO);

        Class session = CheckClass("UISceneSession", YES);
        CheckInstanceMethod(session, "role", YES);

        Class manifest = CheckClass("UIApplicationSceneManifest", NO);
        CheckInstanceMethod(manifest, "supportsMultipleScenes", NO);
        CheckInstanceMethod(manifest, "configurationForRole:", NO);
        CheckInstanceMethod(manifest, "sceneConfigurationForRole:", NO);
        CheckInstanceMethod(manifest, "_configurationForRole:", NO);

        Header(@"Gate G2 — the CarPlay role constant");
        // The tweak matches on the prefix rather than the exact symbol, so this is
        // informational: it confirms the prefix still matches reality.
        void *role = dlsym(RTLD_DEFAULT, "CPTemplateApplicationSceneSessionRoleApplication");
        if (role) {
            NSString *value = *(NSString *__strong *)role;
            Report(YES, NO, [NSString stringWithFormat:@"role constant = \"%@\"", value]);
            Report([value hasPrefix:@"CPTemplateApplicationSceneSessionRole"], YES,
                   @"role matches the prefix CarSurf looks for");
        } else {
            Report(NO, NO, @"CPTemplateApplicationSceneSessionRoleApplication symbol");
        }

        Header(@"Gate G3 — traits and screens");
        Class traits = CheckClass("UITraitCollection", YES);
        CheckInstanceMethod(traits, "userInterfaceIdiom", YES);
        CheckClassMethod(CheckClass("UIScreen", YES), "mainScreen", NO);
        printf("  UIUserInterfaceIdiomCarPlay = %d\n", (int)UIUserInterfaceIdiomCarPlay);

        Header(@"Result");
        if (!carKitPathUsable && !entitlements) {
            gRequiredFailures++;
            printf("  Neither the CarKit policy path nor the CarPlaySupport "
                   "entitlement path is available — gate G1 cannot be opened.\n");
        } else {
            printf("  Gate G1 path: %s\n",
                   carKitPathUsable ? "CarKit policy evaluator (iOS 18.x)"
                                    : "CarPlaySupport entitlements (iOS 13-17)");
        }

        if (gRequiredFailures > 0) {
            printf("  %d required symbol(s) missing — bridging will not work on this "
                   "build.\n", gRequiredFailures);
        } else if (gFailures > 0) {
            printf("  All required symbols present; %d optional symbol(s) missing "
                   "(reduced functionality).\n", gFailures);
        } else {
            printf("  Everything CarSurf needs is present.\n");
        }

        return gRequiredFailures > 0 ? 1 : 0;
    }
}
