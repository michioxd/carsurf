# CarSurf — architecture

A CarBridge-equivalent tweak: run **any** installed iOS app on the CarPlay head-unit
display, with real touch input, on **iOS 18.5** (arm64e, rootless / roothide).

CarBridge itself was written for iOS 11–13, when CarPlay UI was rendered by
SpringBoard and app hosting went through `SBAppSwitcher`-era scene plumbing. From
iOS 13.4 onward CarPlay UI lives in its **own process** (`CarPlay.app`), and from
iOS 16 the entitlement gate moved into `CarPlaySupport.framework`'s
`CARAppEntitlements`. So the original approach does not port; the mechanism below
targets the modern pipeline.

---

## 1. How CarPlay app launching works on iOS 18.x

```
 ┌─────────────────┐   1. dashboard needs an app list
 │   CarPlay.app   │──────────────────────────────────────┐
 │ (com.apple.     │                                      ▼
 │  CarPlayApp)    │                        CarPlaySupport.framework
 │                 │                        ┌───────────────────────────┐
 │  CARDashboard   │                        │ CARApplication            │
 │  icon grid      │◀───────────────────────│  +_allInstalledApps       │
 │                 │   only apps whose      │ CARAppEntitlements        │
 │                 │   entitlements are     │  audio/nav/comm/...       │
 │                 │   non-empty            └───────────────────────────┘
 │                 │
 │  2. tap icon    │
 │       │         │
 │       ▼         │   FBSSceneIdentity(role = CPTemplateApplicationScene…)
 │  request scene  │─────────────────────────────▶ SpringBoard / backboardd
 └─────────────────┘                                        │
                                                            │ 3. create scene
                                                            ▼
                                              ┌──────────────────────────┐
                                              │  target app process      │
                                              │  UIKit resolves the role │
                                              │  against its Info.plist  │
                                              │  UIApplicationSceneMani- │
                                              │  fest → UISceneConfig    │
                                              └──────────────────────────┘
```

Three independent gates block a normal app:

| # | Gate | Where | Symptom if unpatched |
|---|------|-------|----------------------|
| G1 | App has no CarPlay entitlement → excluded from the app list | `CarPlaySupport` (in `CarPlay.app`) | app never appears on the dashboard |
| G2 | Scene role `CPTemplateApplicationSceneSessionRoleApplication` has no matching `UISceneConfiguration` in the app's Info.plist | UIKit, **in the app process** | launch aborts: *"Info.plist contained no UIScene configuration dictionary"* |
| G3 | App is not designed for the head-unit's geometry / non-`main` screen | app's own layout code | black screen, zero-size views, or an "unsupported display" refusal |

## 2. The mechanism

### G1 — make every selected app look CarPlay-capable

Hook, inside `CarPlay.app` only:

- `CARAppEntitlements` boolean getters (`audio`, `navigation`, `communication`,
  `parking`, `charging`, `fueling`, `drivingTask`, `quickOrdering`, …) plus any
  aggregate (`-anyEntitlement` / `-isEmpty` / `-hasAnyEntitlement`) → report the
  app as entitled when its bundle ID is in the user's allowlist.
- `+[CARApplication _allInstalledApplications]` /
  `+_allInstalledApplicationsByBundleIdentifier` → append synthesized
  `CARApplication` objects for allowlisted apps that the original call dropped.

Because the getter names have churned across releases, the implementation does
**not** hardcode a list: it enumerates `CARAppEntitlements`' methods at runtime
and swizzles every zero-argument `BOOL`-returning getter. See
`CBEntitlementSpoof.m`. That is what makes this survive point releases.

### G2 — give the app a scene it actually has

In the **app process**, when UIKit asks the manifest for a configuration for the
CarPlay role and gets `nil`, substitute the app's *default*
`UIWindowSceneSessionRoleApplication` configuration, and force
`sceneClass = UIWindowScene`, `delegateClass =` the app's own scene delegate.

The result is a plain, fully interactive `UIWindowScene` living on the car
display — not a template scene. Touch, gestures, video, and `UIViewController`
hierarchy all work, because as far as the app knows it just got a second window
scene. This is the core trick, and it is why the tweak needs **no** per-app
patching.

`-[UIApplicationSceneManifest supportsMultipleScenes]` is also forced to `YES` so
the phone scene and car scene can coexist.

### G2b — legacy single-window apps

Apps with no `UIApplicationSceneManifest` at all run in UIKit's single-window
compatibility mode and cannot be given a second scene. For those, the tweak
falls back to **layer mirroring**: a `CALayerHost` on the car scene bound to the
`CAContext` of the app's existing key window, with touches hit-tested and
forwarded back to the source window. Independent-content mode is unavailable
here (both displays show the same thing), which matches CarBridge's own
behaviour for old apps.

### G3 — geometry and traits

On the car scene only:

- report `UIUserInterfaceIdiomPhone` (many apps bail on unknown idioms),
- clamp/scale the scene's `coordinateSpace` per the user's per-app zoom setting,
- allow the app to see the car `UIScreen` (`+[UIScreen screens]` is not filtered
  for us, but apps that compare against `+mainScreen` need the car screen to
  answer `_isMainScreen`-ish queries — handled behind a per-app flag, since
  forcing it globally breaks apps that legitimately branch on it).

## 3. Process layout

| Component | Injected into | Job |
|-----------|---------------|-----|
| `CSSystem.dylib` | `CarPlay.app`, `SpringBoard` | G1, scene-request plumbing, config broadcast |
| `CSApp.dylib` | every UIKit app (early-bails unless allowlisted **and** a car scene is connecting) | G2, G2b, G3 |
| `CSPrefs.bundle` | Settings | allowlist + per-app options |

