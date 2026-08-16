# CarSurf

Run any installed iOS app on your CarPlay head unit — CarBridge's functionality,
rebuilt for the iOS 15–18 CarPlay pipeline. Targets **iOS 18.5**, arm64 + arm64e,
rootless.

The original CarBridge stopped at iOS 13 because CarPlay's UI moved out of
SpringBoard into its own process and the entitlement gate moved into
`CarPlaySupport.framework`. This is a fresh implementation against the modern
pipeline, not a port.

## What it does

- **Any app you pick appears on the CarPlay dashboard** and gets a real,
  interactive `UIWindowScene` on the car display. Touch, gestures, keyboard,
  video and modal presentation all work, because the app is running an ordinary
  second window scene and does not know the display is a car.
- **Apps that already support CarPlay show their real interface**, not the
  cut-down template UI Apple's CarPlay SDK allows them. Vietmap, YouTube Music
  and Zalo all put their full phone app on the head unit instead of a template
  list or a Siri prompt — see *How an app gets qualified*.
- **The phone keeps its own screen.** Apps that support multiple scenes run both
  at once; apps that do not (no `UIApplicationSceneManifest`) have their UI
  transplanted to the car and restored when you unplug.
- **Per-app Orientation, Layout and Scale**, over global defaults: fill the
  landscape area or use a centered 9:16 column, build the UI as an iPhone or
  iPad, and scale it between 0.5× and 2× to fit more on screen or make controls
  easier to hit while driving.
- **Nothing to do by hand.** A root daemon qualifies each app you enable, and
  re-checks after App Store updates silently strip what it added. No SSH, no
  re-running a script.
- **Refuses to break your apps.** An app carrying real Apple-issued CarPlay
  entitlements is never re-signed, and a system app with its own sandbox profile
  is refused outright — both are unrecoverable without reinstalling.

Measured working on iOS 18.5 (iPhone 11, rootless) and iOS 16.7.12 (iPhone X,
RootHide).

## How an app gets qualified

`carsurf-helperd`, a root `launchd` daemon, is the automatic path — no SSH
required. It reconciles the set of apps you've enabled in Settings against
their live on-disk state every time preferences change, at boot, and on a
manual **Patch Now** tap, and always re-verifies rather than trusting its own
past outcome (an App Store update silently re-signs a bundle and strips
whatever the daemon added, with no notification). Every attempt lands in one
of three outcomes, visible per-app in Settings:

| Outcome | What happened | CarPlay behavior |
|---|---|---|
| **Patched** | Re-signed with `SBStarkCapable`, trustcache-added | Gets a real `UIWindowScene`, its own phone UI |
| **Native (bridged)** | Already has real Apple-issued CarPlay entitlements — binary left untouched, and CarPlay is told the app has no template capability so it is bridged the same way a patched app is | Real `UIWindowScene`, its own phone UI |
| **Failed** | Refused, or a genuine attempt failed | Stays off the dashboard; reason shown in Settings |

An app already carrying real `com.apple.developer.carplay-*` entitlements is
**never** re-signed — replacing the App Store's real signature with an ad-hoc
one destroys whatever validation those entitlements depend on, permanently.
Confirmed the hard way twice: once on an app that lost its native CarPlay
entitlement (SIGKILL on every launch, phone and CarPlay alike, until
reinstalled from the App Store), and once on a system app whose dedicated
sandbox profile only grants after verifying a real Apple signature — no
re-signing tool can fake that, and there was no fix short of restoring the
bundle from the jailbreak's own system-app tooling. System apps are shown in
the picker; the daemon's dedicated-sandbox and real-signature guard still
refuses unsafe on-disk patching, while runtime admission can consider an enabled
system app without filtering it out of Settings.

An app that ships its own CarPlay interface is bridged too — that interface is
usually a cut-down version of the app, and putting the real one on the head unit
is the whole point of the tweak. What makes it work is that CarPlay is never
allowed to build a template scene for it: `CSSceneManifestSpoof.m` answers its
`com.apple.developer.carplay-*` entitlements as absent and hides its
`CPTemplateApplication*` scene roles, so CarPlay hands it a plain CarPlay window
scene. Rewriting a template scene *after* CarPlay has built one throws inside
`+[UIScene _sceneForFBSScene:create:withSession:connectionOptions:]` and kills
the app on every launch — that is what crashed Waze, and Vietmap after it, on
both iOS 16.7.12 and 18.5. The bridge now declines that rewrite and lets the app
keep its own UI for that launch instead of dying.

