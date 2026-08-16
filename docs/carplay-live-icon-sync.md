# CarPlay live enable/disable icon sync — how it works

Status: **live enable/disable sync WORKING** on iOS 18.5 (verified on device with
the CarPlay Simulator, 2026-08-15). Toggling a CarSurf app off makes its icon
disappear from the CarPlay dashboard live, and the app stays in the Settings >
Customize list (moved to hidden, not deleted). One open item remains — see
"Known issue" at the bottom.

All of this lives in [`sbtweak/CSCarKitPolicy.m`](../sbtweak/CSCarKitPolicy.m).

## The runtime contract (iOS 18.5, confirmed from device logs)

The per-vehicle CarPlay layout is a **`CRSIconLayoutState`**:

- `-pages` → array of **`CRSIconLayoutPage`**; each `-icons` → array of
  **`CRSApplicationIcon`** objects (a page's icons array is an immutable
  `__NSFrozenArrayM`). Resolve a bundle id from a `CRSApplicationIcon` with
  `-bundleIdentifier` (our `CSIconBundleIdentifier` helper).
- `-hiddenIcons` → parallel array of `CRSApplicationIcon` objects (the apps that
  exist for this vehicle but are hidden from the dashboard).
- metadata getters/setters: `rows`/`columns`/`displaysOEMIcon`/`oemIconLabel`.
- Rebuild helpers: `-[CRSIconLayoutPage initWithIcons:]`,
  `-[CRSIconLayoutState initWithPages:hiddenIcons:]`.

The **Settings > Customize list = visible icons (pages) ∪ hiddenIcons**. Hiding
an app means moving it from a page into `hiddenIcons`; it stays in Customize.

### The hooks that matter

The live writer/reader is the **`CRSIconLayoutService`** (NOT the controller):

- `-[CRSIconLayoutService fetchIconStateForVehicleID:completion:]` — returns the
  current `CRSIconLayoutState`.
- `-[CRSIconLayoutService setIconState:forVehicleID:]` — writes a new
  `CRSIconLayoutState`; this is what the native Customize UI calls, and it
  updates the dashboard **live**.
- `vehicleID` is a per-vehicle **UUID string** (e.g. the CarPlay Simulator is
  `7245D718-...`; the real LYNK&CO car is `E7F18C8C-...`). The state persists to
  `/var/mobile/Library/SpringBoard/<vehicleUUID>-CarDisplayIconState.plist`.

We swizzle `initWithDelegate:`, the connection add/remove callbacks,
`setIconState:forVehicleID:`, and `fetchIconStateForVehicleID:completion:` on
`CRSIconLayoutService` (see `CSInstallIconLayoutStateHooks`). From the setState /
fetch hooks we capture `gLastIconLayoutService` and **`gLastIconLayoutVehicleID`**
so the sync knows which service + vehicle to address.

> **Dead end (do not repeat):** `-[CRSIconLayoutController setIconOrder:hiddenIcons:forVehicleID:]`
> is NOT the live path — in the CarPlay UI process the controller list is empty,
> so an earlier controller-targeted version computed the right delta but never
> wrote anything ("no icon-layout service tracked" / "no vehicle identifier").

## The mechanism

On each enable/disable, `CSPrefsStore` posts the Darwin notifications
`com.pavunato.carsurf/reload` and `.../application-library-change`.
`CSInstallCarPlayApplicationLibraryRefresh` observes them and, after a 0.25 s
settle, runs `CSApplyHiddenIconsDelta(previous)` (alongside the existing roster
invalidation). Flow:

1. `CSApplyHiddenIconsDelta` computes the delta from the previous enabled set vs
   the current one: `disabled = previous − current`, `enabled = current − previous`.
2. It finds the live service (`gIconLayoutServices` / `gLastIconLayoutService`)
   and the vehicle id (`CSIconLayoutVehicleIdentifiers(service)`, else
   `gLastIconLayoutVehicleID`, else `gLastVehicleIdentifier`).
3. `CSApplyHiddenDeltaToService` fetches the current state, then
   `CSStateWithHiddenDelta` rebuilds it **object-preserving**: it MOVES the one
   app's existing `CRSApplicationIcon` object between its page and `hiddenIcons`,
   carrying every other icon object (system icons included) and the metadata
   across unchanged. It writes the result with `setIconState:forVehicleID:`.

**Why object-preserving matters:** the old `CSFilterIconLayoutState` rebuilt
pages from a *derived* bundle-id list and dropped any icon it could not account
for (system icons like `com.apple.cardisplay.OEM`), which emptied Customize and
broke connects. Keeping the real icon OBJECTS and only moving one avoids that.

Verified write (disable `vn.vietmap.live`, simulator vehicle 7245D718): fetched
14 icons → wrote pages[0]=13 (vietmap removed, all system icons kept) +
`hiddenIcons=[vn.vietmap.live]`; persisted correctly; no crash; icon disappeared
live on the dashboard.

## How to drive/verify a toggle over SSH (no car UI needed)

The device has no `notifyutil`/`python`. `CSConfig.loadRoot` reads the plist file
directly (`dictionaryWithContentsOfFile:`), so:

1. Edit `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist` (on the Mac
   with `python3 plistlib`, flipping `apps.<bundle>.enabled`) and scp it back.
2. Post the notifications with a tiny signed poster (`np.c`: `notify_post(argv[1])`,
   built with `xcrun -sdk iphoneos clang -arch arm64`, `ldid -S`, deployed to
   `/tmp/np`): `/tmp/np com.pavunato.carsurf/application-library-change` then
   `/tmp/np com.pavunato.carsurf/reload`.
3. Read `hiddenIcons sync` + `SHAPE setState.state` lines in
   `/var/mobile/Library/Logs/carsurf.log` (verbose must be on).

## Current safeguards and verification boundary

The two observed failure modes now have bounded safeguards:

- DashBoard's transient empty `setIconState` is still passed through untouched,
  but the last non-empty state is remembered per vehicle from both `setState`
  and `fetchState`. If the following fetch is the connect-time empty state,
  CarSurf serves that vehicle's last-good state read-side, without changing the
  writer or desynchronizing DashBoard.
- If DashBoard later reconciles a successful hidden-icons write back to
  all-visible, CarSurf re-fetches and re-applies the same object-preserving move
  at 2s, 10s, 30s, and 60s. It does not invalidate the application library or
  force a screen reload.

The final visual behavior still needs confirmation on a connected vehicle. The
iPhone 11 simulator/device session used for the latest toggle test reported no
active icon-layout service, so it can verify notification delivery and roster
sync but cannot exercise the Customize fetch/write callbacks.
