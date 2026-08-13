#import "CSAppOptionsController.h"
#import "CSPrefsStore.h"
#import "CSConfig.h"
#import "CSLayoutSegmentCell.h"
#import "CSPatchLogController.h"
#import "CSPatchState.h"
#import <notify.h>

@implementation CSAppOptionsController {
    NSArray<PSSpecifier *> *_carsurfSpecifiers;
    BOOL _carsurfReentering;
    PSSpecifier *_carsurfStatusGroup;

    // Patch Now progress. A tap used to just show "Requested" and leave the user
    // guessing; this polls CSPatchState for the record carsurf-helperd is about
    // to overwrite and keeps a spinner up until it actually changes (or a
    // timeout), so the button's outcome is always answered on-screen.
    BOOL _carsurfPatching;
    NSInteger _carsurfPatchGeneration;
    NSDate *_carsurfPatchBaselineDate;
    UIView *_carsurfProgressOverlay;
}

- (NSString *)bundleIdentifier {
    id value = [self.specifier propertyForKey:@"carsurfBundle"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.specifier.name ?: @"App Display";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The daemon patches asynchronously (a "Patch Now" tap just wakes it), so the
    // status line can only be trustworthy as of "last time this screen loaded" —
    // refresh it every time the user comes back to it rather than once at push.
    [self carsurfRefreshPatchStatus];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Leaving mid-patch: the daemon keeps working regardless, but this screen
    // stops watching it. Drop the overlay and bump the generation so the
    // in-flight poll chain's next wake-up sees a mismatch and quietly stops
    // instead of trying to present an alert on a controller that's off-screen.
    [_carsurfProgressOverlay removeFromSuperview];
    _carsurfProgressOverlay = nil;
    _carsurfPatching = NO;
    _carsurfPatchGeneration++;
}

- (BOOL)carsurfIsEnabled {
    return [CSPrefsStore.sharedStore isAppEnabled:self.bundleIdentifier];
}

- (id)readEnabled:(PSSpecifier *)specifier {
    return @(self.carsurfIsEnabled);
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    [CSPrefsStore.sharedStore setApp:self.bundleIdentifier enabled:[value boolValue]];
    // Enabling wakes carsurf-helperd immediately (CSPrefsStore posts the reload
    // notification), so the status line is worth a refresh a beat later —
    // sooner than the user could plausibly back out and back in again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
        [self carsurfRefreshPatchStatus];
    });
}

- (NSString *)carsurfPatchStatusText {
    if (!self.carsurfIsEnabled) {
        return @"Off. Turn on Enable for CarPlay above to have carsurf-helperd "
               @"patch this app.";
    }

    CSPatchRecord *record = CSPatchStateRead(self.bundleIdentifier);
    if (!record) {
        return @"Not yet patched. Tap Patch Now below, then reopen this screen "
               @"in a few seconds to check the result.";
    }

    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateStyle = NSDateFormatterMediumStyle;
        formatter.timeStyle = NSDateFormatterShortStyle;
    });
    NSString *when = record.updatedAt ? [formatter stringFromDate:record.updatedAt] : @"unknown time";

    switch (record.status) {
        case CSPatchStatusPatched: {
            NSString *version = record.appVersion.length
                ? [NSString stringWithFormat:@" (version %@)", record.appVersion] : @"";
            return [NSString stringWithFormat:@"Patched %@%@. If this app updated since "
                    @"then, tap Patch Now to re-check it.", when, version];
        }
        case CSPatchStatusNative:
            return [NSString stringWithFormat:@"This app already has real CarPlay support "
                    @"built in, running more than one CarPlay scene at once — checked %@. "
                    @"Nothing to patch, and its scene isn't bridged either; it uses its own "
                    @"CarPlay interface entirely.", when];
        case CSPatchStatusNativeBridged:
            return [NSString stringWithFormat:@"This app has real CarPlay support built in — "
                    @"checked %@. Its binary was never touched, but its CarPlay scene is "
                    @"bridged to show its full phone interface instead of Apple's template UI.",
                    when];
        case CSPatchStatusFailed:
            return [NSString stringWithFormat:@"Last patch attempt failed at %@: %@", when,
                    record.failureReason ?: @"see device log."];
        case CSPatchStatusUnknown:
        default:
            return @"Not yet patched. Tap Patch Now below.";
    }
}

- (void)carsurfRefreshPatchStatus {
    if (!_carsurfStatusGroup) return;
    [_carsurfStatusGroup setProperty:self.carsurfPatchStatusText forKey:@"footerText"];
    [self.table reloadData];
}

