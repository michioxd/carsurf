#define CS_TAG "keyboard"

#import "CSAppInternal.h"
#import "CSLog.h"
#import "CSRuntime.h"
#import <objc/message.h>

static BOOL (*orig_sceneSuppressesKeyboardFocus)(id, SEL);
static BOOL (*orig_shouldSuppressSoftwareKeyboard)(id, SEL);
static BOOL (*orig_shouldSuppressSoftwareKeyboardAndAssistant)(id, SEL);
static BOOL (*orig_shouldSuppressIgnoringPolicy)(id, SEL, BOOL);
static BOOL (*orig_shouldSuppressForResponder)(id, SEL, id, BOOL);
static BOOL (*orig_automaticAppearanceEnabled)(id, SEL);
static BOOL (*orig_becomeFirstResponder)(UIResponder *, SEL);
static BOOL (*orig_resignFirstResponder)(UIResponder *, SEL);

@interface CSCarKeyboardView : UIView
- (instancetype)initWithResponder:(UIResponder<UIKeyInput> *)responder;
@property (nonatomic, weak, readonly) UIResponder<UIKeyInput> *responder;
@end

static __weak CSCarKeyboardView *gFallbackKeyboard;

static void CSPerformNativeReturn(UIResponder<UIKeyInput> *responder) {
    // The system keyboard belongs to a disconnected placeholder scene when an
    // app is bridged to CarPlay, so UIKeyboardImpl's performReturn never
    // reaches the field. Deliver the same UITextFieldDelegate callback UIKit
    // normally sends for the Return key instead.
    if ([responder isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)responder;
        id delegate = field.delegate;
        SEL selector = @selector(textFieldShouldReturn:);
        if ([delegate respondsToSelector:selector]) {
            CSLog("sending textFieldShouldReturn: to %s",
                    object_getClassName(delegate));
            BOOL handled = ((BOOL (*)(id, SEL, UITextField *))objc_msgSend)(
                delegate, selector, field);
            CSLog("textFieldShouldReturn: handled=%d firstResponder=%d",
                    handled, field.isFirstResponder);
            return;
        }
    }

    // Generic UIKeyInput fallback for bridged apps that do not use a
    // UITextField delegate for submission.
    CSLog("inserting return into %s", object_getClassName(responder));
    [responder insertText:@"\n"];
}

@implementation CSCarKeyboardView {
    __weak UIResponder<UIKeyInput> *_responder;
    NSMutableArray<NSArray<UIButton *> *> *_buttonRows;
    BOOL _uppercase;
    BOOL _numbers;
}

- (instancetype)initWithResponder:(UIResponder<UIKeyInput> *)responder {
    self = [super initWithFrame:CGRectZero];
    if (!self) return nil;
    _responder = responder;
    _buttonRows = [NSMutableArray new];
    _uppercase = NO;
    self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];
    self.layer.cornerRadius = 12.0;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    self.accessibilityViewIsModal = YES;
    [self carsurfRebuildKeys];
    return self;
}

- (UIResponder<UIKeyInput> *)responder { return _responder; }

- (UIButton *)carsurfButtonWithTitle:(NSString *)title value:(NSString *)value {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightMedium];
    button.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 6.0;
    button.accessibilityIdentifier = value;
    [button addTarget:self action:@selector(carsurfKeyPressed:)
       forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}

