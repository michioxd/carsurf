#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Read/write access to the tweak's preference plist from the Settings process.
///
/// PSListController's normal `defaults`/`key` mechanism only handles flat keys,
/// and the config is nested (`apps.<bundle id>.enabled`), so the specifiers use
/// custom get/set selectors that funnel through here.
@interface CSPrefsStore : NSObject

@property (class, nonatomic, readonly) CSPrefsStore *sharedStore;

- (nullable id)globalValueForKey:(NSString *)key;
- (void)setGlobalValue:(nullable id)value forKey:(NSString *)key;

- (nullable id)defaultValueForKey:(NSString *)key;
- (void)setDefaultValue:(nullable id)value forKey:(NSString *)key;

- (BOOL)isAppEnabled:(NSString *)bundleIdentifier;
- (void)setApp:(NSString *)bundleIdentifier enabled:(BOOL)enabled;

- (nullable id)value:(NSString *)key forApp:(NSString *)bundleIdentifier;
- (void)setValue:(nullable id)value key:(NSString *)key forApp:(NSString *)bundleIdentifier;

/// Bundle identifiers currently switched on.
@property (nonatomic, readonly) NSUInteger enabledAppCount;

@end

NS_ASSUME_NONNULL_END
