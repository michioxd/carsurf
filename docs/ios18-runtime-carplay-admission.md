# iOS 18 runtime CarPlay admission

Goal: make an installed App Store app show up on CarPlay without touching its
bundle, executable, entitlements, signature, or the trustcache.

Status on iOS 18.5: **working and shipping.** It's the only admission
mechanism — `helperd` no longer patches anything on disk.

## Why iOS 18 needed a new approach

On iOS 16/17 the decision was made by LaunchServices. DashBoard asked
`LSBundleProxy` for entitlement values, so spoofing typed getters was enough.
That's what [`CSSceneManifestSpoof.m`](../sbtweak/CSSceneManifestSpoof.m)
does, and it's still the iOS <18 path.

iOS 18 moved the decision into CarKit:

1. CarKit builds a `CRCarPlayAppDeclaration` for an installed app.
2. `CRCarPlayAppPolicyEvaluator` reads that declaration.
3. `effectivePolicyForAppDeclaration:` returns a `CRCarPlayAppPolicy` with
   `canDisplayOnCarScreen`, `isCarPlayCapable`, `isCarPlaySupported`, and
   `launchUsingTemplateUI`.

CarKit stopped consulting the `LSBundleProxy` getters when building this
roster, so the old spoof does nothing on 18. The policy hook alone isn't
enough either — it can only promote a declaration that already exists, and
an ordinary app never gets one.

## How it works now

Three stages, all in [`CSCarKitPolicy.m`](../sbtweak/CSCarKitPolicy.m),
hooked in SpringBoard and the CarPlay UI processes only.

**1. Build a declaration.** Re-run the original factory
`+[CRCarPlayAppDeclaration declarationForBundleIdentifier:info:entitlements:]`,
but swap the `entitlements` argument for a per-call `NSProxy`. The proxy
forwards every selector to the real `LSBundleInfoCachedValues` and only
answers the admission key `SBStarkCapable` — a raw `BOOL` for `boolForKey:`
and `@YES` for `objectForKey:` and its typed variants. Only used when the
real factory returned `nil`, for an enabled non-native bundle.

**2. Put a real object in the roster.** The roster entry must be a genuine
`DBApplicationInfo`:

```objc
[[DBApplicationInfo alloc] initWithApplicationProxy:
    [LSApplicationProxy applicationProxyForIdentifier:bundleID]]
```

DashBoard sends it the full `FBSApplicationInfo` contract, not just
`-carPlayDeclaration`.

**3. Promote the policy.** The existing `CRCarPlayAppPolicyEvaluator` hook
sets `display / capable / supported` and turns template UI off for
phone-screen apps. Native CarPlay apps keep CarKit's own policy.

Live enable/disable on top of this is documented in
[carplay-live-icon-sync.md](carplay-live-icon-sync.md).

## Hard rules

Each of these cost a device recovery. Do not retry them.

| Don't | What happened |
| --- | --- |
| Swizzle `LSBundleInfoCachedValues` globally | CarPlay link stuck in an endless "connecting" retry loop. Use the per-call proxy. |
| Hook anything in `carkitd` | Same connecting loop. SpringBoard and the CarPlay UI processes only. |
| Insert a plain `FBSApplicationInfo` in the roster | `-[FBSApplicationInfo carPlayDeclaration]: unrecognized selector`, CarPlay crash. |
| Add only `-carPlayDeclaration` to a subclass | Next missing selector crashes instead (`-isHidden`, `-applicationIdentity`, …). Supply the whole contract. |
| Use the path-taking declaration factory overload | It reloads the bundle's raw Info.plist, so wrapping the arguments can't make it safe. |
| Hook `-[LSBundleProxy entitlements]` or return a fabricated dictionary | Callers expect private typed objects and send selectors a dictionary lacks. |
| Run the iOS 16/17 LaunchServices hooks on iOS 18 | SpringBoard safe mode. `CSUsesRuntimeCarPlayAdmission()` is the version gate — leave it alone. |
| Force `launchUsingTemplateUI = NO` on a genuinely native template app | Regression example: YouTube Music. |
| Re-sign or rewrite the app as a fallback | Defeats the whole point, and `helperd` keeps no executable backup. |
| Treat a visible icon as proof | Verify a real CarPlay `UIWindowScene` and an interactive source process. |

## Device checkpoints

| Build / device | Result |
| --- | --- |
| iPhone X, iOS 16.7.12, RootHide | LaunchServices path proven. Relay-only helper, no app patch. |
| iPhone 11, iOS 18.5, build `1-13` | Known-good baseline. Falls back to this when an experiment breaks CarPlay. |
| iPhone 11, iOS 18.5, build `1-28` | First clean `DBApplicationInfo` admission. Roster 34 → 35, policy promoted `display=1 capable=1 supported=1 templateUI-off=1`, FPT Play visible, bundle untouched, no crash. |
| iPhone 11, iOS 18.5, build `0.1.4-27` | Live enable/disable in place via `DBApplicationController`, user-verified on the CarPlay screen. |

`iPhone10,6` = iPhone X. `iPhone12,1` = iPhone 11.

Nothing here is evidence about iOS 26. Public iOS 26 CarPlay work
([mib2q-carplay-rgi](https://github.com/luka-dev/mib2q-carplay-rgi),
[iDevice-Toolkit](https://github.com/GeoSn0w/iDevice-Toolkit)) covers head-unit
transport and generic dylib injection, not app admission. The iOS 14-era
[carplay-cast](https://github.com/EthanArbuckle/carplay-cast) approach
doesn't apply either. Before enabling this on a new release, run an
observe-only probe first: log the factory and evaluator class/selector/
caller, and only turn the proxy on where the object contract matches.

## If CarPlay will not start

`carkitd` can look healthy while `caraccessoryd` is stopped, and then
`CarPlay.app` can't launch even though nothing crashed:

```sh
launchctl kickstart -k user/501/com.apple.caraccessoryd
```

Then unplug and replug. Record this separately from real crashes so a
missing accessory handshake isn't blamed on the admission code.

## Definition of done

- the app's on-disk bundle hash, entitlements, and signature are unchanged;
- it appears in CarPlay's app library after an allowlist change;
- `CRCarPlayAppPolicy` reports display/capable/supported for it;
- it launches into a real CarPlay window scene, not a template scene;
- touch, keyboard, lock-screen wake, and Portal capture work;
- disable/re-enable and App Store updates need no patching;
- native CarPlay apps are unaffected.