- (NSArray<PSSpecifier *> *)specifiers {
    if (_carsurfReentering) return _carsurfSpecifiers ?: @[];

    _carsurfReentering = YES;
    NSArray<PSSpecifier *> *stored = [super specifiers];
    _carsurfReentering = NO;
    if (stored.count > 0) return stored;

    if (!_carsurfSpecifiers) {
        NSMutableArray<PSSpecifier *> *result = [NSMutableArray new];

        // The one thing this whole screen exists to do: everything below is
        // detail for an app that's already on.
        PSSpecifier *enableGroup = [PSSpecifier groupSpecifierWithName:nil];
        [enableGroup setProperty:CSUsesRuntimeCarPlayAdmission()
                                     ? @"Puts this app on the CarPlay dashboard. "
                                       @"Nothing on disk is modified — the app keeps "
                                       @"its original signature."
                                     : @"Puts this app on the CarPlay dashboard. "
                                       @"carsurf-helperd patches it in the background — "
                                       @"see status below."
                          forKey:@"footerText"];
        [result addObject:enableGroup];

        PSSpecifier *enable =
            [PSSpecifier preferenceSpecifierNamed:@"Enable for CarPlay"
                                            target:self
                                               set:@selector(setEnabled:specifier:)
                                               get:@selector(readEnabled:)
                                            detail:Nil
                                              cell:PSSwitchCell
                                              edit:Nil];
        [result addObject:enable];

        // The whole qualification section only means something where the app has
        // to be patched on disk. Before iOS 18 admission happens at runtime and
        // the bundle is never touched, so a status line, a "Patch Now" button and
        // a patch log would all describe work that never runs.
        if (!CSUsesRuntimeCarPlayAdmission()) {
            // Patching is manual for now: nothing on-device notices an app update
            // by itself, so if YouTube (or any enabled app) drops off CarPlay
            // after updating, this is where the user comes to fix it.
            _carsurfStatusGroup = [PSSpecifier groupSpecifierWithName:@"CarPlay Qualification"];
            [_carsurfStatusGroup setProperty:self.carsurfPatchStatusText forKey:@"footerText"];
            [result addObject:_carsurfStatusGroup];

            PSSpecifier *patchNow =
                [PSSpecifier preferenceSpecifierNamed:@"Patch Now"
                                                target:self
                                                   set:NULL
                                                   get:NULL
                                                detail:Nil
                                                  cell:PSButtonCell
                                                  edit:Nil];
            patchNow.buttonAction = @selector(carsurfPatchNow);
            [result addObject:patchNow];

            PSSpecifier *patchLog =
                [PSSpecifier preferenceSpecifierNamed:@"View Live Patch Log"
                                                target:self
                                                   set:NULL
                                                   get:NULL
                                                detail:CSPatchLogController.class
                                                  cell:PSLinkCell
                                                  edit:Nil];
            [patchLog setProperty:self.bundleIdentifier forKey:@"carsurfBundle"];
            [result addObject:patchLog];
        }

        // Only apps that ship their own CarPlay support have two interfaces to
        // choose between; for everything else CarSurf has nothing but the phone
        // scene to show, so the setting is inert rather than hidden — the app
        // list has no way to know which is which before the daemon has looked.
        PSSpecifier *interfaceGroup =
            [PSSpecifier groupSpecifierWithName:@"CarPlay Interface"];
        [interfaceGroup setProperty:@"For an app that already supports CarPlay, "
                                    @"choose between the CarPlay interface it "
                                    @"ships and its ordinary phone screen. Auto "
                                    @"keeps the app's own interface when it runs "
                                    @"several CarPlay screens at once (map, "
                                    @"dashboard, instrument cluster) and bridges "
                                    @"the phone screen otherwise. Apps without "
                                    @"CarPlay support of their own always use "
                                    @"the phone screen."
                            forKey:@"footerText"];
        [result addObject:interfaceGroup];

        PSSpecifier *sceneSource =
            [PSSpecifier preferenceSpecifierNamed:@"Show On Car Display"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSegmentCell
                                              edit:Nil];
        [sceneSource setProperty:@"sceneSource" forKey:@"carsurfKey"];
        [sceneSource setProperty:@[ @"Auto", @"Its Own", @"Phone Screen" ]
                          forKey:@"carsurfItems"];
        [sceneSource setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
        [sceneSource setProperty:@(84.0) forKey:@"height"];
        [result addObject:sceneSource];

        PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"CarPlay Display"];
        [group setProperty:@"Choose the viewport and whether the app should build its "
                           @"interface as an iPhone or iPad. Use CarPlay Screen Size "
                           @"makes apps read the head-unit dimensions."
                   forKey:@"footerText"];
        [result addObject:group];

        PSSpecifier *layout =
            [PSSpecifier preferenceSpecifierNamed:@"Layout"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSegmentCell
                                              edit:Nil];
        [layout setProperty:@"layoutMode" forKey:@"carsurfKey"];
        [layout setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
        [layout setProperty:@(84.0) forKey:@"height"];
        [result addObject:layout];

        PSSpecifier *idiom =
            [PSSpecifier preferenceSpecifierNamed:@"Interface Idiom"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSegmentCell
                                              edit:Nil];
        [idiom setProperty:@"idiomMode" forKey:@"carsurfKey"];
        [idiom setProperty:@[ @"Auto", @"iPhone", @"iPad" ] forKey:@"carsurfItems"];
        [idiom setProperty:CSLayoutSegmentCell.class forKey:@"cellClass"];
        [idiom setProperty:@(84.0) forKey:@"height"];
        [result addObject:idiom];

        PSSpecifier *carScreen =
            [PSSpecifier preferenceSpecifierNamed:@"Use CarPlay Screen Size"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSwitchCell
                                              edit:Nil];
        [carScreen setProperty:@"spoofMainScreen" forKey:@"carsurfKey"];
        [result addObject:carScreen];

        PSSpecifier *scale =
            [PSSpecifier preferenceSpecifierNamed:@"Render Scale"
                                            target:self
                                               set:@selector(setAppValue:specifier:)
                                               get:@selector(readAppValue:)
                                            detail:Nil
                                              cell:PSSliderCell
                                              edit:Nil];
        [scale setProperty:@"scale" forKey:@"carsurfKey"];
        [scale setProperty:@(0.5) forKey:@"min"];
        [scale setProperty:@(2.0) forKey:@"max"];
        [scale setProperty:@(1.0) forKey:@"default"];
        [scale setProperty:@YES forKey:@"showValue"];
        [scale setProperty:@YES forKey:@"isContinuous"];
        [result addObject:scale];

        PSSpecifier *applyGroup =
            [PSSpecifier groupSpecifierWithName:@"Apply Changes"];
        [applyGroup setProperty:@"Close the app after changing layout or scale. "
                                @"The next phone or CarPlay launch uses the new values."
                        forKey:@"footerText"];
        [result addObject:applyGroup];

        PSSpecifier *close =
            [PSSpecifier preferenceSpecifierNamed:@"Close App to Apply Changes"
                                            target:self
                                               set:NULL
                                               get:NULL
                                            detail:Nil
                                              cell:PSButtonCell
                                              edit:Nil];
        close.buttonAction = @selector(closeApp);
        [close setProperty:@YES forKey:@"isDestructive"];
        [result addObject:close];
        _carsurfSpecifiers = result;
    }

    _carsurfReentering = YES;
    [self setSpecifiers:_carsurfSpecifiers];
    _carsurfReentering = NO;
    return _carsurfSpecifiers;
}

- (id)readAppValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    CSPrefsStore *store = CSPrefsStore.sharedStore;
    id value = [store value:key forApp:self.bundleIdentifier];
    if (!value) value = [store defaultValueForKey:key];
    if (value) return value;
    if ([key isEqualToString:@"scale"]) return @(1.0);
    if ([key isEqualToString:@"layoutMode"]) return @(CSLayoutModeHorizontal);
    if ([key isEqualToString:@"idiomMode"]) return @(CSIdiomModePhone);
    if ([key isEqualToString:@"sceneSource"]) return @(CSSceneSourceAuto);
    return @NO;
}

