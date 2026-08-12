#import "CSLayoutSegmentCell.h"

@implementation CSLayoutSegmentCell {
    UILabel *_carsurfLabel;
    UISegmentedControl *_carsurfControl;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                     specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
               reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.titleLabel.hidden = YES;

    _carsurfLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _carsurfLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _carsurfLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _carsurfLabel.adjustsFontForContentSizeCategory = YES;
    _carsurfLabel.text = specifier.name ?: @"Layout";
    [self.contentView addSubview:_carsurfLabel];

    NSArray *items = [specifier propertyForKey:@"carsurfItems"];
    if (![items isKindOfClass:NSArray.class] || items.count == 0) {
        items = @[ @"Auto", @"Horizontal", @"Vertical" ];
    }
    _carsurfControl = [[UISegmentedControl alloc] initWithItems:items];
    _carsurfControl.translatesAutoresizingMaskIntoConstraints = NO;
    _carsurfControl.accessibilityLabel = specifier.name ?: @"Option";
    [_carsurfControl addTarget:self
                     action:@selector(carsurfLayoutChanged:)
           forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_carsurfControl];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_carsurfLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_carsurfLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
        [_carsurfLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9.0],
        [_carsurfControl.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_carsurfControl.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_carsurfControl.topAnchor constraintEqualToAnchor:_carsurfLabel.bottomAnchor constant:7.0],
        [_carsurfControl.heightAnchor constraintEqualToConstant:34.0],
        [_carsurfControl.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9.0],
    ]];

    [self carsurfRefreshValueFromSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.titleLabel.hidden = YES;
    _carsurfLabel.text = specifier.name ?: @"Layout";
    [self carsurfRefreshValueFromSpecifier:specifier];
}

- (void)carsurfRefreshValueFromSpecifier:(PSSpecifier *)specifier {
    if (!specifier || !_carsurfControl) return;
    NSInteger mode = [[specifier performGetter] integerValue];
    if (mode < 0 || mode > 2) mode = 0;
    _carsurfControl.selectedSegmentIndex = mode;
}

- (void)carsurfLayoutChanged:(UISegmentedControl *)control {
    [self.specifier performSetterWithValue:@(control.selectedSegmentIndex)];
}

@end
