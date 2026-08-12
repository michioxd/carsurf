#import "CSPatchLogController.h"
#import "CSPatchLog.h"
#import "CSPatchState.h"

@interface CSPatchLogController ()
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UILabel *liveLabel;
@property (nonatomic, strong) UIButton *patchButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, copy) NSString *lastText;
@end

@implementation CSPatchLogController

- (NSString *)bundleIdentifier {
    id value = [self.specifier propertyForKey:@"carsurfBundle"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Patch Log";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *live = [UILabel new];
    live.translatesAutoresizingMaskIntoConstraints = NO;
    live.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    live.textColor = UIColor.secondaryLabelColor;
    live.text = @"● LIVE · updates while carsurf-helperd patches";
    [self.view addSubview:live];
    self.liveLabel = live;

    UITextView *textView = [UITextView new];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.selectable = YES;
    textView.alwaysBounceVertical = YES;
    textView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    textView.textColor = UIColor.labelColor;
    textView.font = [UIFont monospacedSystemFontOfSize:11.5
                                               weight:UIFontWeightRegular];
    textView.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    textView.layer.cornerRadius = 10;
    [self.view addSubview:textView];
    self.logView = textView;

    UIButton *clear = [self buttonWithTitle:@"Clear Log"
                                      color:UIColor.systemRedColor
                                     action:@selector(clearLog)];
    UIButton *patch = [self buttonWithTitle:@"Patch Again"
                                      color:UIColor.systemBlueColor
                                     action:@selector(patchAgain)];
    patch.hidden = self.bundleIdentifier.length == 0;
    self.patchButton = patch;
    UIButton *share = [self buttonWithTitle:@"Share Log"
                                      color:UIColor.systemBlueColor
                                     action:@selector(shareLog:)];
    self.shareButton = share;

    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:
                            self.bundleIdentifier.length ? @[ clear, patch, share ]
                                                         : @[ clear, share ]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 10;
    [self.view addSubview:buttons];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [live.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [live.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [live.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],

        [textView.topAnchor constraintEqualToAnchor:live.bottomAnchor constant:8],
        [textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],

        [buttons.topAnchor constraintEqualToAnchor:textView.bottomAnchor constant:10],
        [buttons.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [buttons.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [buttons.heightAnchor constraintEqualToConstant:44],
        [buttons.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
    ]];
}

- (UIButton *)buttonWithTitle:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:color forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.backgroundColor = UIColor.secondarySystemBackgroundColor;
    button.layer.cornerRadius = 10;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshLog];
    __weak __typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES
                                                         block:^(NSTimer *timer) {
        [weakSelf refreshLog];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshLog {
    NSString *text = CSPatchLogRead();
    if ([text isEqualToString:self.lastText]) return;

    BOOL nearBottom = self.logView.contentOffset.y + self.logView.bounds.size.height >=
        self.logView.contentSize.height - 60.0;
    self.lastText = text;
    self.logView.text = text.length ? text
        : @"No patch log yet.\n\nTap Clear Log, then Patch Again to capture a clean reproduction.";
    if (nearBottom || self.logView.contentSize.height <= self.logView.bounds.size.height) {
        NSRange end = NSMakeRange(self.logView.text.length, 0);
        [self.logView scrollRangeToVisible:end];
    }
}

- (void)clearLog {
    self.liveLabel.text = @"● LIVE · clearing through carsurf-helperd…";
    self.patchButton.enabled = NO;
    CSPatchLogRequestClear();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.liveLabel.text = @"● LIVE · log cleared; reproduce the failure now";
        self.patchButton.enabled = YES;
        [self refreshLog];
    });
}

- (void)patchAgain {
    NSString *bundleID = self.bundleIdentifier;
    if (bundleID.length == 0) return;
    self.liveLabel.text = [NSString stringWithFormat:@"● LIVE · patching %@…", bundleID];
    CSPatchRequestSubmit(bundleID);
}

- (void)shareLog:(UIButton *)sender {
    if (!sender.enabled) return;
    sender.enabled = NO;
    self.liveLabel.text = @"● LIVE · preparing share sheet…";
    [CSPatchLogController presentShareSheetFromController:self
                                               sourceView:sender
                                         bundleIdentifier:self.bundleIdentifier];
}

static UIViewController *CSTopViewController(UIViewController *controller) {
    UIViewController *current = controller;
    while (current.presentedViewController &&
           !current.presentedViewController.isBeingDismissed) {
        current = current.presentedViewController;
    }
    if ([current isKindOfClass:UINavigationController.class]) {
        UIViewController *visible = [(UINavigationController *)current visibleViewController];
        if (visible) return CSTopViewController(visible);
    }
    if ([current isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = [(UITabBarController *)current selectedViewController];
        if (selected) return CSTopViewController(selected);
    }
    return current;
}

+ (void)presentShareSheetFromController:(UIViewController *)controller
                             sourceView:(UIView *)sourceView
                       bundleIdentifier:(NSString *)bundleIdentifier {
    NSString *bundleCopy = [bundleIdentifier copy] ?: @"";
    NSString *systemVersion = UIDevice.currentDevice.systemVersion ?: @"unknown";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *log = CSPatchLogRead();
        // Some share extensions become slow or fail on very large text items.
        // Preserve the most relevant tail while the on-screen viewer retains
        // the complete bounded transcript.
        static const NSUInteger kMaximumSharedCharacters = 200000;
        if (log.length > kMaximumSharedCharacters) {
            log = [@"[Older entries omitted from shared copy.]\n"
                stringByAppendingString:[log substringFromIndex:
                    log.length - kMaximumSharedCharacters]];
        }
        NSString *bundleLine = bundleCopy.length
            ? [NSString stringWithFormat:@"Requested app: %@\n", bundleCopy] : @"";
        CSPatchRecord *record = bundleCopy.length ? CSPatchStateRead(bundleCopy) : nil;
        NSString *failureLine = record.failureReason.length
            ? [NSString stringWithFormat:@"Reported failure: %@\n", record.failureReason]
            : @"";
        NSString *report = [NSString stringWithFormat:
            @"CarSurf Patch Log\nGenerated: %@\niOS: %@\n%@%@\n%@",
            NSDate.date, systemVersion, bundleLine, failureLine,
            log.length ? log : @"No patch output was recorded.\n"];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *presenter = CSTopViewController(controller);
            UIActivityViewController *activity = [[UIActivityViewController alloc]
                initWithActivityItems:@[ report ] applicationActivities:nil];
            activity.modalPresentationStyle = UIModalPresentationPageSheet;
            activity.completionWithItemsHandler =
                ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
                if ([controller isKindOfClass:CSPatchLogController.class]) {
                    CSPatchLogController *logController = (CSPatchLogController *)controller;
                    logController.shareButton.enabled = YES;
                    logController.liveLabel.text = @"● LIVE · updates while carsurf-helperd patches";
                }
            };
            UIPopoverPresentationController *popover = activity.popoverPresentationController;
            if (popover) {
                UIView *anchor = sourceView.window ? sourceView : presenter.view;
                popover.sourceView = anchor;
                popover.sourceRect = anchor == sourceView ? sourceView.bounds
                    : CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
            }
            [presenter presentViewController:activity animated:YES completion:^{
                if ([controller isKindOfClass:CSPatchLogController.class]) {
                    ((CSPatchLogController *)controller).shareButton.enabled = YES;
                }
            }];
        });
    });
}

@end