- (void)carsurfRebuildKeys {
    for (NSArray<UIButton *> *row in _buttonRows) {
        for (UIButton *button in row) [button removeFromSuperview];
    }
    [_buttonRows removeAllObjects];

    NSArray<NSArray<NSString *> *> *rows;
    if (_numbers) {
        rows = @[
            @[ @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"0" ],
            @[ @"-", @"/", @":", @";", @"(", @")", @"$", @"&", @"@", @"\"" ],
            @[ @".", @",", @"?", @"!", @"'", @"#", @"%", @"+", @"=", @"⌫" ],
            @[ @"ABC", @"space", @"Search", @"Done" ],
        ];
    } else {
        rows = @[
            @[ @"q", @"w", @"e", @"r", @"t", @"y", @"u", @"i", @"o", @"p" ],
            @[ @"a", @"s", @"d", @"f", @"g", @"h", @"j", @"k", @"l" ],
            @[ @"⇧", @"z", @"x", @"c", @"v", @"b", @"n", @"m", @"⌫" ],
            @[ @"123", @"space", @"Search", @"Done" ],
        ];
    }

    for (NSArray<NSString *> *titles in rows) {
        NSMutableArray<UIButton *> *buttons = [NSMutableArray new];
        for (NSString *raw in titles) {
            NSString *title = (!_numbers && _uppercase && raw.length == 1)
                                  ? raw.uppercaseString : raw;
            [buttons addObject:[self carsurfButtonWithTitle:title value:raw]];
        }
        [_buttonRows addObject:buttons];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat outer = 7.0;
    CGFloat gap = 5.0;
    CGFloat rowHeight = (self.bounds.size.height - outer * 2.0 - gap * 3.0) / 4.0;

    [_buttonRows enumerateObjectsUsingBlock:^(NSArray<UIButton *> *buttons,
                                               NSUInteger rowIndex,
                                               BOOL *stop) {
        CGFloat y = outer + rowIndex * (rowHeight + gap);
        CGFloat usableWidth = self.bounds.size.width - outer * 2.0;
        NSMutableArray<NSNumber *> *weights = [NSMutableArray new];
        CGFloat totalWeight = 0.0;
        for (UIButton *button in buttons) {
            NSString *value = button.accessibilityIdentifier;
            CGFloat weight = 1.0;
            if ([value isEqualToString:@"space"]) weight = 4.0;
            else if ([value isEqualToString:@"Search"] ||
                     [value isEqualToString:@"Done"]) weight = 1.7;
            else if ([value isEqualToString:@"123"] ||
                     [value isEqualToString:@"ABC"] ||
                     [value isEqualToString:@"⇧"] ||
                     [value isEqualToString:@"⌫"]) weight = 1.35;
            [weights addObject:@(weight)];
            totalWeight += weight;
        }

        usableWidth -= gap * MAX((NSInteger)buttons.count - 1, 0);
        CGFloat x = outer;
        for (NSUInteger index = 0; index < buttons.count; index++) {
            CGFloat width = usableWidth * weights[index].doubleValue / totalWeight;
            buttons[index].frame = CGRectMake(x, y, width, rowHeight);
            x += width + gap;
        }
    }];
}

- (void)carsurfKeyPressed:(UIButton *)button {
    UIResponder<UIKeyInput> *responder = _responder;
    if (!responder || !responder.isFirstResponder) {
        [self removeFromSuperview];
        return;
    }

    NSString *key = button.accessibilityIdentifier ?: @"";
    if ([key isEqualToString:@"⇧"]) {
        _uppercase = !_uppercase;
        [self carsurfRebuildKeys];
    } else if ([key isEqualToString:@"123"] || [key isEqualToString:@"ABC"]) {
        _numbers = !_numbers;
        _uppercase = NO;
        [self carsurfRebuildKeys];
    } else if ([key isEqualToString:@"⌫"]) {
        [responder deleteBackward];
    } else if ([key isEqualToString:@"space"]) {
        [responder insertText:@" "];
    } else if ([key isEqualToString:@"Search"] ||
               [key isEqualToString:@"Done"]) {
        CSPerformNativeReturn(responder);
    } else {
        NSString *text = (!_numbers && _uppercase) ? key.uppercaseString : key;
        [responder insertText:text];
    }
}

@end

static void CSDismissFallbackKeyboardForResponder(UIResponder *responder) {
    CSCarKeyboardView *keyboard = gFallbackKeyboard;
    if (!keyboard || (responder && keyboard.responder != responder)) return;
    [keyboard removeFromSuperview];
    gFallbackKeyboard = nil;
    CSLog("dismissed local CarPlay keyboard");
}

static void CSPresentFallbackKeyboard(UIResponder<UIKeyInput> *responder) {
    if (!responder.isFirstResponder) return;
    UIWindow *window = [responder isKindOfClass:UIView.class]
                           ? [(UIView *)responder window] : nil;
    if (!window || !CSIsBridgedCarScene(window.windowScene)) return;

    CSDismissFallbackKeyboardForResponder(nil);
    CGFloat height = MIN(320.0, MAX(230.0, window.bounds.size.height * 0.43));
    CSCarKeyboardView *keyboard =
        [[CSCarKeyboardView alloc] initWithResponder:responder];
    keyboard.frame = CGRectMake(0.0, window.bounds.size.height - height,
                                window.bounds.size.width, height);
    [window addSubview:keyboard];
    [window bringSubviewToFront:keyboard];
    gFallbackKeyboard = keyboard;
    CSLog("presented local CarPlay keyboard %.0fx%.0f in %s",
            keyboard.bounds.size.width, keyboard.bounds.size.height,
            object_getClassName(window));
}

static BOOL cs_sceneSuppressesKeyboardFocus(id self, SEL _cmd) {
    if (CSHasActiveCarScene()) return NO;
    return orig_sceneSuppressesKeyboardFocus(self, _cmd);
}

static BOOL cs_shouldSuppressSoftwareKeyboard(id self, SEL _cmd) {
    if (CSHasActiveCarScene()) return NO;
    return orig_shouldSuppressSoftwareKeyboard(self, _cmd);
}

static BOOL cs_shouldSuppressSoftwareKeyboardAndAssistant(id self, SEL _cmd) {
    if (CSHasActiveCarScene()) return NO;
    return orig_shouldSuppressSoftwareKeyboardAndAssistant(self, _cmd);
}

static BOOL cs_shouldSuppressIgnoringPolicy(id self, SEL _cmd,
                                               BOOL ignoringPolicyDelegate) {
    if (CSHasActiveCarScene()) return NO;
    return orig_shouldSuppressIgnoringPolicy(self, _cmd, ignoringPolicyDelegate);
}

static BOOL cs_shouldSuppressForResponder(id self, SEL _cmd, id responder,
                                             BOOL ignoringPolicyDelegate) {
    if (CSHasActiveCarScene() &&
        [responder conformsToProtocol:@protocol(UITextInput)]) {
        return NO;
    }
    return orig_shouldSuppressForResponder(self, _cmd, responder,
                                            ignoringPolicyDelegate);
}

static BOOL cs_automaticAppearanceEnabled(id self, SEL _cmd) {
    if (CSHasActiveCarScene()) return YES;
    return orig_automaticAppearanceEnabled(self, _cmd);
}

static void CSLogKeyboardPresentationState(id keyboard, UIResponder *responder) {
    UIWindow *keyboardWindow = [keyboard isKindOfClass:UIView.class]
                                   ? [(UIView *)keyboard window] : nil;
    id responderController = nil;
    Class responderClass = objc_getClass("UIInputResponderController");
    SEL activeResponder = sel_getUid("activeInputResponderController");
    if (responderClass && [(id)responderClass respondsToSelector:activeResponder]) {
        responderController =
            ((id (*)(id, SEL))objc_msgSend)(responderClass, activeResponder);
    }
    UIScene *inputScene = nil;
    if ([responderController respondsToSelector:@selector(scene)]) {
        inputScene = ((id (*)(id, SEL))objc_msgSend)(responderController,
                                                    @selector(scene));
    }
    CSLog("keyboard state view=%s window=%s hidden=%d scene=%s role=%s bridged=%d",
            keyboard ? object_getClassName(keyboard) : "nil",
            keyboardWindow ? object_getClassName(keyboardWindow) : "nil",
            keyboardWindow ? keyboardWindow.hidden : -1,
            inputScene ? object_getClassName(inputScene) : "nil",
            inputScene.session.role.UTF8String ?: "nil",
            CSIsBridgedCarScene(inputScene));
    if (!keyboardWindow && responder.isFirstResponder &&
        [responder conformsToProtocol:@protocol(UIKeyInput)]) {
        CSPresentFallbackKeyboard((UIResponder<UIKeyInput> *)responder);
    }
}

static void CSShowKeyboardWithoutExternalScenePolicy(UIResponder *responder) {
    if (!CSHasActiveCarScene() || !responder.isFirstResponder ||
        ![responder conformsToProtocol:@protocol(UITextInput)]) {
        return;
    }

    Class keyboardClass = objc_getClass("UIKeyboardImpl");
    SEL activeSelector = sel_getUid("activeInstance");
    SEL showSelector = sel_getUid("showKeyboardWithoutSuppressionPolicy");
    if (!keyboardClass || ![(id)keyboardClass respondsToSelector:activeSelector]) return;

    id keyboard = ((id (*)(id, SEL))objc_msgSend)(keyboardClass, activeSelector);
    if (!keyboard || ![keyboard respondsToSelector:showSelector]) return;

    Class responderClass = objc_getClass("UIInputResponderController");
    SEL activeResponder = sel_getUid("activeInputResponderController");
    SEL enableAppearance = sel_getUid("setAutomaticAppearanceEnabled:");
    if (responderClass && [(id)responderClass respondsToSelector:activeResponder]) {
        id controller =
            ((id (*)(id, SEL))objc_msgSend)(responderClass, activeResponder);
        if ([controller respondsToSelector:enableAppearance]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(controller,
                                                   enableAppearance, YES);
        }
    }

    CSLog("requesting software keyboard for %s on bridged scene",
            object_getClassName(responder));
    ((void (*)(id, SEL))objc_msgSend)(keyboard, showSelector);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CSLogKeyboardPresentationState(keyboard, responder);
    });
}

