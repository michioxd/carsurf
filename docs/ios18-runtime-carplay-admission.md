# iOS 18 runtime CarPlay admission without modifying the app

## Objective

Make an installed App Store application appear as a CarPlay app and launch into
the CarSurf phone-screen bridge without changing its bundle, executable,
entitlements, trust cache, or code signature.

This is a research/design document. The current iOS 18 implementation still
uses `carsurf-helperd` to grant `SBStarkCapable` on disk. The runtime path below
is the replacement to investigate; it is not enabled by this document.

## What changed on iOS 18

The older admission path was LaunchServices-driven. On iOS 16/17,
`DashBoard` asks `LSBundleProxy` for entitlement values while building its app
library. `CSSceneManifestSpoof.m` already demonstrates the safe version of that
approach: hook typed value getters, return `@YES` only for allowlisted bundles,
and leave the original object/type intact.

iOS 18 moves the important decision into CarKit:

1. CarKit creates a `CRCarPlayAppDeclaration` for an installed application.
2. `CRCarPlayAppPolicyEvaluator` receives that declaration.
3. `effectivePolicyForAppDeclaration:` returns a mutable
   `CRCarPlayAppPolicy`.
4. The policy contains `canDisplayOnCarScreen`, `isCarPlayCapable`,
   `isCarPlaySupported`, and `launchUsingTemplateUI`.
5. CarPlay uses that policy to decide how the app is presented.

The current hook in [`CSCarKitPolicy.m`](../sbtweak/CSCarKitPolicy.m) is useful
but late. It can promote a policy only after a declaration already exists. It
cannot create a declaration for an app that CarKit never considered. The
current comments and logs also show that CarKit no longer consults the
`LSBundleProxy` entitlement getters for this initial roster on iOS 18.

## Historical iOS 18 experiment already preserved

The separate branch `research/fpt-play-runtime-admission` contains a more
specific result from the FPT Play investigation. It should be treated as the
starting point for the next implementation, not rediscovered from scratch:

- On iOS 18.5, `+[CRCarPlayAppDeclaration
  declarationForBundleIdentifier:info:entitlements:]` was observed in
  SpringBoard building every declaration. The probe recorded 492 calls, with
  66 genuine declarations and `nil` for ordinary apps.
- The `entitlements` argument is an `LSBundleInfoCachedValues` object. CarKit
  asks it for the admission key `SBStarkCapable` while building the declaration.
- Re-running the original factory with a per-call `NSProxy` stand-in for that
  one argument produced a valid declaration for an allowlisted app without
  changing its bundle or signature.
- The stand-in forwards every selector to the real object and only answers
  `boolForKey:` / `objectForKey:...` lookups for `SBStarkCapable`, preserving the
  exact BOOL-versus-object return type.
- The experiment deliberately avoids swizzling `LSBundleInfoCachedValues` or
  other hot CoreServices paths. An earlier attempt there caused the CarPlay
  link to remain in an endless “connecting” retry loop.
- CarPlay declarations were observed being built in SpringBoard; admitting
  only in another process produced no useful dashboard result.

This changes the status of the plan: the declaration producer and the
entitlement argument are no longer unknown. The next work is to port that
isolated factory/stand-in experiment into the current branch, add its runtime
admission ledger, and then verify the scene launch path. The research branch is
intentionally not merged because it was based on an earlier Portal layout and
would remove current dual-app code if merged wholesale.

## The runtime-only architecture

The desired flow is:

```text
allowlist change
    -> invalidate/rebuild CarKit's app declaration/library cache
    -> synthesize or admit a CRCarPlayAppDeclaration for the bundle
    -> promote CRCarPlayAppPolicy in the evaluator
    -> CarPlay launches a CarPlay UIWindowScene
    -> CSApp scene bridge renders the phone UI
```

Nothing in this flow writes into the target app bundle. The tweak remains
injected into the system processes (`SpringBoard`, `CarPlay`, and any lazy
CarKit host) and into the target app process through the existing substrate
configuration.

## Where to instrument first

### 1. Reproduce the declaration factory safely

The preserved experiment identifies the primary selector:
`+[CRCarPlayAppDeclaration declarationForBundleIdentifier:info:entitlements:]`.
First reproduce it in observe-only mode and confirm that it still runs in
SpringBoard on the target iOS 18 build. The existing
`-[CRCarPlayAppDeclaration setBundleIdentifier:]` trace remains useful for
capturing the caller stack, but it is no longer the discovery step.

Enable verbose logging, reconnect CarPlay, and capture the declaration trace:

```text
carsurf-logs -c
enable verboseLogging in CarSurf preferences
disconnect/reconnect CarPlay
carsurf-logs
```

The factory result and process identity are the most valuable regression
artifacts. Do not move the admission hook into `carkitd` or a global
`LSBundleInfoCachedValues` swizzle; the preserved experiment showed that those
hot paths can destabilize the CarPlay connection.

For each class in that stack, record methods with:

```text
carsurf-classes --methods ClassName
```

The target hook should be the narrowest method that either enumerates app
declarations or constructs one from a bundle identifier. Prefer modifying the
returned collection or declaration object after the original method returns;
do not replace a whole private database object unless its concrete class and
type contract are known.

### 2. Keep the per-call entitlement stand-in narrow

The first implementation should retain the original factory and replace only
the `entitlements` argument for an allowlisted bundle with a forwarding
`NSProxy`. Log the selectors received by that stand-in and compare a genuine
app with an ordinary app. The known admission key is `SBStarkCapable`; verify
whether the target release still asks for only that key before adding any
others. Preserve exact return types:

- `boolForKey:` returns a raw `BOOL`.
- `objectForKey:` and its typed variants return `@YES`.

Do not synthesize a complete `CRCarPlayAppDeclaration` manually. The factory
must continue to populate all fields CarKit expects. The stand-in should be
used only when the original factory returned `nil`, and only for an enabled,
non-native bundle.

Then trace a genuine CarPlay app and an ordinary app side by side. Log every
declaration property read by the evaluator and compare:

- bundle identifier / application proxy
- `requiredEntitlementKeys`
- scene-role or manifest information
- capability/category fields
- certificate/team/signing metadata
- whether a declaration is rejected before the policy evaluator

The runtime route is viable only if the declaration's admission inputs are
object-level values that CarKit obtains through a hookable process. If CarKit
performs a direct kernel/Security-framework signature validation before the
declaration is created, that check cannot be forged by an ordinary Objective-C
swizzle and the no-patch goal is not achievable for that gate.

### 3. Promote the resulting policy

Keep [`CSCarKitPolicy.m`](../sbtweak/CSCarKitPolicy.m) as the final policy hook,
but remove its dependency on `CSPatchStateIsPatched` for a successfully
runtime-admitted app. Add a separate state such as `runtime-admitted` or
`native-runtime-bridged` so that:

- a user-enabled declaration is promoted only after the declaration hook
  confirms admission;
- native CarPlay apps retain CarKit's own template policy;
- phone-screen apps get `launchUsingTemplateUI = NO`;
- a failed declaration experiment does not make every enabled app appear
  qualified.

`CSPatchState` should become an admission ledger, not only an on-disk patch
ledger. The helper daemon must not run `ldid`, `jbctl`, or mutate an app when
the runtime route succeeds.

## Scene launch requirements

Admission alone is not enough. A plain phone-screen app still needs a
CarPlay-window scene that can be hosted on the car display.

The existing app-side pieces are the reusable part:

- [`CSSceneBridge.m`](../apptweak/CSSceneBridge.m) maps the CarPlay scene to a
  normal `UIWindowScene`.
- [`CSPortalSource.m`](../apptweak/CSPortalSource.m) and the mirror/fullscreen
  modules provide the rendering bridge.
- [`CSSceneManifestSpoof.m`](../sbtweak/CSSceneManifestSpoof.m) documents the
  required distinction between a plain CarPlay window scene and a template
  scene.

For iOS 18, instrument which object supplies the scene configuration after a
runtime-admitted declaration. Candidate observation points are the CarKit
declaration's scene/configuration properties and the CarPlay process's
application launch request. Only add a runtime CarPlay role if the original
manifest has no usable role. If a template role is left visible while the app
is bridged as a plain window, the known result is a blank screen or a scene-role
exception.

## Cache and lifecycle work

The admission hook must handle all of these transitions:

- CarPlay connection after preferences were changed
- app enable/disable without a respring
- app update/reinstall with a new container or version
- CarPlay disconnect/reconnect
- the target app already running on the phone
- Portal switching between two runtime-admitted sources

The implementation should expose one idempotent `CSRebuildRuntimeAdmission`
operation. It should invalidate only CarSurf-managed declarations, request a
CarPlay app-library refresh, and then let the normal CarKit evaluator run.
Avoid global cache flushes until the declaration producer and cache owner are
known; broad invalidation is a likely source of SpringBoard safe mode or
CarPlay restarts.

## What must not be done

- Do not re-sign or rewrite the target app as a fallback inside the runtime
  prototype.
- Do not hook `-[LSBundleProxy entitlements]` or return a fabricated
  dictionary. The existing iOS 16 crash analysis shows that callers expect
  private typed objects and can send selectors that a dictionary does not
  implement.
- Do not force `launchUsingTemplateUI = NO` for a genuinely native template
  app. YouTube Music is the existing regression example.
- Do not promote policy for an app whose declaration was never accepted.
- Do not treat a visible icon as proof of launchability. Verify a real
  CarPlay `UIWindowScene` and an interactive source process.
- Do not make the iOS 16 LaunchServices hooks run on iOS 18. The current
  version gate exists because those hooks previously caused SpringBoard safe
  mode on iOS 18.5.

## Suggested experiment sequence

1. Capture the first declaration producer backtrace with verbose logging.
2. Add read-only logging around that producer for one genuine app and one
   ordinary app.
3. Identify the smallest returned declaration/collection that can be extended
   for one allowlisted bundle.
4. Add a disabled-by-default `CARSURF_RUNTIME_ADMISSION_IOS18` flag.
5. Admit one test app without changing its files and verify that its declaration
   reaches `CRCarPlayAppPolicyEvaluator`.
6. Promote only that app's policy and verify it appears in the CarPlay app list.
7. Verify the app receives a plain CarPlay `UIWindowScene`, renders through
   `CSSceneBridge`, and survives disconnect/reconnect.
8. Add cache invalidation and preference lifecycle handling.
9. Only after the runtime path is stable, make it the iOS 18 default and leave
   the on-disk helper path as an explicitly selectable fallback for debugging.

## Success criteria

The runtime path is complete only when all of the following are true:

- the target app's on-disk bundle hash, entitlements, and signature are
  unchanged before and after admission;
- the app appears in CarPlay's app library after an allowlist change;
- `CRCarPlayAppPolicy` reports display/capable/supported for that app;
- the app launches in a real CarPlay window scene, not a template scene;
- touch, keyboard, lock-screen wake, and Portal capture remain functional;
- disable/re-enable and App Store update remove/recreate admission without
  patching the app;
- native CarPlay apps remain unaffected.
