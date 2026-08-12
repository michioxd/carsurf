#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Guarded lookup

/// objc_getClass, but logs once per missing name so an audit of the log tells you
/// exactly which private symbols moved in a new iOS build.
Class _Nullable CSLookupClass(const char *name);

/// First class whose name matches one of the candidates, or Nil. Lets a hook
/// tolerate a rename across iOS versions.
Class _Nullable CSLookupAnyClass(const char *const _Nonnull candidates[_Nonnull], size_t count);

BOOL CSHasInstanceMethod(Class _Nullable cls, SEL sel);
BOOL CSHasClassMethod(Class _Nullable cls, SEL sel);

#pragma mark - Guarded swizzling

/// Replaces an existing instance method. Returns NO (and installs nothing) if
/// the class or selector is absent — never creates a new method, because adding
/// a method the framework does not expect is how you get a boot loop.
///
/// On success `*outOriginal` receives the previous IMP; call it through a
/// correctly-typed function pointer.
BOOL CSSwizzleInstanceMethod(Class _Nullable cls, SEL sel, IMP replacement,
                               IMP _Nullable *_Nullable outOriginal);

BOOL CSSwizzleClassMethod(Class _Nullable cls, SEL sel, IMP replacement,
                            IMP _Nullable *_Nullable outOriginal);

/// Applies `apply` to every zero-argument, BOOL-returning instance method
/// declared directly on `cls` (not inherited). Used to blanket-patch
/// CARAppEntitlements, whose getter names change between iOS releases.
/// `apply` returns NO to skip a given selector.
void CSEnumerateBoolGetters(Class _Nullable cls,
                              BOOL (^apply)(SEL sel, IMP original,
                                            IMP _Nullable *_Nonnull outReplacement));

#pragma mark - Spoof suppression

/// While suppressed, the entitlement hooks defer to the original implementation.
/// This is how the system-side tweak obtains the *real* CarPlay app list to diff
/// against the spoofed one. Per-thread, and safe to nest.
BOOL CSSpoofSuppressed(void);
void CSRunWithSpoofSuppressed(dispatch_block_t block);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
