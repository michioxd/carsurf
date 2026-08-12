// Declarations for private API the tweak touches. Nothing here is guaranteed to
// exist on a given iOS build — every use site goes through the guarded lookup in
// CSRuntime.h. See ARCHITECTURE.md §5.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - MobileCoreServices

@interface LSApplicationProxy : NSObject
+ (nullable instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly, nullable) NSString *localizedName;
@property (nonatomic, readonly) NSDictionary *entitlements;
@property (nonatomic, readonly) NSString *applicationType; // User / System / Internal
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray<LSApplicationProxy *> *)allApplications;
@end

#pragma mark - CarPlaySupport.framework

/// Wraps an installed app from CarPlay's point of view. `-entitlements` is the
/// gate that decides whether the app reaches the dashboard icon grid.
@interface CARAppEntitlements : NSObject
@end

@interface CARApplication : NSObject
+ (nullable NSArray<CARApplication *> *)_allInstalledApplications;
+ (nullable NSDictionary<NSString *, CARApplication *> *)_allInstalledApplicationsByBundleIdentifier;
+ (nullable instancetype)applicationWithBundleIdentifier:(NSString *)bundleIdentifier;
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic, readonly, nullable) LSApplicationProxy *applicationProxy;
@property (nonatomic, readonly, nullable) CARAppEntitlements *entitlements;
@end

#pragma mark - UIKit scene internals

/// Parsed form of UIApplicationSceneManifest in an app's Info.plist. When an app
/// ships no manifest, UIKit still builds one of these in single-window
/// compatibility mode.
@interface UIApplicationSceneManifest : NSObject
@property (nonatomic, readonly) BOOL supportsMultipleScenes;
@property (nonatomic, readonly, nullable) NSDictionary *sceneConfigurations;
- (nullable id)configurationForRole:(NSString *)role;
@end

@interface UIApplicationSceneSpecification : NSObject
@end

@interface UISceneConfiguration (CSPrivate)
- (void)_setSceneClass:(Class)sceneClass;
- (void)_setDelegateClass:(Class)delegateClass;
@end

@interface UIApplication (CSPrivate)
- (nullable UIApplicationSceneManifest *)_sceneManifest;
+ (BOOL)_supportsMultipleScenes;
@end

@interface UIScene (CSPrivate)
@property (nonatomic, readonly, nullable) id _FBSScene;
@end

@interface UIScreen (CSPrivate)
- (BOOL)_isCarScreen;
@property (nonatomic, readonly) NSInteger _displayIdentity;
@end

#pragma mark - FrontBoardServices

@interface FBSDisplayIdentity : NSObject
@property (nonatomic, readonly) BOOL isMainDisplay;
@property (nonatomic, readonly) BOOL isCarDisplay;
@property (nonatomic, readonly) NSString *displayName;
@end

@interface FBSDisplayConfiguration : NSObject
@property (nonatomic, readonly) FBSDisplayIdentity *identity;
@property (nonatomic, readonly) CGSize pixelSize;
@property (nonatomic, readonly) CGFloat scale;
@end

#pragma mark - QuartzCore layer hosting (mirror mode)

@interface CALayerHost : CALayer
@property (nonatomic, assign) uint32_t contextId;
@end

@interface CAContext : NSObject
+ (NSArray<CAContext *> *)allContexts;
@property (nonatomic, readonly) uint32_t contextId;
@property (nonatomic, strong, nullable) CALayer *layer;
@end

@interface UIWindow (CSPrivate)
@property (nonatomic, readonly, nullable) CAContext *_context;
@end

NS_ASSUME_NONNULL_END
