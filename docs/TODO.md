# CarSurf — TODO

Open items, newest and most urgent first. Sources: roadmap "Way out", memory notes, and the 2026-08-16 device audit.

## Fixed (2026-08-16, build 0.1.4-27) — user-verified on the CarPlay screen

- **Fresh-enable live-sync without the reload.** Enable/disable now mutates `DBApplicationController` in place (`_loadApplicationWithInfo:` / `_removeApplicationWithBundleIdentifier:`) and fires `_didAddApplications:` / `_didRemoveApplications:` — the grid re-renders live with **no** `FBSApplicationLibrary` invalidation, **no** screen reflow, **no** alphabetical re-sort. Verified on the Simulator (7245D718) and confirmed on-screen by the user via UI toggles after a userspace restart: 15 in-place events, 0 `unrecognized selector` / `EXC_BAD_ACCESS` / PAC, CarPlay on one pid throughout.
- **The `carPlayDeclaration` crash.** `_updatePolicyForApplication:` sends `carPlayDeclaration` to the `DBApplication`, which does not implement it (only its `-info`, a `DBApplicationInfo`, does). A guarded `class_addMethod` bridge forwards it to `-[DBApplicationInfo carPlayDeclaration]` — the declaration the runtime-admission factory built. The `class_getInstanceMethod` guard keeps native behavior if the system ever provides it. (Deliberate, documented exception to CSRuntime's "never class_addMethod" rule: the framework sends this selector and crashes when it is absent.)
- **The roster-rebuild reload is retired for toggles.** `CSDeltaNeedsRosterRebuild` removed; whole-library invalidation now only happens on genuine uninstall.
- **Config-to-scene reactivity audit.** The app-side CarPlay gate now reads the current allowlist instead of caching its launch-time value, and a live CarPlay scene exits when the global or per-app toggle is turned off. Phone-only app processes are not terminated. Still verify the teardown timing once on a connected vehicle.

## Crashes (top priority)

- [ ] **PAC crash — improved, pending a connected-car test.** Synthetic roster entries are pinned alive (`gPinnedRosterInfos`), and the in-place path pins the `DBApplicationInfo` + `DBApplication` it loads. No crash in Simulator toggle testing. Still needs a LYNK&CO connected-car run to confirm.
- [ ] **CRS fetch interception crash — reproduced on the CarPlay Simulator.** Launchd recorded `CarPlayApp` `SIGSEGV` in the native `DBIconLayoutVehicleDataProvider getIconStateWithCompletion:` path while the CRS fetch wrapper was installed. Disabling that wrapper stopped the startup/Customize crash; keep the fetch hook off until a non-reconstructing read path is designed.
- [ ] **Enabled-app launch crash — newly observed.** With roster admission restored, launching enabled `com.apple.stocks` correlated with `CarPlayApp` `SIGABRT` and a respawn, while the Stocks process remained alive. Treat this as a separate app-launch/CarPlay-host admission issue.
- [x] **Customize-empty-on-relaunch** — DashBoard's *own* `setIconState` can write an empty `pages[0]` during startup. CarSurf now restores the same vehicle's persisted `*-CarDisplayIconState.plist` into native CRS icon objects when a fresh process has no in-memory snapshot, then keeps the native writer call coherent. The previous in-memory last-good fallback remains for later transient empties.

## Live sync (the core feature)

- [x] **Customize-entry reload path** — toggle refreshes remain in-place (`DBApplicationController` notifications); icon-layout initialization/reconcile no longer performs a forced reset/invalidation. Customize entry no longer receives the fresh-process empty layout: the persisted-layout restoration is applied before the native write. Final visual behavior is being checked on the connected simulator.
- [ ] **Customize list omits CarSurf-enabled apps in safe mode.** With the CRS fetch wrapper disabled to stop the crash, native Customize returns only the 12 Apple icons; roster admission makes the apps visible on the dashboard but does not populate this CRS list. Needs a safe object-preserving list update without reconstructing fetch results.
- [ ] **First toggle right after connect — likely fixed, verify.** The in-place add/remove goes through `DBApplicationController` (no vehicle ID needed), so the old vehicle-ID timing gap (Way out #3) should no longer drop the first toggle. Confirm on a fresh Simulator connect. (The hiddenIcons sync path still needs the vehicle ID, so the gap remains for hide/unhide.)
- [x] **DashBoard hidden-state reconciliation** — hidden-state changes are reasserted with bounded delays (2s/10s/30s/60s) using the object-preserving state move, without a full screen reload. Verify persistence beyond the retry window on a connected vehicle.
- [ ] **Dashboard refresh storm** — `refresh notification → reload invalidation → relay updated` oscillation. The invalidation is gone from the toggle path; re-check.
- [ ] **com.apple.camera spurious remove** seen once at 16:12:02 — baseline diff produced a remove for an app not in the enabled set. Watch.

## Scene bridge

- [ ] **`multiScene=0`** — `UIApplicationSceneManifest` is missing on iOS 18.5, so the multi-scene hooks never install; only single-scene bridging works.

## Tooling / hygiene

- [ ] **helperd never backs up the executable** — only Info.plist + entitlements; a damaged binary means App Store reinstall (Way out #4).
- [ ] **README install glob** still lands on stale `0.2.0-1-93` (Way out #5).

## North star (unchanged)

Runtime admission only — no on-disk app mutation, no trustcache, no per-app dylib. The version that survives App Store updates. The on-disk and runtime paths coexist until runtime covers every app.