- (void)setAppValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"carsurfKey"];
    [CSPrefsStore.sharedStore setValue:value key:key
                                  forApp:self.bundleIdentifier];
}

- (void)carsurfPatchNow {
    NSString *bundleID = self.bundleIdentifier;
    if (bundleID.length == 0) return;

    if (!self.carsurfIsEnabled) {
        // The daemon only ever touches bundles in the enabled set — a request
        // for one that isn't enabled would just be silently ignored, which is
        // a worse experience than telling the user why nothing happened.
        [self carsurfPresentAlertTitle:@"Not Enabled"
                                message:@"Turn on Enable for CarPlay above first — "
                                        @"the daemon only patches apps that are "
                                        @"switched on."];
        return;
    }
    if (_carsurfPatching) return; // already watching one attempt; ignore the repeat tap

    _carsurfPatching = YES;
    _carsurfPatchGeneration++;
    NSInteger generation = _carsurfPatchGeneration;
    // Whatever's on record right now — even nil — is the baseline. The poll
    // below is done the moment carsurf-helperd writes anything that isn't this.
    _carsurfPatchBaselineDate = CSPatchStateRead(bundleID).updatedAt;

    CSPatchRequestSubmit(bundleID);
    [self carsurfShowProgressOverlay];
    [self carsurfPollPatchGeneration:generation elapsedSeconds:0];
}