In Settings: **CarSurf → Apps → *pick an app*** — the same screen carries the
enable switch, qualification status, layout options, and a manual re-check
button, so enabling an app and finding out whether it actually worked is one
screen, not two.

## Build

```sh
# one-time
git clone --recursive https://github.com/theos/theos.git ~/theos
# install an SDK into ~/theos/sdks (16.5 or newer is fine)
brew install ldid dpkg

export THEOS=~/theos
make package FINALPACKAGE=1
```

### Patch an installed app over SSH

The root helper is the long-term automatic path. For testing, the repeatable
manual workflow is packaged as a script because commands launched by `sshd`
inherit the iOS app-bundle storage access needed to modify an installed app:

```sh
CS_PASSWORD='your-root-password' tools/carsurf-patch-app.sh YouTube
# A bundle identifier works too:
CS_PASSWORD='your-root-password' tools/carsurf-patch-app.sh com.google.ios.youtube
```

Set `CS_HOST` or `CS_USER` when the device is not
`root@192.168.6.34`. The script makes a timestamped, lightweight backup under
`/var/mobile/carsurf-backup/<bundle-id>/`, preserves the main executable's signing
identifier, leaves embedded frameworks and their Apple/DRM signatures untouched,
adds the main executable and existing embedded-framework cdhashes to the jailbreak
trustcache, and re-registers the app. Trusting those unchanged framework hashes is
required because dyld will not load a non-platform image into the now-platform
main process.

The script stops there, which is enough only for an app that has not been launched
yet this boot. `carsurf-helperd` additionally replaces each embedded framework with
a byte-identical copy of itself after trusting it, so the file gets a new inode and
the kernel evaluates it against the new trustcache instead of reusing the
non-platform code-signature blob it cached the first time the app mapped that
framework — see *Why a trusted framework still needs a new inode* below.

### Why a trusted framework still needs a new inode

The kernel attaches a code-signature blob to a file's vnode the first time the
file is mapped and keeps reusing it. Adding a cdhash to the trustcache afterwards
does not re-classify an image the device has already loaded, so a framework that
was mapped before its app was patched stays *non-platform* while the re-signed
main executable is now a platform binary — and dyld refuses to map it:

```
Library not loaded: @rpath/Flutter.framework/Flutter
  code signature ... not valid for use in process:
  mapping process is a platform binary, but mapped file is not
```

The app is killed at launch, on the phone as much as on CarPlay, and which
framework is blamed changes between runs depending on what is still cached. The
main executable escapes it only because `ldid` rewrites the file, which forces a
fresh evaluation. Replacing each framework with a byte-identical copy does the
same for the rest: same bytes, same cdhash, new inode.

Copying is safe even though every App Store framework is FairPlay-encrypted
(`cryptid=1`) and ships its own `SC_Info/*.sinf` sidecar — measured on iOS 18.5,
the copy decrypts and launches exactly as the original did. An earlier build
refused to touch anything carrying FairPlay metadata, which excluded every
framework in every App Store app and left the bug unfixed.

Each refresh is recorded per-cdhash in
`/var/jb/Library/CarSurf/framework-trust.plist`, so reconciling repeatedly does
not re-copy frameworks that are already trusted with the bytes they have now.

The `.deb` lands in `packages/`. It contains:

| Path | What |
|------|------|
| `Library/MobileSubstrate/DynamicLibraries/CSSystem.dylib` | SpringBoard + CarPlay.app: dashboard app list, CarKit admission policy |
| `Library/MobileSubstrate/DynamicLibraries/CSApp.dylib` | every enabled app: scene role rewriting, traits, scaling |
| `Library/PreferenceBundles/CSPrefs.bundle` | Settings pane |
| `Library/LaunchDaemons/com.pavunato.carsurf.helperd.plist` | keeps `carsurf-helperd` running as root |
| `usr/local/libexec/carsurf-helperd` | the qualification daemon — see *How an app gets qualified* above |
| `usr/local/bin/carsurf-audit` | on-device symbol audit |
| `usr/local/bin/carsurf-classes`, `carsurf-apps`, `carsurf-prefstest` | further on-device diagnostics |

## Install

```sh
scp packages/com.pavunato.carsurf_*.deb root@<device>:/tmp/
ssh root@<device> 'dpkg -i /tmp/com.pavunato.carsurf_*.deb && killall -9 SpringBoard'
```

`libSandy` is a strong recommendation, not a requirement — see *Preferences and
the sandbox* below.

