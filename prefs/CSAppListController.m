#import "CSAppListController.h"
#import "CSAppOptionsController.h"
#import "CSPrefsStore.h"
#import "CSPrivate.h"
#import "CSLog.h"
#import "CSAppFilter.h"
#import <objc/runtime.h>

// One list, one screen per app: every installed app is a row here, and tapping
// any of them — enabled or not — goes straight to CSAppOptionsController,
// which now carries the enable switch itself. Enabling used to live in this
// list (as an inline switch) while layout/scale/patch-status lived in a
// separate "Per-App Display" list that only showed apps already enabled —
// two lists to visit, and the second one was invisible until you'd already
// committed to the first. Collapsing them means the whole "get an app onto
// CarPlay" flow is: open the app's row, flip one switch.
/// Settings renders a list row's icon in a fixed, small square (about the size
/// stock apps like Notifications use). The private accessor below hands back
/// an icon sized for the home screen instead, and letting PSTableCell scale
/// that on the fly is what produced icons that didn't fit the row — oversized,
/// and not vertically centered with the text baseline next to them. Rendering
/// our own small, rounded copy up front sidesteps whatever that cell does with
/// an unexpectedly large image.
static UIImage *CSSmallAppIcon(NSString *bundleIdentifier) {
    if (![UIImage respondsToSelector:
             @selector(_applicationIconImageForBundleIdentifier:format:scale:)]) {
        return nil;
    }
    UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier
                                                                 format:2
                                                                  scale:UIScreen.mainScreen.scale];
    if (!icon) return nil;

    const CGFloat side = 28.0;
    UIGraphicsImageRendererFormat *format = UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        UIBezierPath *clip = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                                          cornerRadius:side * 0.22];
        [clip addClip];
        [icon drawInRect:CGRectMake(0, 0, side, side)];
    }];
}

@implementation CSAppListController {
    NSArray<PSSpecifier *> *_carsurfSpecifiers;
    BOOL _carsurfReentering;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Apps";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // On/off values shown per row can go stale after a trip into an app's
    // detail screen and back, so refresh them rather than only on first load.
    [self.table reloadData];
}

- (NSArray<PSSpecifier *> *)specifiers {
    // Settings tears down PSListController's own specifier state when the pane is
    // backgrounded and rebuilt on resume. The conventional theos pattern survives
    // that by caching in PS's private _specifiers ivar, which is not exported, so
    // instead: trust PS's state when it has any, and re-apply ours when it does
    // not. Without this the pane comes back blank after a trip to the home screen.
    if (_carsurfReentering) return _carsurfSpecifiers ?: @[];

    _carsurfReentering = YES;
    NSArray<PSSpecifier *> *stored = [super specifiers];
    _carsurfReentering = NO;
    if (stored.count > 0) return stored;

    if (!_carsurfSpecifiers) _carsurfSpecifiers = [self buildSpecifiers];

    _carsurfReentering = YES;
    [self setSpecifiers:_carsurfSpecifiers];
    _carsurfReentering = NO;

    CSLogImpl("prefs", "%s restored %lu specifiers after PS state was cleared",
                object_getClassName(self), (unsigned long)_carsurfSpecifiers.count);
    return _carsurfSpecifiers;
}

- (NSArray<PSSpecifier *> *)buildSpecifiers {
    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray new];

    PSSpecifier *userGroup = [PSSpecifier groupSpecifierWithName:@"Installed Apps"];
    [userGroup setProperty:@"Tap an app, then turn on Enable for CarPlay. Apps that "
                           @"already support CarPlay natively don't need this — they "
                           @"keep working either way."
                    forKey:@"footerText"];
    [specifiers addObject:userGroup];
    [specifiers addObjectsFromArray:[self specifiersForApplicationsOfType:@"User"]];

#if !CARSURF_HIDE_SYSTEM_APPS
    // Off by default (CARSURF_HIDE_SYSTEM_APPS=1 in the top-level Makefile).
    // A system app can carry a dedicated seatbelt profile that only grants
    // after verifying the binary's *real* Apple signature — no re-signing
    // tool can satisfy that, entitlements can be reverted but the signature
    // never can, and there is no fix short of restoring the bundle from the
    // jailbreak's own system-app tooling. Confirmed the hard way on Photos.
    // The daemon's CSHasDedicatedSandboxProfile guard already refuses to
    // touch one; this keeps a user from trying in the first place.
    PSSpecifier *systemGroup = [PSSpecifier groupSpecifierWithName:@"System Apps"];
    [systemGroup setProperty:@"Bridging built-in apps is more likely to misbehave; "
                             @"try one at a time."
                      forKey:@"footerText"];
    [specifiers addObject:systemGroup];
    [specifiers addObjectsFromArray:[self specifiersForApplicationsOfType:@"System"]];
#endif

    return specifiers;
}

- (NSArray<PSSpecifier *> *)specifiersForApplicationsOfType:(NSString *)type {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass performSelector:@selector(defaultWorkspace)];
    NSArray<LSApplicationProxy *> *all = [workspace performSelector:@selector(allApplications)];

    NSMutableArray<LSApplicationProxy *> *matching = [NSMutableArray new];
    for (LSApplicationProxy *proxy in all) {
        if (![proxy.applicationType isEqualToString:type]) continue;
        // Most of the 200-plus registered "applications" are internal UIServices;
        // CSAppFilter keeps only what the user can actually launch.
        if (!CSAppIsUserVisible(proxy, NULL)) continue;
        [matching addObject:proxy];
    }

    [matching sortUsingComparator:^NSComparisonResult(LSApplicationProxy *a, LSApplicationProxy *b) {
        return [a.localizedName localizedCaseInsensitiveCompare:b.localizedName];
    }];

    NSMutableArray<PSSpecifier *> *specifiers = [NSMutableArray new];
    for (LSApplicationProxy *proxy in matching) {
        // PSLinkListCell: a disclosure row with a trailing value label, the same
        // shape stock Settings uses for e.g. Notifications > <app> [Banners]. The
        // label is this app's current on/off state, read live each time the row
        // draws, so the list itself doubles as a status overview.
        PSSpecifier *specifier =
            [PSSpecifier preferenceSpecifierNamed:proxy.localizedName
                                          target:self
                                             set:NULL
                                             get:@selector(readAppStateLabel:)
                                          detail:CSAppOptionsController.class
                                            cell:PSLinkListCell
                                            edit:Nil];
        specifier.identifier = proxy.applicationIdentifier;
        [specifier setProperty:proxy.applicationIdentifier forKey:@"carsurfBundle"];

        UIImage *icon = CSSmallAppIcon(proxy.applicationIdentifier);
        if (icon) [specifier setProperty:icon forKey:@"iconImage"];

        [specifiers addObject:specifier];
    }
    return specifiers;
}

#pragma mark - Value plumbing

- (id)readAppStateLabel:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:@"carsurfBundle"];
    return [CSPrefsStore.sharedStore isAppEnabled:bundleID] ? @"On" : @"Off";
}

@end
