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

## OSS survey: iOS 18 versus iOS 26

The public-source search was deliberately limited to code or reverse-engineering
that names CarPlay internals, rather than generic “CarPlay entitlement” advice.
The result is a useful boundary, not a ready-made implementation:

- The well-known open-source `CarPlayEnable` project is an iOS 14-era tweak. Its
  contemporaneous documentation describes using unsupported apps through
  CarPlay, and the linked source is `EthanArbuckle/carplay-cast`; public reports
  also document that it was unstable and did not work reliably on later
  releases. See the [source announcement and iOS 14 scope](https://www.idownloadblog.com/2021/02/11/carplayenable/)
  and the [open-source repository reference](https://github.com/EthanArbuckle/carplay-cast).
- Public tweak indexes still list CarBridge as non-working on iOS 16 in some
  semi-jailbreak environments, with no iOS 18 implementation or declaration
  factory published ([example compatibility ledger](https://github.com/Loy6410/ios16-tweaks)).
  This is evidence that old tweaks are not a portable iOS 18 admission solution,
  not proof that every build fails.
- The strongest recent iOS 26 CarPlay OSS result is
  [`mib2q-carplay-rgi`](https://github.com/luka-dev/mib2q-carplay-rgi). Its iOS
  26.1 reverse engineering is about the head unit's second display (`altScreen`),
  AirPlay feature negotiation, and stream type 111. It does not add an iPhone
  application to CarKit's app roster and therefore does not replace the
  `CRCarPlayAppDeclaration` admission hook.
- A separate open-source iOS 26 toolkit advertises IPA/dylib injection, but its
  README explicitly limits built-in tweaks to iOS 18.3.2 and describes iOS 26 as
  supported only for file-manager and IPA-injector functions. It contains no
  CarPlay declaration/policy implementation. See the
  [`iDevice-Toolkit` compatibility statement](https://github.com/GeoSn0w/iDevice-Toolkit#-what-is-idevice-toolkit).

### Version conclusion

The OSS evidence does **not** show that the iOS 18 declaration-factory method is
also implemented or validated on iOS 26. What exists for iOS 26 is mostly
transport/head-unit reverse engineering or generic tweak injection. Our
`CRCarPlayAppDeclaration` + per-call `LSBundleInfoCachedValues` proxy is a
successful **research-branch experiment on iOS 18.5**, not the mechanism used by
the current dual-app build. The current build still uses the on-disk helper
patch. The next research step is therefore a version-gated observe-only probe:
resolve the declaration factory and policy evaluator on each OS, log their
class/selector/caller, and only enable the proxy on releases where the same
object contract is confirmed.

## Reality ledger: methods already tested

This table records observed results from the prior sessions. “Proven” means it
was exercised on a device and produced the stated log/result. “Research-only”
means the code and instrumentation are preserved on the separate research
branch but are not part of the current installed dual-app build.

| Method | Device / release | Result | Use for next work |
| --- | --- | --- | --- |
| LaunchServices entitlement getter spoof (`LSBundleProxy`) | RootHide iPhone X, iOS 16.7.12 | **Proven.** Runtime admission installed; helper ran relay-only with no app patch; CarPlay loaded allowlisted apps. | Keep as the iOS 16/17 path only. |
| iOS 16/17 scene-manifest and typed entitlement hooks | RootHide iPhone X, iOS 16.7.12 | **Proven with guardrails.** Typed getters and manifest masking worked. Fabricated dictionaries, broad entitlement hooks, and wrong object types previously caused safe mode/crashes. | Do not run these hooks on iOS 18. |
| iOS 18 `LSBundleProxy` admission | iOS 18.5 | **Failed / irrelevant.** CarKit did not consult this path for the initial app roster. Earlier broad versions caused SpringBoard or CarPlay instability. | Do not spend more time on this gate. |
| iOS 18 `CRCarPlayAppPolicyEvaluator` mutation | iOS 18.5, current dual-app build | **Partially proven.** Logs show policies promoted for existing declarations, including YouTube, but an ordinary app with no declaration never reaches this hook. | Retain as the final policy stage, not the admission stage. |
| iOS 18 declaration-factory + per-call `NSProxy` stand-in | iOS 18.5 FPT Play research branch | **Research-only but successful in the preserved experiment.** Factory observed in SpringBoard; 492 calls / 66 declarations; stand-in answered `SBStarkCapable` and produced a valid declaration without changing the app. | Port this exact narrow experiment into the current branch. |
| Global `LSBundleInfoCachedValues` swizzle | iOS 18.5 FPT Play research | **Failed / unsafe.** CarPlay link entered an endless “connecting” retry loop. | Never use as the implementation mechanism. |
| RootHide app-container trust-cache patch | RootHide iPhone X, iOS 16.7.12 | **Unavailable.** `jbctl trustcache add` refused app-container paths; this is why runtime admission was required for older RootHide testing. | Runtime route is mandatory where app bundles cannot be trusted. |
| On-disk re-sign/patch route | Rootless iPhone 11, iOS 18.5 | **Proven, but invasive.** Build 91 helper logs show YouTube repaired and verified; six enabled apps reconciled. It changes signatures and remains the current iOS 18 fallback. | Keep only as fallback while runtime admission is developed. |
| Rootless Portal rendering | Rootless iPhone 11, iOS 18.5 | **Proven.** Build 93 hosted YouTube and Vietmap simultaneously at approximately 296/297 px panes; close action was received. | Reuse the existing scene bridge after runtime admission. |

The practical conclusion is narrow: the only unmodified-app iOS 18 route that
has produced a declaration is the factory retry with a per-call stand-in. The
policy hook, Portal capture, and scene bridge are downstream pieces that already
work once CarKit has a declaration.

## Tested build/device checkpoints

- RootHide build 89 (`iphoneos-arm64e`) installed on iPhone X (`iPhone10,6`,
  iOS 16.7.12). Helper, Portal registration, relay updates, and runtime
  admission hooks were verified after respring.
- Rootless build 91 (`iphoneos-arm64`) installed on iPhone 11 (`iPhone12,1`,
  iOS 18.5). The launch-daemon path was corrected to `/var/jb/...`; helper
  reconciliation and Portal registration were verified after respring.
- Rootless build 93 installed on the same iPhone 11. The dedicated sidebar
  action slot was verified at both 640×360 and 640×240 CarPlay bounds, and the
  close notification closed Portal and both source processes.

These are compatibility checkpoints, not proof that iOS 18 runtime admission
works on every release. The dual-app branch still uses the on-disk helper patch;
the research branch now has the separate device result recorded below.

### Latest runtime-admission device test

After migrating this document to `research/fpt-play-runtime-admission`, the
branch was built as rootless (`iphoneos-arm64`) and installed on the configured
iPhone 11 running iOS 18.5. The FPT Play executable was inspected before the
test and contained no `SBStarkCapable` or `CARCapableApp` entitlement. After a
SpringBoard restart and the required wait, the device log recorded:

```text
enumerated enabled bundle ftel.rad.fptplay -> nil
stand-in received -boolForKey:
admission key answered via -boolForKey:
declaration built for ftel.rad.fptplay
ftel.rad.fptplay admitted at runtime — no on-disk patch required
```

The same run logged the factory hook and policy hook installed in SpringBoard,
CarPlay, and CarPlayTemplateUIHost. The helper reported `reconciled: 7 enabled
(patching is manual)`, so this test did not re-sign or trust-cache FPT Play.
This is the first current-branch device confirmation of the preserved proxy
experiment; it proves iOS 18.5 only and says nothing yet about iOS 26.

### CarPlay recovery checkpoint: do not retry the raw roster insertion

On the rootless iPhone 11 (iOS 18.5), the `0.1.4-1-14+debug` experiment added a
plain `FBSApplicationInfo` produced by
`LSApplicationProxy → initWithApplicationProxy:` directly to CarPlay's
filtered `FBSApplicationLibrary` result. That object does not implement
`-carPlayDeclaration`. CarPlay then crashed in
`-[DBApplicationController _updatePolicyForApplication:]` with:

```text
-[FBSApplicationInfo carPlayDeclaration]: unrecognized selector sent to instance
```

After downgrading to `0.1.4-1-13+debug` and running `sbreload`, CarPlay returned
normally: `CarPlay.app`, `carkitd`, `caraccessoryd`, and
`ACCCarPlayService` were all running, with no new CarPlay crash. The baseline
roster correctly logged `FBSApplicationLibrary allInstalledApplications
count=34 fpt=0`, so this package restores the connection but does not expose
FPT Play.

This is a hard negative checkpoint. Do **not** reintroduce the raw `1-14`
insertion or treat a plain `FBSApplicationInfo` as a valid CarPlay roster
entry. Any future in-memory insertion must preserve the object contract (in
particular `-carPlayDeclaration`) before returning it to CarPlay. The FPT
bundle, executable, signature, and entitlements were not modified in this
comparison.

The follow-up adapter builds are also negative checkpoints, not safe releases:

- `1-21` and `1-22` crashed while the adapter called the path-taking factory;
  CarPlay sent `boolForKey:` to a frozen entitlement dictionary.
- `1-23` preflighted the entitlement argument, but the same crash remained
  because the path-taking factory reloaded the bundle's raw Info.plist.
- `1-24` moved the failure to `objectForKey:ofClass:` on a mutable raw
  dictionary, confirming that wrapping only the externally supplied arguments
  cannot make the path-taking overload safe.
- `1-23` reached the declaration path and logged an FPT declaration, but the
  live CarPlay session hung and then hit the watchdog (`CarPlay` exited with
  signal 6). A declaration log is therefore not evidence that the roster
  object or policy update is valid.
- `1-24` was installed after that watchdog and did not produce a clean,
  independent CarPlay run; its diagnostics were still dominated by the prior
  failed session. It is not a verified candidate.
- `1-25` produced a new, definitive object-contract crash while CarPlay was
  connecting:

  ```text
  -[<object> isHidden]: unrecognized selector sent to instance
  DBIconModel isIconVisible: -> loadAllIcons -> DBDashboard handleConnect
  ```

  The dynamically subclassed `FBSApplicationInfo` supplied only
  `-carPlayDeclaration`; Dashboard also expects the full `DBApplicationInfo`
  contract (including `-isHidden`). It is therefore unsafe even when the
  declaration factory itself returns successfully. The device was restored to
  `1-13` immediately afterward.

Do not retry `1-21` through `1-25` as-is. The next experiment must avoid both
the path-taking factory's internal raw-property-list reload and a fabricated
`FBSApplicationInfo` roster object. A valid insertion must be a real
`DBApplicationInfo` (or an object with its complete private selector contract),
then be verified against a live CarPlay process before any FPT roster entry is
retained.

### First successful DBApplicationInfo admission: `1-28`

Build `0.1.4-1-28+debug` used the private Dashboard class that the live
CarPlay process already uses. It created:

```text
[[DBApplicationInfo alloc] initWithApplicationProxy:
    [LSApplicationProxy applicationProxyForIdentifier:@"ftel.rad.fptplay"]]
```

The candidate reported `class=DBApplicationInfo hidden=0 valid=1 installed=1`
and a non-nil `carPlayDeclaration`. Adding that object to the process-local
filtered library produced `34 -> 35` entries. CarPlay then requested FPT's
policy and promoted it with `display=1 capable=1 supported=1 templateUI-off=1`.
FPT Play appeared in the CarPlay app list, while the bundle remained untouched;
the source path performs no LaunchServices or app-bundle write. No new CarPlay
crash report appeared after this insertion. Launching and interacting with the
new icon is the remaining runtime check before treating this as a release.

### Accessory-daemon recovery checkpoint

After a package downgrade and `sbreload`, `carkitd` can remain healthy while
`user/501/com.apple.caraccessoryd` is stopped (`state=not running`, `runs=0`).
In that state `CarPlay.app` cannot launch, even though the tweak has not
crashed. Restarting only the accessory service with:

```text
launchctl kickstart -k user/501/com.apple.caraccessoryd
```

returned the service to `state=running`; a fresh unplug/replug handshake then
brought CarPlay back. Record this separately from CarPlay-process crashes so a
missing accessory handshake is not misattributed to the FPT admission code.

After the `1-23`/`1-24`/`1-25` comparison, the device was explicitly restored
to `0.1.4-1-13+debug`, resprung, and `caraccessoryd` was kickstarted again.
The package query confirmed `1-13`; `caraccessoryd` was `state=running`, and
the crash directory contained no report newer than the `1-25`
`CarPlay-2026-08-14-140751.ips` failure. This is the current safe checkpoint.
The package state is safe, but the CarPlay connection itself is not guaranteed
after a userspace reboot: if `caraccessoryd` returns to `state=not running`,
kickstart it and perform a fresh physical unplug/replug handshake.

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
