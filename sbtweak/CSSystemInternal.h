#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Patches CARAppEntitlements so allowlisted apps look CarPlay-capable (gate G1,
/// first half). No-op if CarPlaySupport is not loaded in this process.
void CSInstallEntitlementSpoof(void);

/// Upstream half of gate G1 on iOS 18.x: reports UIWindowSceneSessionRoleCarPlay
/// in allowlisted apps' scene manifests so CarKit builds a declaration for them
/// at all. Without this the policy hook below is never consulted.
void CSInstallSceneManifestSpoof(void);

/// Gate G1 on iOS 18.x: CarKit's CRCarPlayAppPolicyEvaluator decides which apps
/// may appear on the car screen. No-op on releases that predate CarKit's policy
/// API, where the CARApplication path below applies instead.
void CSInstallCarKitPolicyHook(void);

/// Patches the CARApplication class-level app list so the dashboard sees the
/// genuine CarPlay apps plus the user's allowlist, and nothing else (gate G1,
/// second half).
void CSInstallAppListFilter(void);

/// SpringBoard mirrors the effective preferences to a world-readable relay file
/// so sandboxed app processes without libSandy can still read them.
void CSStartRelay(void);

NS_ASSUME_NONNULL_END
