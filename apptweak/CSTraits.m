#define CS_TAG "traits"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSPrivate.h"
#import "CSRuntime.h"

// Gate G3. Two independent problems:
//
//  1. Apps that switch on traitCollection.userInterfaceIdiom see
//     UIUserInterfaceIdiomCarPlay and either fall through to a default branch
//     with no layout or refuse to build a UI at all. Reporting Phone keeps them
//     on the code path they were written for.
//
//  2. Apps that lay out against +[UIScreen mainScreen].bounds instead of their
//     scene's coordinate space render at phone size on a much wider display.
//     Pointing mainScreen at the car screen fixes those — at the cost of the
//     phone-side UI laying out wrongly while bridged, which is why it is off by
//     default and opt-in per app.

static CSAppOptions *CSOptionsForThisApp(void) {
    static CSAppOptions *options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        options = [CSConfig.sharedConfig optionsForBundle:bundleID];
    });
    return options;
}

#pragma mark - Idiom

static UIUserInterfaceIdiom (*orig_userInterfaceIdiom)(id, SEL);
static UIUserInterfaceIdiom (*orig_deviceUserInterfaceIdiom)(id, SEL);

static UIUserInterfaceIdiom CSForcedIdiom(UIUserInterfaceIdiom original) {
    switch (CSOptionsForThisApp().idiomMode) {
        case CSIdiomModePhone: return UIUserInterfaceIdiomPhone;
        case CSIdiomModePad:   return UIUserInterfaceIdiomPad;
        case CSIdiomModeAuto:  return original;
    }
    return original;
}

static void CSLogIdiomOverrideOnce(const char *source,
                                     UIUserInterfaceIdiom original,
                                     UIUserInterfaceIdiom forced) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CSLog("idiom query via %s: original=%ld forced=%ld", source,
                (long)original, (long)forced);
    });
}

static UIUserInterfaceIdiom cs_userInterfaceIdiom(id self, SEL _cmd) {
    UIUserInterfaceIdiom idiom = orig_userInterfaceIdiom(self, _cmd);
    UIUserInterfaceIdiom forced = CSForcedIdiom(idiom);
    CSLogIdiomOverrideOnce("UITraitCollection", idiom, forced);
    return forced;
}

static UIUserInterfaceIdiom cs_deviceUserInterfaceIdiom(id self, SEL _cmd) {
    UIUserInterfaceIdiom idiom = orig_deviceUserInterfaceIdiom(self, _cmd);
    UIUserInterfaceIdiom forced = CSForcedIdiom(idiom);
    CSLogIdiomOverrideOnce("UIDevice", idiom, forced);
    return forced;
}

#pragma mark - Main screen

/// Supplied directly by the scene lifecycle callback. Looking it up by asking
/// UIApplication for connectedScenes from inside +[UIScreen mainScreen] can
/// re-enter UIKit while it holds its scene-activation lock, stalling launch until
/// the watchdog kills the app.
static __weak UIScreen *gActiveCarScreen;

void CSSetActiveCarScreen(UIScreen *screen) {
    gActiveCarScreen = screen;
    CSVLog("active car screen %s", screen ? "cached" : "cleared");
}

static UIScreen *CSCarScreen(void) {
    return gActiveCarScreen;
}

static UIScreen *(*orig_mainScreen)(Class, SEL);

static UIScreen *cs_mainScreen(Class self, SEL _cmd) {
    if (!CSOptionsForThisApp().spoofMainScreen) return orig_mainScreen(self, _cmd);

    UIScreen *car = CSCarScreen();
    return car ?: orig_mainScreen(self, _cmd);
}

#pragma mark - Install

void CSInstallTraitOverrides(void) {
    CSAppOptions *options = CSOptionsForThisApp();

    BOOL traitIdiom = NO;
    BOOL deviceIdiom = NO;
    if (options.idiomMode != CSIdiomModeAuto) {
        traitIdiom = CSSwizzleInstanceMethod(UITraitCollection.class,
                                              @selector(userInterfaceIdiom),
                                              (IMP)cs_userInterfaceIdiom,
                                              (IMP *)&orig_userInterfaceIdiom);
        deviceIdiom = CSSwizzleInstanceMethod(UIDevice.class,
                                               @selector(userInterfaceIdiom),
                                               (IMP)cs_deviceUserInterfaceIdiom,
                                               (IMP *)&orig_deviceUserInterfaceIdiom);
    }

    BOOL screen = NO;
    if (options.spoofMainScreen) {
        screen = CSSwizzleClassMethod(UIScreen.class, @selector(mainScreen),
                                        (IMP)cs_mainScreen, (IMP *)&orig_mainScreen);
    }

    CSLog("trait overrides installed (traitIdiom=%d deviceIdiom=%d mode=%ld, "
            "mainScreen=%d)", traitIdiom, deviceIdiom,
            (long)options.idiomMode, screen);
}