Then in **Settings → CarSurf**: turn on **Enable CarSurf**, open **Apps**,
tap one app to start with, and turn on **Enable for CarPlay**. `carsurf-helperd`
reconciles automatically — watch the status line on that same screen for the
result, or tap **Patch Now** to re-check it immediately.

When a patch fails, open **View Live Patch Log** on that app's settings page.
Use **Clear Log**, reproduce with **Patch Again**, then **Share Log** to send the
diagnostic text through Messenger, Telegram, Mail, or any other iOS share target.

## Verify it works before blaming the car

Run the audit tool first. It checks, on your actual device, that every private
symbol the tweak hooks still exists on this iOS build:

```sh
ssh root@<device> carsurf-audit
```

Any line marked `[required]` and `MISSING` means bridging cannot work on that
build and the selector names need updating — the tweak skips missing hooks rather
than crashing, so a rename shows up as "nothing happens", not as a boot loop.

Then watch the hooks land. **iOS ships no `log` binary** (and in zsh `log` is a
shell built-in that silently swallows `log show ...`), so the tweak writes its own
file instead:

```sh
ssh root@<device> carsurf-logs        # print everything
ssh root@<device> carsurf-logs -c     # clear
```

Turn on **Verbose Logging** in the prefs pane for the detailed stream. A healthy
launch looks roughly like:

```
[system/CarPlay]  CarPlaySupport is now loaded — installing hooks
[entitle/CarPlay] entitlement spoof installed (conservative): 9 getters patched, 4 left alone
[applist/CarPlay] app list: 214 installed -> 7 listed (5 genuine CarPlay apps)
[app/YourApp]     bridging enabled for com.example.yourapp
[scene/YourApp]   scene bridge installed (configuration=1, role=1, multiScene=1)
[scene/YourApp]   rewriting scene role CPTemplateApplicationSceneSessionRoleApplication -> UIWindowSceneSessionRoleApplication
[scene/YourApp]   car scene connected (mode=1, scale=1.00)
```

## If the device will not boot

Injecting into SpringBoard always carries that risk. The tweak reads its kill
switch *before* installing a single hook, so:

```sh
ssh root@<device> 'touch /var/mobile/Library/Preferences/.carsurf-disable'
```

is enough to disable it entirely without uninstalling. Delete the file to
re-enable. `CS_SAFE=1` in a process's environment does the same for that one
process.

## Preferences and the sandbox

The config lives at
`/var/mobile/Library/Preferences/com.pavunato.carsurf.plist`. App sandboxes
deny that directory, so `CSApp.dylib` reads it one of two ways:

1. **libSandy** (`SystemGroupContainers` profile) — the clean path, used when
   libSandy is installed.
2. **Relay file** — SpringBoard mirrors the preferences to
   `/var/jb/Library/CarSurf/relay.plist` mode 0644 (falls back further to
   `/var/tmp/.carsurf-relay.plist` for compatibility with older installs).
   The same directory holds `carsurf-helperd`'s qualification state
   (`patched.plist`) and per-app backups, all readable from any sandbox.

If neither works, the app-side tweak sees no config, treats itself as disabled,
and installs nothing. A sandbox failure degrades to "the tweak does nothing",
never to undefined behaviour.

## Per-app options

| Option | Default | When to change it |
|--------|---------|-------------------|
| Render Scale | 1.0 | Below 1.0 fits more UI on screen; above 1.0 enlarges controls. |
| Layout | Horizontal | Choose Auto, Horizontal, or a centered 9:16 Vertical viewport; available globally and per enabled app. |
| Interface Idiom | iPhone | Leave on iPhone. Apps that switch on `traitCollection.userInterfaceIdiom` see `.carPlay` otherwise and often render nothing. |

## Known limits

- **Apps with no scene manifest** get transplant mode: the UI moves to the car
  screen and the phone goes blank until you unplug. A view controller can only
  belong to one window; duplicating the render tree would produce a picture you
  cannot touch.
- **Non-touch head units** (knob/joystick only) are not handled. The scene is a
  plain `UIWindowScene`, so it receives touches but has no UIKit focus support
  for rotary input.
- **DRM video** may refuse to render on a non-main display regardless of what the
  tweak reports; that decision is inside the media stack, not UIKit.
- **CarPlay's own template apps** are untouched — the tweak only adds scenes, it
  never removes what CarPlay already offered.
- The dashboard-widget and instrument-cluster scene roles are deliberately left
  alone. Putting a full app UI where the car expects a small widget is not an
  improvement.

## Safety and driving

Everything here renders app UI on a screen in a moving vehicle. CarPlay's app
restrictions exist for a reason. Use it parked.
