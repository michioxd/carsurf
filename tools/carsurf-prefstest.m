// carsurf-prefstest — works out why the Settings pane is empty.
//
// An empty PreferenceLoader pane has three possible causes, and this separates
// them instead of guessing:
//
//   1. the bundle's binary will not load at all (dlopen reports why)
//   2. it loads but the principal class is missing or misnamed
//   3. it loads and the class exists, but -specifiers returns nothing

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kBundlePath =
    @"/var/jb/Library/PreferenceBundles/CSPrefs.bundle";

static void Step(NSString *title) {
    printf("\n== %s ==\n", title.UTF8String);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        Step(@"Preferences.framework");
        // PS* classes must exist before our bundle can possibly work: if they
        // moved framework on iOS 18, that alone explains an empty pane.
        static const char *const frameworks[] = {
            "/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
            "/System/Library/PrivateFrameworks/PreferencesUI.framework/PreferencesUI",
        };
        for (size_t i = 0; i < sizeof(frameworks) / sizeof(*frameworks); i++) {
            void *handle = dlopen(frameworks[i], RTLD_LAZY);
            printf("  %-88s %s\n", frameworks[i], handle ? "loaded" : "FAILED");
            if (!handle) printf("      dlerror: %s\n", dlerror() ?: "(none)");
        }
        static const char *const psClasses[] = {
            "PSListController", "PSSpecifier", "PSViewController",
        };
        for (size_t i = 0; i < sizeof(psClasses) / sizeof(*psClasses); i++) {
            Class cls = objc_getClass(psClasses[i]);
            printf("  class %-20s %s\n", psClasses[i], cls ? "present" : "MISSING");
            if (!cls) continue;
            printf("      -specifiers      %s\n",
                   class_getInstanceMethod(cls, sel_getUid("specifiers")) ? "yes" : "no");
            printf("      -setSpecifiers:  %s\n",
                   class_getInstanceMethod(cls, sel_getUid("setSpecifiers:")) ? "yes" : "no");
        }

        Step(@"CSPrefs bundle on disk");
        NSBundle *bundle = [NSBundle bundleWithPath:kBundlePath];
        printf("  NSBundle              %s\n", bundle ? "found" : "MISSING");
        printf("  principal class name  %s\n",
               [[bundle objectForInfoDictionaryKey:@"NSPrincipalClass"] UTF8String] ?: "(none)");
        printf("  executable            %s\n",
               [[bundle objectForInfoDictionaryKey:@"CFBundleExecutable"] UTF8String] ?: "(none)");

        Step(@"Loading the binary");
        NSString *binary = [kBundlePath stringByAppendingPathComponent:@"CSPrefs"];
        void *handle = dlopen(binary.fileSystemRepresentation, RTLD_NOW);
        printf("  dlopen                %s\n", handle ? "OK" : "FAILED");
        if (!handle) {
            // This is the interesting case: a missing symbol or an invalid code
            // signature is named here verbatim.
            printf("  dlerror               %s\n", dlerror() ?: "(none)");
            return 1;
        }

        Step(@"Principal class");
        Class root = objc_getClass("CSRootListController");
        printf("  CSRootListController %s\n", root ? "present" : "MISSING");
        Class list = objc_getClass("CSAppListController");
        printf("  CSAppListController  %s\n", list ? "present" : "MISSING");
        if (!root) return 1;
        printf("  superclass             %s\n", class_getName(class_getSuperclass(root)));
        printf("  overrides -specifiers  %s\n",
               class_getInstanceMethod(root, sel_getUid("specifiers")) ? "yes" : "no");

        Step(@"Building specifiers");
        // Outside Settings this can legitimately fail; catching keeps the useful
        // output above from being lost to a crash.
        @try {
            id controller = [[root alloc] init];
            printf("  init                  %s\n", controller ? "OK" : "nil");
            id specifiers = ((id (*)(id, SEL))objc_msgSend)(controller, sel_getUid("specifiers"));
            printf("  -specifiers count     %lu\n",
                   (unsigned long)[specifiers count]);
            if ([specifiers count] == 0) {
                printf("  => the pane is empty because -specifiers returned nothing\n");
            } else {
                printf("  => specifiers build fine; the pane is empty for another reason\n");
            }
        } @catch (NSException *exception) {
            printf("  EXCEPTION             %s: %s\n", exception.name.UTF8String,
                   exception.reason.UTF8String);
            printf("  => -specifiers throws; that is why the pane is empty\n");
        }
        return 0;
    }
}