Config lives at `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist`.
App processes are sandboxed away from it, so the app-side tweak uses **libSandy**
(`SystemGroupContainers` profile) to gain read access, falling back to a
`notify_post` + shared-`/var/tmp` handshake written 0644 by the SpringBoard side.

## 4. Safety

Injecting into `CarPlay.app` and `SpringBoard` risks a boot loop. Mitigations:

- Every hook is installed only after `objc_getClass` + `class_getInstanceMethod`
  confirm the symbol exists; a missing symbol logs and is skipped, never crashes.
- A global kill switch file `/var/mobile/Library/Preferences/.carsurf-disable`
  disables all hooks before any of them are applied. Creating it over SSH
  recovers a device without reinstalling.
- `CS_SAFE=1` in the environment does the same for a single process.

## 5. Verified on iOS 18.5 (22F76, iPhone 11, Dopamine + ElleKit)

Measured on-device, not inferred. `carsurf-audit` reproduces all of it.

### Confirmed present — gates G2 and G3 work

| Symbol | Status |
|--------|--------|
| `-[UISceneConfiguration initWithName:sessionRole:]` | present |
| `-[UISceneConfiguration setSceneClass:]` | present |
| `-[UISceneSession role]` | present |
| `CPTemplateApplicationSceneSessionRoleApplication` | present, string unchanged |
| `-[UITraitCollection userInterfaceIdiom]` | present |
| `UIUserInterfaceIdiomCarPlay` | 3 |

### Confirmed gone

`CARApplication` and `CARAppEntitlements` no longer exist. CarPlaySupport.framework
is now **entirely template rendering** — every class is `CPS*`. `UIApplicationSceneManifest`
does not exist either. Any CarBridge-era tweak targeting those is dead on arrival.

### Where gate G1 actually lives now: CarKit

```
CRCarPlayAppDeclaration     one per CarPlay-capable app; carries -bundleIdentifier,
                            -bundlePath, -supportsAudio/Maps/Messaging/...
CRCarPlayAppPolicy          the decision: -canDisplayOnCarScreen, -isCarPlayCapable,
                            -isCarPlaySupported, -launchUsingTemplateUI
CRCarPlayAppPolicyEvaluator -effectivePolicyForAppDeclaration:
                            -effectivePolicyForAppDeclaration:inVehicleWithCertificateSerial:
CRCarPlayAppDenylist
```

Both evaluator selectors are hooked successfully in **SpringBoard and CarPlay.app**,
and fire for every app CarPlay considers (~24 on this device: Maps, Music, Podcasts,
Phone, Messages, Siri, News, Books, plus `CarRadio`/`CarClimate`/`CarCamera`/
`AutoSettings`/`MediaRemoteUIService`/`CarPlayWallpaper`).

### The non-template role — the key discovery

`/Applications/CarCamera.app` Info.plist contains **only** this:

```
UIApplicationSceneManifest = {
  UISceneConfigurations = {
    UIWindowSceneSessionRoleCarPlay = ( { UISceneDelegateClassName = CarCamera.CameraSceneDelegate } );
  };
};
```

`UIWindowSceneSessionRoleCarPlay` is a plain `UIWindowScene` role for the head unit
— first-class UIKit, no template protocol. Apple's own CarCamera, CarRadio,
CarClimate and AutoSettings render real UIKit UI on the car screen this way. This is
exactly the capability CarBridge provided, and it is a supported mechanism rather
than a hack. `CSIsCarSceneRole` matches it alongside the template role.

### The remaining blocker

Promoting a policy is not enough: CarPlay only requests a policy for apps that
**already have a declaration**, and Safari never gets one. Ruled out by measurement:

- `-[CRCarPlayAppPolicyEvaluator effectivePolicyForAppDeclaration:]` — hooked, never
  called for Safari.
- `-[LSBundleProxy objectForInfoDictionaryKey:ofClass:]`, `objectsForInfoDictionaryKeys:`,
  `_infoDictionary` — hooked, never consulted for Safari's manifest.
- `-[NSBundle objectForInfoDictionaryKey:]`, `-[NSBundle infoDictionary]` — hooked,
  never consulted for Safari's manifest.
- `FBSApplicationInfo` / `FBSBundleInfo` — carry no scene-role or CarPlay properties.

So the capable-app set is **not computed in-process**. It arrives pre-filtered from
the LaunchServices database, which records scene roles at app-registration time. The
declaration backtrace agrees: CarKit's builder is called per-app from
`FrontBoardServices`' app library, with the enumeration driven by `SpringBoard`
(and `DashBoard` inside CarPlay.app).

**Next step:** find who decides the set on the SpringBoard side — dump SpringBoard's
own classes from inside the process for CarPlay-related accessors (a CLI cannot see
them), or make LaunchServices re-register the app with the CarPlay role present.

### Hard-won safety note

Hooking `-[NSBundle infoDictionary]` and asking the bundle for `-bundleIdentifier`
inside the hook is an **infinite recursion** — `bundleIdentifier` is implemented on
top of the info dictionary. It put SpringBoard into a 5-second crash loop. The
identifier must be read straight out of the raw dictionary, guarded by a
thread-local reentrancy flag. That route is now opt-in via `spoofViaNSBundle`
because the failure mode is a boot loop rather than a missing feature.

The kill switch recovered the device instantly over SSH:

```sh
touch /var/mobile/Library/Preferences/.carsurf-disable
killall -9 SpringBoard
```
