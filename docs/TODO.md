# CarSurf — TODO

`[ ]` open, `[x]` done — kept for the reasoning.

## Open

- [ ] **Customize list omits CarSurf apps.** The CRS fetch wrapper is off (it
  crashed native CarPlay — see below), so Settings > Customize shows only the
  12 Apple icons; apps still show on the dashboard. Needs a list update that
  preserves the fetched objects instead of rebuilding them.
- [ ] **First scene after re-enable ignores the display setting — parked, not
  reproducible (2026-08-17).** Re-enable an app and its CarPlay scene comes up
  with default geometry instead of the configured interface/aspect. Closing
  and reopening, or reconnecting CarPlay, fixes it.
  - Geometry is applied once, in `CSCarSceneConnected` → `CSApplyScaleToCarScene`
    on `UISceneDidActivateNotification`, guarded by a `seen` set keyed on
    `scene.session.persistentIdentifier` (`apptweak/CSSceneBridge.m` ~L365). A
    scene that activates before `coordinateSpace.bounds` is final gets measured
    once and never re-measured — likely cause.
  - Options are read fresh per connect (`optionsForBundle:` L328), but idiom is
    cached per-process by `dispatch_once` in `CSTraits`; queried too early, the
    whole process builds phone-idiom UI.
  - Fix ideas: re-apply geometry on a later signal (`didUpdateCoordinateSpace`,
    first layout pass, or a one-shot next-runloop retry); stop caching the idiom
    for the process lifetime.
  - Runtime-admitted Apple apps are sandboxed and can't write the shared log —
    their `scene`/`traits` lines land in the app container's `tmp/carsurf.log`.
- [ ] **`multiScene=0`** — `UIApplicationSceneManifest` is missing on iOS 18.5,
  so multi-scene hooks never install. Only single-scene bridging works.
- [ ] **Dashboard refresh storm** — old `refresh → invalidation → relay updated`
  oscillation. Invalidation is gone from the toggle path; re-check.
- [ ] **README install glob** still lands on the stale `0.2.0-1-93` package.
- [ ] **PAC crash** — improved but unconfirmed. Synthetic roster entries are
  pinned alive (`gPinnedRosterInfos`), and the in-place path pins the
  `DBApplicationInfo`/`DBApplication` it loads. Clean in Simulator toggling;
  still needs a connected-car run.

## Done — keep the reasoning

- [x] **On-disk patching removed from `helperd` (0.1.4-27-19).** Runtime
  admission covers every supported release, so the daemon no longer patches,
  re-signs, trustcaches, backs up, or reverts anything. `carsurf-helperd.m`
  went 988 → ~127 lines, now just the preferences relay. The per-app "Patch
  Now" UI and the `ldid`/`uikittools` Depends are gone.
  `CSUsesRuntimeCarPlayAdmission()` is unchanged — it still selects the
  per-release admission hook, and the full `CSInstallSceneManifestSpoof` would
  crash-loop SpringBoard on 18.5. Bundles patched by older builds are left
  alone; there's no automatic revert.
- [x] **Live enable/disable without a reload (0.1.4-27).** Toggling mutates
  `DBApplicationController` in place (`_loadApplicationWithInfo:` /
  `_removeApplicationWithBundleIdentifier:`) and fires `_didAddApplications:` /
  `_didRemoveApplications:`. The grid re-renders live — no
  `FBSApplicationLibrary` invalidation, reflow, or re-sort. Whole-library
  invalidation is now only for a genuine uninstall. User-verified: 15 in-place
  events, 0 crashes, CarPlay on one pid throughout.
- [x] **Enabled-app launch crash (0.1.4-27-17).** Toggling an app off→on then
  launching it aborted the CarPlay host. Cause: the in-place re-enable path
  leaves the icon backed by a thin `DBApplication` wrapper exposing only
  `-info`/`-bundleIdentifier`/`-appPolicy`, while DashBoard sends it the whole
  `FBSApplicationInfo` identity family (`applicationIdentity`,
  `processIdentity`, `signerIdentity`, `carPlayDeclaration`) — all living on
  `-info`. A full reload never crashed because native startup caches the
  launch identity. Fix: one `-forwardingTargetForSelector:` on `DBApplication`
  forwards anything the wrapper lacks to `-info`, leaving
  `-respondsToSelector:` at `NO` so native feature-detection is unchanged.
- [x] **Icon flicker on re-enable (0.1.4-27-18).** After re-enabling, the icon
  flickered for ~1 minute: disable and re-enable each started a
  `CSVerifyHiddenDeltaAfterDelay` chain carrying a *frozen* delta, and they
  replayed opposite states against each other. Fix: each reassertion prunes
  its delta against the live enabled set at fire time and stops once a newer
  toggle supersedes it. The retry chain itself stays — DashBoard reconciles
  hidden writes back to all-visible on reconnect.
- [x] **CRS fetch interception crash.** Launchd recorded `CarPlayApp`
  `SIGSEGV` in the native `DBIconLayoutVehicleDataProvider
  getIconStateWithCompletion:` path while the CRS fetch wrapper was installed.
  Keep the fetch hook off until a read path that doesn't reconstruct state is
  designed.
- [x] **Customize empty on relaunch.** DashBoard's own `setIconState` can
  write an empty `pages[0]` at startup. CarSurf now restores that vehicle's
  persisted `*-CarDisplayIconState.plist` into native CRS icon objects when a
  fresh process has no snapshot.
- [x] **Config-to-scene reactivity.** The app-side CarPlay gate reads the
  current allowlist instead of its launch-time value, and a live CarPlay
  scene exits when the global or per-app toggle goes off. Phone-only app
  processes aren't killed. Teardown timing still wants one check on a
  connected vehicle.

## North star — reached

Runtime admission only. No on-disk app mutation, no trustcache, no per-app
dylib. The version that survives App Store updates.
