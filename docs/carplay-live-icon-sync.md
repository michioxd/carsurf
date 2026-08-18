# CarPlay live enable/disable icon sync

**Working** on iOS 18.5, verified on device with the CarPlay Simulator
(2026-08-15). Toggle a CarSurf app off and its icon disappears from the
dashboard live; the app stays in Settings > Customize, moved to hidden rather
than deleted. One open issue at the bottom.

All of this is in [`sbtweak/CSCarKitPolicy.m`](../sbtweak/CSCarKitPolicy.m).

## The runtime objects

The per-vehicle layout is a **`CRSIconLayoutState`**:

- `-pages` → array of `CRSIconLayoutPage`; each `-icons` → array of
  `CRSApplicationIcon` (immutable `__NSFrozenArrayM`). Get a bundle id with
  `-bundleIdentifier` (helper: `CSIconBundleIdentifier`).
- `-hiddenIcons` → parallel array of `CRSApplicationIcon` — apps that exist
  for this vehicle but are hidden from the dashboard.
- metadata: `rows`, `columns`, `displaysOEMIcon`, `oemIconLabel`.
- rebuild: `-[CRSIconLayoutPage initWithIcons:]`,
  `-[CRSIconLayoutState initWithPages:hiddenIcons:]`.

**Settings > Customize = pages ∪ hiddenIcons.** Hiding an app moves it from a
page into `hiddenIcons`; it stays in Customize.

## The hooks

The live reader/writer is **`CRSIconLayoutService`** — not the controller:

- `-fetchIconStateForVehicleID:completion:` returns the current state.
- `-setIconState:forVehicleID:` writes a new one — what native Customize
  calls, and it updates the dashboard live.
- `vehicleID` is a per-vehicle UUID string (Simulator `7245D718-…`, the
  LYNK&CO car `E7F18C8C-…`). State persists to
  `/var/mobile/Library/SpringBoard/<vehicleUUID>-CarDisplayIconState.plist`.

`CSInstallIconLayoutStateHooks` swizzles `initWithDelegate:`, the connection
add/remove callbacks, `setIconState:forVehicleID:`, and
`fetchIconStateForVehicleID:completion:`. The setState and fetch hooks
capture `gLastIconLayoutService` and `gLastIconLayoutVehicleID` so the sync
knows which service and vehicle to address.

> **Dead end, do not repeat:**
> `-[CRSIconLayoutController setIconOrder:hiddenIcons:forVehicleID:]` is not
> the live path — in the CarPlay UI process the controller list is empty, so
> an earlier controller-targeted version computed the right delta and wrote
> nothing ("no icon-layout service tracked").

## The flow

On each toggle, `CSPrefsStore` posts `com.pavunato.carsurf/reload` and
`.../application-library-change`. `CSInstallCarPlayApplicationLibraryRefresh`
observes them and, after a 0.25s settle, runs `CSApplyHiddenIconsDelta`:

1. Compute the delta: `disabled = previous − current`,
   `enabled = current − previous`.
2. Find the live service (`gIconLayoutServices` / `gLastIconLayoutService`)
   and vehicle id (`CSIconLayoutVehicleIdentifiers(service)`, else
   `gLastIconLayoutVehicleID`, else `gLastVehicleIdentifier`).
3. `CSApplyHiddenDeltaToService` fetches the state and `CSStateWithHiddenDelta`
   rebuilds it **object-preserving**: it MOVES the one app's existing
   `CRSApplicationIcon` between its page and `hiddenIcons`, carrying every
   other icon object and all metadata across unchanged. Then writes with
   `setIconState:forVehicleID:`.

**Object-preserving matters.** The old `CSFilterIconLayoutState` rebuilt
pages from a derived bundle-id list and dropped any icon it couldn't account
for — including system icons like `com.apple.cardisplay.OEM` — which emptied
Customize and broke connects.

Verified write (disable `vn.vietmap.live`, Simulator vehicle `7245D718`):
fetched 14 icons, wrote `pages[0]` = 13 with every system icon kept plus
`hiddenIcons = [vn.vietmap.live]`. Persisted correctly, no crash, icon
disappeared live.

## Driving a toggle over SSH

The device has no `notifyutil` or `python`. `CSConfig.loadRoot` reads the
plist directly, so:

1. Edit `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist` on the
   Mac (`python3 plistlib`, flip `apps.<bundle>.enabled`) and scp it back.
2. Post both notifications with `carsurf-notify` (source `tools/np.m`):
   `application-library-change` first, then `reload`.
3. Read the `hiddenIcons sync` and `SHAPE setState.state` lines in the log
   (verbose must be on).

`tools/device-test.sh` does all three.

## Safeguards

- **DashBoard's transient empty write.** DashBoard itself can `setIconState`
  an empty `pages[0]` at startup. The call still goes through the native
  writer, but the payload is replaced with that vehicle's last non-empty
  state (remembered from both setState and fetchState). Dropping the write
  instead was the earlier desynchronization/PAC path. An empty fetch is
  served from the same last-good state.
- **DashBoard reconciling a write back.** If a successful hidden-icons write
  gets reverted to all-visible, CarSurf re-applies the same object-preserving
  move at 2s, 10s, 30s, and 60s. Each reassertion is pruned against the live
  enabled set at fire time and the chain stops once a newer toggle supersedes
  it — without that, two chains replay opposite frozen deltas and the icon
  flickers for a minute. It never invalidates the application library or
  forces a reload.

## Known issue

The `fetchIconStateForVehicleID:completion:` interception is **disabled** in
the safe connected-device build. Re-enabling it reproduced a native CarPlay
`SIGSEGV` in `DBIconLayoutVehicleDataProvider`. Consequence: Customize shows
only the native icon-state entries, while runtime-admitted CarSurf apps still
appear on the dashboard. A read path that doesn't reconstruct the fetched
state is needed.

Final visual behaviour still wants a connected-vehicle run. The last toggle
test session reported no active icon-layout service, so it verified
notification delivery and roster sync but not the Customize fetch/write
callbacks.
