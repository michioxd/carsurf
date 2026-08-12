#import "CSAppFilter.h"
#import <objc/message.h>
#import <objc/runtime.h>

static id CSSend(id target, const char *selectorName) {
    SEL sel = sel_getUid(selectorName);
    if (![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static BOOL CSSendBool(id target, const char *selectorName) {
    SEL sel = sel_getUid(selectorName);
    if (![target respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(target, sel);
}

/// SBAppTags for an app. LaunchServices caches only a subset of Info.plist keys,
/// so fall back to reading the bundle when the proxy does not carry it.
static NSArray *CSAppTags(id applicationProxy) {
    SEL sel = sel_getUid("objectForInfoDictionaryKey:ofClass:");
    if ([applicationProxy respondsToSelector:sel]) {
        id tags = ((id (*)(id, SEL, NSString *, Class))objc_msgSend)(
            applicationProxy, sel, @"SBAppTags", NSArray.class);
        if ([tags isKindOfClass:NSArray.class]) return tags;
    }

    id bundleURL = CSSend(applicationProxy, "bundleURL");
    if ([bundleURL isKindOfClass:NSURL.class]) {
        NSBundle *bundle = [NSBundle bundleWithURL:bundleURL];
        id tags = [bundle objectForInfoDictionaryKey:@"SBAppTags"];
        if ([tags isKindOfClass:NSArray.class]) return tags;
    }
    return nil;
}

BOOL CSAppIsUserVisible(id applicationProxy, NSString **outReason) {
    NSString *reason = nil;
    BOOL visible = NO;

    do {
        id identifier = CSSend(applicationProxy, "applicationIdentifier");
        if (![identifier isKindOfClass:NSString.class] || [identifier length] == 0) {
            reason = @"no identifier";
            break;
        }

        id name = CSSend(applicationProxy, "localizedName");
        if (![name isKindOfClass:NSString.class] || [name length] == 0) {
            reason = @"no display name";
            break;
        }

        if (CSSendBool(applicationProxy, "isPlaceholder")) {
            reason = @"placeholder";
            break;
        }

        if (CSSendBool(applicationProxy, "fbs_isLaunchProhibited")) {
            reason = @"launch prohibited";
            break;
        }

        id type = CSSend(applicationProxy, "applicationType");
        if (![type isEqualToString:@"User"] && ![type isEqualToString:@"System"]) {
            reason = [NSString stringWithFormat:@"type %@", type];
            break;
        }

        // The one that actually matters: this is how SpringBoard decides an app
        // has no home-screen presence.
        NSArray *tags = CSAppTags(applicationProxy);
        if ([tags containsObject:@"hidden"]) {
            reason = @"SBAppTags hidden";
            break;
        }

        visible = YES;
    } while (0);

    if (outReason) *outReason = reason;
    return visible;
}