- (void)carsurfPollPatchGeneration:(NSInteger)generation elapsedSeconds:(NSTimeInterval)elapsed {
    static const NSTimeInterval kPollInterval = 0.6;
    static const NSTimeInterval kTimeout = 20.0;

    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
        __strong __typeof(weakSelf) self = weakSelf;
        // Superseded by a newer tap, or the screen was left — stop silently.
        if (!self || generation != self->_carsurfPatchGeneration) return;

        CSPatchRecord *record = CSPatchStateRead(self.bundleIdentifier);
        BOOL changed = record != nil &&
            (self->_carsurfPatchBaselineDate == nil ||
             ![record.updatedAt isEqualToDate:self->_carsurfPatchBaselineDate]);
        NSTimeInterval nextElapsed = elapsed + kPollInterval;

        if (changed) {
            self->_carsurfPatching = NO;
            [self carsurfRefreshPatchStatus];
            [self carsurfHideProgressOverlayWithCompletion:^{
                switch (record.status) {
                    case CSPatchStatusPatched:
                        [self carsurfPresentAlertTitle:@"Patched"
                                                message:@"This app now qualifies for CarPlay."];
                        break;
                    case CSPatchStatusNative:
                        [self carsurfPresentAlertTitle:@"Already CarPlay-Ready"
                                                message:@"This app already has real CarPlay "
                                                        @"support built in — nothing needed "
                                                        @"patching, and its scene runs "
                                                        @"unbridged, on its own."];
                        break;
                    case CSPatchStatusNativeBridged:
                        [self carsurfPresentAlertTitle:@"Already CarPlay-Ready"
                                                message:@"This app already has real CarPlay "
                                                        @"support built in — nothing needed "
                                                        @"patching, but its scene is bridged "
                                                        @"to show its phone interface."];
                        break;
                    default:
                        [self carsurfPresentPatchFailureWithMessage:
                            record.failureReason ?: @"See the live patch log for details."];
                        break;
                }
            }];
            return;
        }

        if (nextElapsed >= kTimeout) {
            self->_carsurfPatching = NO;
            [self carsurfRefreshPatchStatus];
            [self carsurfHideProgressOverlayWithCompletion:^{
                [self carsurfPresentAlertTitle:@"Still Working"
                                        message:@"No result yet after 20 seconds. "
                                                @"carsurf-helperd may still be patching "
                                                @"this app — check back shortly."];
            }];
            return;
        }

        [self carsurfPollPatchGeneration:generation elapsedSeconds:nextElapsed];
    });
}

#pragma mark - Progress overlay

- (void)carsurfShowProgressOverlay {
    if (_carsurfProgressOverlay) return;

    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    overlay.alpha = 0;

    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemBackgroundColor;
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [overlay addSubview:card];

    UIActivityIndicatorView *spinner =
        [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:spinner];

    UILabel *label = [UILabel new];
    label.text = @"Patching…";
    label.font = [UIFont systemFontOfSize:15];
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintGreaterThanOrEqualToConstant:160],

        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],

        [label.topAnchor constraintEqualToAnchor:spinner.bottomAnchor constant:10],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-20],
    ]];

    [self.view addSubview:overlay];
    _carsurfProgressOverlay = overlay;

    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 1;
    }];
}

- (void)carsurfHideProgressOverlayWithCompletion:(void (^)(void))completion {
    UIView *overlay = _carsurfProgressOverlay;
    _carsurfProgressOverlay = nil;
    if (!overlay) {
        if (completion) completion();
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
        if (completion) completion();
    }];
}

- (void)carsurfPresentAlertTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:title message:message
                                      preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)carsurfPresentPatchFailureWithMessage:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Patch Failed"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"View Log"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            PSSpecifier *specifier = [PSSpecifier
                preferenceSpecifierNamed:@"Patch Log" target:self set:NULL get:NULL
                detail:CSPatchLogController.class cell:PSLinkCell edit:Nil];
            [specifier setProperty:self.bundleIdentifier forKey:@"carsurfBundle"];
            CSPatchLogController *controller = [CSPatchLogController new];
            controller.specifier = specifier;
            [self pushController:controller];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Share Log"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [CSPatchLogController presentShareSheetFromController:self
                                                       sourceView:self.view
                                                 bundleIdentifier:self.bundleIdentifier];
        });
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)closeApp {
    NSString *bundleID = self.bundleIdentifier;
    if (bundleID.length == 0) return;
    NSString *notification =
        [@"com.pavunato.carsurf/close/" stringByAppendingString:bundleID];
    notify_post(notification.UTF8String);
}

@end
