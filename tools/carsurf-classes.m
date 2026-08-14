// carsurf-classes — Objective-C introspection for adapting CarSurf to a new iOS
// build. Answers "what is this class called now?" without a disassembler.
//
//   carsurf-classes --image CarPlaySupport     classes defined in a loaded image
//   carsurf-classes --grep SceneManifest       registered classes matching a name
//   carsurf-classes --methods CARApplication   methods of one class
//   carsurf-classes --bools CARAppEntitlements zero-argument BOOL getters only

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

static void LoadCarPlayFrameworks(void) {
    static const char *const paths[] = {
        "/System/Library/PrivateFrameworks/DashBoard.framework/DashBoard",
        "/System/Library/PrivateFrameworks/CarPlaySupport.framework/CarPlaySupport",
        "/System/Library/PrivateFrameworks/CarPlayUI.framework/CarPlayUI",
        "/System/Library/PrivateFrameworks/CarPlayUIServices.framework/CarPlayUIServices",
        "/System/Library/PrivateFrameworks/CarPlayServices.framework/CarPlayServices",
        "/System/Library/Frameworks/CarPlay.framework/CarPlay",
        "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore",
        "/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(*paths); i++) {
        dlopen(paths[i], RTLD_LAZY);
    }
}

static void DumpImage(const char *needle) {
    unsigned int imageCount = 0;
    const char **images = objc_copyImageNames(&imageCount);
    if (!images) return;

    for (unsigned int i = 0; i < imageCount; i++) {
        if (!strstr(images[i], needle)) continue;
        printf("\n== %s ==\n", images[i]);

        unsigned int classCount = 0;
        const char **names = objc_copyClassNamesForImage(images[i], &classCount);
        if (!names) continue;

        // Sorted output: diffing two iOS versions is the whole point.
        NSMutableArray *sorted = [NSMutableArray arrayWithCapacity:classCount];
        for (unsigned int j = 0; j < classCount; j++) {
            [sorted addObject:[NSString stringWithUTF8String:names[j]]];
        }
        [sorted sortUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *name in sorted) printf("  %s\n", name.UTF8String);
        printf("  (%u classes)\n", classCount);
        free((void *)names);
    }
    free((void *)images);
}

static void GrepClasses(const char *needle) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    if (!classes) return;

    NSMutableArray *matches = [NSMutableArray new];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name || !strcasestr(name, needle)) continue;

        const char *image = class_getImageName(classes[i]);
        const char *shortImage = image ? strrchr(image, '/') : NULL;
        [matches addObject:[NSString stringWithFormat:@"  %-52s %s", name,
                                                      shortImage ? shortImage + 1
                                                                 : (image ?: "?")]];
    }
    free(classes);

    [matches sortUsingSelector:@selector(caseInsensitiveCompare:)];
    printf("\n== classes matching \"%s\" ==\n", needle);
    for (NSString *line in matches) printf("%s\n", line.UTF8String);
    printf("  (%lu matches)\n", (unsigned long)matches.count);
}

static void DumpMethods(const char *className, BOOL boolGettersOnly) {
    Class cls = objc_getClass(className);
    if (!cls) {
        printf("\n== %s: NOT FOUND ==\n", className);
        return;
    }

    printf("\n== %s%s (superclass %s) ==\n", className,
           boolGettersOnly ? " — zero-argument BOOL getters" : "",
           class_getName(class_getSuperclass(cls)) ?: "?");

    for (int pass = 0; pass < 2; pass++) {
        Class target = (pass == 0) ? cls : object_getClass(cls);
        unsigned int count = 0;
        Method *methods = class_copyMethodList(target, &count);
        if (!methods) continue;

        NSMutableArray *lines = [NSMutableArray new];
        for (unsigned int i = 0; i < count; i++) {
            const char *name = sel_getName(method_getName(methods[i]));
            char *returnType = method_copyReturnType(methods[i]);

            if (boolGettersOnly) {
                BOOL zeroArg = (strchr(name, ':') == NULL);
                BOOL isBool = returnType && (strcmp(returnType, "B") == 0 ||
                                             strcmp(returnType, "c") == 0);
                if (!zeroArg || !isBool) { free(returnType); continue; }
            }

            [lines addObject:[NSString stringWithFormat:@"  %c%s  -> %s",
                                                        pass == 0 ? '-' : '+', name,
                                                        returnType ?: "?"]];
            free(returnType);
        }
        free(methods);

        [lines sortUsingSelector:@selector(caseInsensitiveCompare:)];
        for (NSString *line in lines) printf("%s\n", line.UTF8String);
    }
}

/// Invokes a zero-argument class method that returns an object, and prints its
/// -description. Read-only introspection helper — never used on instance state.
static void CallClassMethod(const char *className, const char *selectorName) {
    Class cls = objc_getClass(className);
    if (!cls) {
        printf("\n== %s: NOT FOUND ==\n", className);
        return;
    }
    SEL sel = sel_getUid(selectorName);
    if (![(id)cls respondsToSelector:sel]) {
        printf("\n== %s does not respond to +%s ==\n", className, selectorName);
        return;
    }
    id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id result = fn(cls, sel);
    printf("\n== +[%s %s] ==\n%s\n", className, selectorName,
           [[result description] UTF8String] ?: "(nil)");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        LoadCarPlayFrameworks();

        if (argc < 3) {
            printf("usage: carsurf-classes --image|--grep|--methods|--bools <argument>\n");
            printf("       carsurf-classes --call <Class> <selector>\n");
            return 2;
        }

        const char *mode = argv[1];
        if (strcmp(mode, "--call") == 0) {
            if (argc < 4) { printf("usage: carsurf-classes --call <Class> <selector>\n"); return 2; }
            CallClassMethod(argv[2], argv[3]);
            return 0;
        }
        for (int i = 2; i < argc; i++) {
            if (strcmp(mode, "--image") == 0) DumpImage(argv[i]);
            else if (strcmp(mode, "--grep") == 0) GrepClasses(argv[i]);
            else if (strcmp(mode, "--methods") == 0) DumpMethods(argv[i], NO);
            else if (strcmp(mode, "--bools") == 0) DumpMethods(argv[i], YES);
            else { printf("unknown mode %s\n", mode); return 2; }
        }
        return 0;
    }
}
