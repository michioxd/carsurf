#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// YES when CarPlay admission is granted at runtime rather than by patching the
/// app on disk — i.e. everything before iOS 18.
///
/// On iOS 16/17 DashBoard filters the app library by asking LSBundleProxy for
/// entitlements (`_proxyPassesInclusionFilter`), so CSSceneManifestSpoof.m can
/// admit an app with its Apple signature completely intact. iOS 18 moved the gate
/// into CarKit, which never consults LaunchServices, and there the on-disk patch
/// is the only route.
///
/// Patching where runtime admission applies is not merely redundant, it breaks
/// apps: on RootHide the trustcache refuses every path under
/// /var/containers/Bundle/Application, so a re-signed binary is ad-hoc signed,
/// untrusted, and killed at exec with no crash report. Callers must therefore
/// leave the bundle strictly alone when this returns YES — reverting is equally
/// destructive, since re-signing can never restore Apple's original CMS
/// signature.
BOOL CSUsesRuntimeCarPlayAdmission(void);

/// The on-disk "indicator" for whether an app currently qualifies for CarPlay.
///
/// carsurf-helperd is the only writer (it runs as root and is the only process that
/// can re-sign a bundle). Everyone else — the CarKit policy hook in SpringBoard,
/// the Settings UI — only ever reads this. That split matters after an App Store
/// update: the update silently strips the SBStarkCapable entitlement the helper
/// added, and until the helper re-patches the bundle (manually, for now — see
/// CSPatchRequestSubmit), this file is the only place that recorded fact is
/// visible from. Trusting the user's "enabled" toggle alone would say the app is
/// fine when its on-disk patch has actually been wiped.
///
/// Stored at /var/jb/Library/CarSurf/patched.plist, the same directory
/// CSConfig's relay already proves reachable from every process that needs it
/// (see CSRelay.m) — root-owned, mobile-writable, world-readable.
typedef NS_ENUM(NSInteger, CSPatchStatus) {
    /// No patch has ever been attempted, or the state file could not be read.
    CSPatchStatusUnknown = 0,
    /// The most recent patch attempt succeeded and is believed to still be in
    /// effect. Not re-verified against the live binary on every read — only
    /// carsurf-helperd re-checks that, on reconcile or on a manual request.
    CSPatchStatusPatched,
    /// The most recent patch attempt failed; see -failureReason.
    CSPatchStatusFailed,
    /// No longer written: CarSurf used to leave an app that runs several
    /// concurrent CarPlay scenes (Waze) on its own template UI, and this said
    /// so. Every enabled app is bridged now, so the daemon records
    /// CSPatchStatusNativeBridged for those too. Still read, because a state
    /// file written by an older build can carry it, and CSCarKitPolicy.m must
    /// keep leaving CarKit's own admission alone for one — nothing bridges
    /// that app's scene until the daemon next reconciles it.
    CSPatchStatusNative,
    /// Has real Apple-issued CarPlay entitlements, so its binary is never
    /// touched, but CarSurf bridges its phone scene onto the car display all
    /// the same. CSApp.m installs the scene bridge, CSSceneManifestSpoof.m
    /// hides the app's template entitlements and scene roles from CarPlay so
    /// no template scene is built, and CSCarKitPolicy.m forces
    /// launchUsingTemplateUI off exactly as it would for CSPatchStatusPatched.
    CSPatchStatusNativeBridged,
};

@interface CSPatchRecord : NSObject
@property (nonatomic, readonly) CSPatchStatus status;
@property (nonatomic, readonly, nullable) NSDate *updatedAt;
/// CFBundleShortVersionString observed at the time of this attempt. Display-only
/// — the daemon does not use it to decide whether to re-patch; it just re-reads
/// the live entitlement, which is idempotent and version-agnostic.
@property (nonatomic, readonly, nullable) NSString *appVersion;
@property (nonatomic, readonly, nullable) NSString *failureReason;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// nil if no record exists (never patched, or state unreadable).
CSPatchRecord *_Nullable CSPatchStateRead(NSString *bundleIdentifier);

/// Convenience for the common case: YES only for CSPatchStatusPatched. NO for
/// CSPatchStatusNative — deliberately: see the enum's doc comment. Callers
/// that want to admit both a bridged app and a native one need to check both.
BOOL CSPatchStateIsPatched(NSString *_Nullable bundleIdentifier);

/// YES only for CSPatchStatusNative (the complex, hands-off case).
BOOL CSPatchStateIsNative(NSString *_Nullable bundleIdentifier);

/// YES only for CSPatchStatusNativeBridged.
BOOL CSPatchStateIsNativeBridged(NSString *_Nullable bundleIdentifier);

/// All bundle identifiers currently recorded as patched. Used by the daemon to
/// know what to revert when an app is disabled or removed from the allowlist.
NSArray<NSString *> *CSPatchStateAllPatchedIdentifiers(void);

// --- Writer side: carsurf-helperd only (runs as root). ------------------------

void CSPatchStateRecordSuccess(NSString *bundleIdentifier, NSString *_Nullable appVersion);
void CSPatchStateRecordNativeBridged(NSString *bundleIdentifier, NSString *_Nullable appVersion);
void CSPatchStateRecordFailure(NSString *bundleIdentifier, NSString *_Nullable reason);
void CSPatchStateRemove(NSString *bundleIdentifier);

// --- Manual "patch now" request queue ---------------------------------------
//
// Part 1 is manual for now: the Settings UI writes a request naming the bundle
// it wants re-checked, then posts the fixed darwin notification below. Darwin
// notify has no per-bundle payload, so the bundle identifier travels through a
// small request file in the same mobile-writable directory instead — cheaper
// than registering one notification name per enabled app.

FOUNDATION_EXPORT NSString *const CSPatchRequestNotification;

/// Settings-process side: queues a bundle for carsurf-helperd to re-check and wakes
/// it. Safe to call from a sandboxed process — the directory is mobile-writable.
void CSPatchRequestSubmit(NSString *bundleIdentifier);

/// Daemon side: reads and clears the queued bundle identifiers.
NSArray<NSString *> *CSPatchRequestTakeAll(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
