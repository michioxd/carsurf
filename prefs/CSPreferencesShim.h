// Minimal declarations for Preferences.framework, which ships no public headers.
// Only what the two controllers below actually call.

#import <UIKit/UIKit.h>

typedef enum {
    PSGroupCell,
    PSLinkCell,
    PSLinkListCell,
    PSListItemCell,
    PSTitleValueCell,
    PSSliderCell,
    PSSwitchCell,
    PSStaticTextCell,
    PSEditTextCell,
    PSSegmentCell,
    PSGiantIconCell,
    PSGiantCell,
    PSSecureEditTextCell,
    PSButtonCell,
    PSEditTextViewCell,
} PSCellType;

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(PSCellType)cell
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) id identifier;
@property (nonatomic, assign) SEL buttonAction;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (id)performGetter;
- (void)performSetterWithValue:(id)value;
@end

@interface PSTableCell : UITableViewCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier;
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
@property (nonatomic, strong) PSSpecifier *specifier;
@property (nonatomic, readonly) UILabel *titleLabel;
@end

@interface PSViewController : UIViewController
@property (nonatomic, strong) PSSpecifier *specifier;
@end

@interface PSListController : PSViewController
@property (nonatomic, readonly) UITableView *table;
- (NSArray<PSSpecifier *> *)specifiers;
- (void)setSpecifiers:(NSArray<PSSpecifier *> *)specifiers;
- (void)reloadSpecifiers;
- (void)pushController:(id)controller;
- (PSSpecifier *)specifierAtIndex:(NSInteger)index;
@end

@interface UIImage (CSPrefsPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                                format:(int)format
                                                 scale:(CGFloat)scale;
@end