static BOOL cs_becomeFirstResponder(UIResponder *self, SEL _cmd) {
    BOOL became = orig_becomeFirstResponder(self, _cmd);
    if (became && CSHasActiveCarScene() &&
        [self conformsToProtocol:@protocol(UITextInput)]) {
        // Let UIKit finish installing the new input session before asking its
        // keyboard implementation to bypass the external-scene policy.
        dispatch_async(dispatch_get_main_queue(), ^{
            CSShowKeyboardWithoutExternalScenePolicy(self);
        });
    }
    return became;
}

static BOOL cs_resignFirstResponder(UIResponder *self, SEL _cmd) {
    BOOL resigned = orig_resignFirstResponder(self, _cmd);
    if (resigned) CSDismissFallbackKeyboardForResponder(self);
    return resigned;
}

void CSInstallKeyboardSupport(void) {
    Class client = objc_getClass("_UIApplicationSceneKeyboardClientComponent");
    BOOL focus = CSSwizzleInstanceMethod(
        client, sel_getUid("suppressKeyboardFocusRequests"),
        (IMP)cs_sceneSuppressesKeyboardFocus,
        (IMP *)&orig_sceneSuppressesKeyboardFocus);

    Class keyboard = objc_getClass("UIKeyboardImpl");
    BOOL suppress = CSSwizzleInstanceMethod(
        keyboard, sel_getUid("_shouldSuppressSoftwareKeyboard"),
        (IMP)cs_shouldSuppressSoftwareKeyboard,
        (IMP *)&orig_shouldSuppressSoftwareKeyboard);
    BOOL combined = CSSwizzleInstanceMethod(
        keyboard, sel_getUid("_shouldSuppressSoftwareKeyboardAndAssistantView"),
        (IMP)cs_shouldSuppressSoftwareKeyboardAndAssistant,
        (IMP *)&orig_shouldSuppressSoftwareKeyboardAndAssistant);
    BOOL policy = CSSwizzleInstanceMethod(
        keyboard, sel_getUid("_shouldSuppressSoftwareKeyboardIgnoringPolicyDelegate:"),
        (IMP)cs_shouldSuppressIgnoringPolicy,
        (IMP *)&orig_shouldSuppressIgnoringPolicy);
    BOOL responder = CSSwizzleInstanceMethod(
        keyboard,
        sel_getUid("_shouldSuppressSoftwareKeyboardForResponder:ignoringPolicyDelegate:"),
        (IMP)cs_shouldSuppressForResponder,
        (IMP *)&orig_shouldSuppressForResponder);

    Class responderController = objc_getClass("UIInputResponderController");
    BOOL appearance = CSSwizzleInstanceMethod(
        responderController, sel_getUid("automaticAppearanceEnabled"),
        (IMP)cs_automaticAppearanceEnabled,
        (IMP *)&orig_automaticAppearanceEnabled);

    BOOL firstResponder = CSSwizzleInstanceMethod(
        UIResponder.class, @selector(becomeFirstResponder),
        (IMP)cs_becomeFirstResponder,
        (IMP *)&orig_becomeFirstResponder);
    BOOL resign = CSSwizzleInstanceMethod(
        UIResponder.class, @selector(resignFirstResponder),
        (IMP)cs_resignFirstResponder,
        (IMP *)&orig_resignFirstResponder);

    CSLog("keyboard support installed (focus=%d, suppress=%d, combined=%d, "
            "policy=%d, responder=%d, appearance=%d, first=%d, resign=%d)",
            focus, suppress, combined, policy, responder, appearance,
            firstResponder, resign);
}
