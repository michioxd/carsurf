#define CS_TAG "runtime"

#import "CSRuntime.h"
#import "CSLog.h"

#pragma mark - Guarded lookup

Class CSLookupClass(const char *name) {
    if (!name) return Nil;
    Class cls = objc_getClass(name);
    if (!cls) CSLog("missing class %s", name);
    return cls;
}

Class CSLookupAnyClass(const char *const candidates[], size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (!candidates[i]) continue;
        Class cls = objc_getClass(candidates[i]);
        if (cls) return cls;
    }
    if (count > 0) CSLog("no class among %zu candidates (first: %s)", count,
                           candidates[0] ?: "?");
    return Nil;
}

BOOL CSHasInstanceMethod(Class cls, SEL sel) {
    return cls && sel && class_getInstanceMethod(cls, sel) != NULL;
}

BOOL CSHasClassMethod(Class cls, SEL sel) {
    return cls && sel && class_getClassMethod(cls, sel) != NULL;
}

#pragma mark - Guarded swizzling

static BOOL CSSwizzle(Method method, const char *what, IMP replacement, IMP *outOriginal) {
    if (!method) {
        CSLog("cannot hook %s — method absent", what);
        return NO;
    }
    IMP original = method_setImplementation(method, replacement);
    if (outOriginal) *outOriginal = original;
    CSVLog("hooked %s", what);
    return YES;
}

BOOL CSSwizzleInstanceMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    char what[256];
    snprintf(what, sizeof(what), "-[%s %s]", class_getName(cls), sel_getName(sel));
    // Deliberately not class_addMethod: we only ever replace what already exists.
    return CSSwizzle(class_getInstanceMethod(cls, sel), what, replacement, outOriginal);
}

BOOL CSSwizzleClassMethod(Class cls, SEL sel, IMP replacement, IMP *outOriginal) {
    if (!cls || !sel || !replacement) return NO;
    char what[256];
    snprintf(what, sizeof(what), "+[%s %s]", class_getName(cls), sel_getName(sel));
    return CSSwizzle(class_getClassMethod(cls, sel), what, replacement, outOriginal);
}

void CSEnumerateBoolGetters(Class cls,
                             BOOL (^apply)(SEL sel, IMP original, IMP *outReplacement)) {
    if (!cls || !apply) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    for (unsigned int i = 0; i < count; i++) {
        Method method = methods[i];
        SEL sel = method_getName(method);
        const char *name = sel_getName(sel);

        // Zero arguments: selector must contain no colon.
        if (strchr(name, ':')) continue;
        // Skip lifecycle selectors — replacing these is never what we want.
        if (strcmp(name, "dealloc") == 0 || strcmp(name, "init") == 0 ||
            strcmp(name, "copy") == 0 || strcmp(name, "description") == 0) continue;

        char *returnType = method_copyReturnType(method);
        if (!returnType) continue;
        // BOOL is 'B' (C99 _Bool) or 'c' (signed char) depending on the SDK the
        // framework was built with; accept both.
        BOOL isBool = (strcmp(returnType, "B") == 0 || strcmp(returnType, "c") == 0);
        free(returnType);
        if (!isBool) continue;

        IMP replacement = NULL;
        if (!apply(sel, method_getImplementation(method), &replacement)) continue;
        if (!replacement) continue;

        method_setImplementation(method, replacement);
        CSVLog("patched -[%s %s]", class_getName(cls), name);
    }
    free(methods);
}

#pragma mark - Spoof suppression

static _Thread_local NSUInteger gSuppressDepth = 0;

BOOL CSSpoofSuppressed(void) { return gSuppressDepth > 0; }

void CSRunWithSpoofSuppressed(dispatch_block_t block) {
    if (!block) return;
    gSuppressDepth++;
    @try {
        block();
    } @finally {
        if (gSuppressDepth > 0) gSuppressDepth--;
    }
}
