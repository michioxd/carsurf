#define CS_TAG "fullscreen"

#import "CSAppInternal.h"
#import "CSLog.h"
#import <objc/runtime.h>

static void (*orig_watchWillAppear)(id, SEL, BOOL);
static void (*orig_watchDidDisappear)(id, SEL, BOOL);
static void (*orig_watchFullscreenWillAppear)(id, SEL, BOOL);
static void (*orig_watchFullscreenDidDisappear)(id, SEL, BOOL);
static BOOL gWatchVisible;
static BOOL gFullscreenVisible;

static void CSUpdateVideoLayout(void) {
    CSSetMirroringVideoActive(gWatchVisible || gFullscreenVisible);
}

/// Adds an override to `cls` without replacing the inherited implementation on
/// UIViewController. If YouTube implements the lifecycle method itself, replace
/// that class-local method instead.
static BOOL CSHookClassLifecycleMethod(Class cls, SEL selector, IMP replacement,
                                         IMP *outOriginal) {
    if (!cls || !selector || !replacement) return NO;

    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited) return NO;
    IMP original = method_getImplementation(inherited);
    const char *types = method_getTypeEncoding(inherited);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method local = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            local = methods[index];
            break;
        }
    }
    free(methods);

    if (local) {
        original = method_setImplementation(local, replacement);
    } else if (!class_addMethod(cls, selector, replacement, types)) {
        return NO;
    }

    if (outOriginal) *outOriginal = original;
    return YES;
}

static void cs_watchWillAppear(id self, SEL _cmd, BOOL animated) {
    // Resize before YouTube builds the watch page so the inline player and its
    // playlist measure the horizontal canvas on their first layout pass.
    gWatchVisible = YES;
    CSUpdateVideoLayout();
    CSVLog("watch page appearing (watch=1 fullscreen=%d)", gFullscreenVisible);
    orig_watchWillAppear(self, _cmd, animated);
}

static void cs_watchDidDisappear(id self, SEL _cmd, BOOL animated) {
    orig_watchDidDisappear(self, _cmd, animated);

    // UIKit also sends -viewDidDisappear: to the inline watch controller when
    // YouTube covers it with its fullscreen controller. Do not interpret that
    // as leaving the player: after fullscreen is dismissed the same watch page
    // is still underneath and must remain horizontal. Defer one run-loop turn
    // so the fullscreen controller's -viewWillAppear: has set its flag even if
    // YouTube happens to deliver the two callbacks in the opposite order.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFullscreenVisible) {
            CSVLog("watch page covered by fullscreen; keeping player active");
            return;
        }
        gWatchVisible = NO;
        CSVLog("watch page exited (watch=0 fullscreen=0)");
        CSUpdateVideoLayout();
    });
}

static void cs_watchFullscreenWillAppear(id self, SEL _cmd, BOOL animated) {
    gFullscreenVisible = YES;
    CSUpdateVideoLayout();
    CSVLog("fullscreen appearing (watch=%d fullscreen=1)", gWatchVisible);
    orig_watchFullscreenWillAppear(self, _cmd, animated);
}

static void cs_watchFullscreenDidDisappear(id self, SEL _cmd, BOOL animated) {
    orig_watchFullscreenDidDisappear(self, _cmd, animated);
    gFullscreenVisible = NO;
    CSVLog("fullscreen exited (watch=%d fullscreen=0)", gWatchVisible);
    CSUpdateVideoLayout();
}

void CSInstallFullscreenLayoutSupport(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    if (![bundleID isEqualToString:@"com.google.ios.youtube"]) return;

    Class watch = objc_getClass("YTWatchViewController");
    BOOL watchEnter = CSHookClassLifecycleMethod(
        watch, @selector(viewWillAppear:),
        (IMP)cs_watchWillAppear,
        (IMP *)&orig_watchWillAppear);
    BOOL watchExit = CSHookClassLifecycleMethod(
        watch, @selector(viewDidDisappear:),
        (IMP)cs_watchDidDisappear,
        (IMP *)&orig_watchDidDisappear);

    Class fullscreen = objc_getClass("YTWatchFullscreenViewController");
    BOOL fullscreenEnter = CSHookClassLifecycleMethod(
        fullscreen, @selector(viewWillAppear:),
        (IMP)cs_watchFullscreenWillAppear,
        (IMP *)&orig_watchFullscreenWillAppear);
    BOOL fullscreenExit = CSHookClassLifecycleMethod(
        fullscreen, @selector(viewDidDisappear:),
        (IMP)cs_watchFullscreenDidDisappear,
        (IMP *)&orig_watchFullscreenDidDisappear);
    CSLog("YouTube player auto-layout installed (watch=%d/%d, fullscreen=%d/%d)",
            watchEnter, watchExit, fullscreenEnter, fullscreenExit);
}
