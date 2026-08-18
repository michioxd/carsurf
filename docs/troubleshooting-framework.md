# How to debug CarSurf

The method that found the CarPlay host launch crash and the icon flicker
(2026-08-17). Do the steps in order — each one produces the evidence the next
needs. The rule underneath all of it: **capture the real failure before changing
any code.** No guessing, no whack-a-mole.

## Where things live

| What | Where |
| --- | --- |
| Devices | `iphone-11` (192.168.6.34, iOS 18.5) and `iphone-10` (192.168.6.11) in `~/.ssh/config`. Key `~/.ssh/carbridge_iphone`. |
| Shared log | `/var/jb/Library/CarSurf/carsurf.log`, then `/var/mobile/Library/Logs/carsurf.log`, then `/var/tmp/carsurf.log` — first writable one wins (`shared/CSLog.m`). |
| Sandboxed app logs | `carsurf.log` inside the app's own container under `/var/mobile/Containers/Data/Application`. `carsurf-logs` collects these too. |
| Prefs | `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist` |
| Per-vehicle layout | `/var/mobile/Library/SpringBoard/<vehicleUUID>-CarDisplayIconState.plist` |

Tools are **not** on the SSH PATH. Call them by full path:
`/var/jb/usr/local/bin/carsurf-*`.

The `iphone-10-roothide-16.7.12` host name is stale — that device was
re-jailbroken rootless on 2026-08-17.

## 1. Capture the real failure

The CarPlay host (`CarPlay`, `CarPlayTemplateUIHost`) exits with `SIGABRT` and
respawns faster than ReportCrash can write an `.ips`, and iOS ships no `log`
binary. So the abort reason is gone afterwards **unless we record it ourselves.**

`sbtweak/CSCrashDiag.m` (`CSInstallCrashDiagnostics`, installed only in the
CarPlay UI processes from `CSSystem.m`) writes the uncaught-exception
name/reason/symbolicated stack and a fatal-signal backtrace **synchronously**
before the process dies, then chains the previous handler so the normal crash
path still runs. Keep it in debug builds.

This is what turned "CarPlay crashes, not sure why" into
`-[DBApplication applicationIdentity]: unrecognized selector`:

```sh
ssh iphone-11 'grep -an "UNCAUGHT EXCEPTION\|FATAL SIGNAL\|unrecognized selector" \
  /var/jb/Library/CarSurf/carsurf.log | tail'
```

## 2. Confirm the real API — never assume a selector

`carsurf-classes` (source `tools/carsurf-classes.m`) dlopens the CarPlay and
DashBoard frameworks and dumps what is actually registered:

```sh
ssh iphone-11 '/var/jb/usr/local/bin/carsurf-classes --methods DBApplication'
ssh iphone-11 '/var/jb/usr/local/bin/carsurf-classes --grep ApplicationIdentity'
```

That proved `DBApplication` implements neither `applicationIdentity` nor the rest
of the identity family — they live on its `-info` (a `DBApplicationInfo` :
`FBSApplicationInfo`).

Limit: a standalone tool cannot see a category added by our injected dylib, and
its class copies are pristine. **The crash itself is the authority** on what the
live process answers.

## 3. Reproduce over SSH

`tools/device-test.sh <bundle> <enable|disable|hide|show>` edits the prefs plist
and posts `com.pavunato.carsurf/reload` + `.../application-library-change` via
`carsurf-notify` (the device has no `notifyutil` or `python`). It then prints the
recent sync lines.

The **physical icon tap on the car screen cannot be done over SSH.** That is the
one step Tony performs. Stage everything else first, then hand off just the tap.

## 4. Build → deploy → reload → verify by delta

1. **Build**: `THEOS=~/theos make package` (no `FINALPACKAGE`). Theos stamps an
   incrementing `0.1.4-27-N+debug`, so `dpkg -l` shows what is on device. Match
   the previous build's variant (debug vs release) — switching recompiles every
   subproject. Never pipe a build through `head`; the closed pipe kills it and
   looks like success.
2. **Deploy**: `scp` the deb to `/tmp`, then `dpkg -i`.
3. **Reload**: new code only runs after the host respawns. `killall CarPlay
   CarPlayTemplateUIHost` may leave `CarPlay.app` on the same pid — kill it **by
   pid** and confirm a new one. Watch for the hook-install line (e.g. `installed
   DBApplication -forwardingTargetForSelector: bridge`) to confirm the build is
   live.
4. **Verify**: take `wc -l` of the log as a mark *before* the repro, then read
   only `tail -n +$MARK`. Prove the fix by the crash markers being absent, the
   new lines being present, and the host **not** respawning (stable pid).

## 5. Fix the class of bug, not the instance

When a fix surfaces the next instance of the same shape (`carPlayDeclaration`,
then `applicationIdentity`, then `processIdentity`), stop and fix the class. The
thin `DBApplication` wrapper was missing the whole `FBSApplicationInfo` family,
so one `-forwardingTargetForSelector:` routing unhandled selectors to `-info`
replaced a growing per-selector list. It also cannot regress native behaviour:
forwarding leaves `-respondsToSelector:` at `NO`.

**Also: work out which code path fails.** The launch crash only hit the in-place
re-enable path (`_loadApplicationWithInfo:` → `_didAddApplications:`), which
leaves a bare wrapper. A full reload rebuilds through `allInstalledApplications`,
which caches the launch identity, so it never crashed. Knowing which path fails
tells you where the fix belongs.

## 6. Ask what cancels a timer, and what it reads when it fires

Anything scheduled to reassert itself must reconcile against the **current**
config when it fires, not replay a frozen snapshot. The icon flicker was two
`CSVerifyHiddenDeltaAfterDelay` chains replaying opposite frozen deltas for 60s.
The fix prunes each reassertion against the live enabled set and stops a chain
once a newer toggle supersedes it.

## 7. Prove on-disk writes on device first

Standing rule: any change to a patch mechanism is proven with
`tools/carsurf-patch-app.sh` over SSH, on a test app Tony picks, before it can
reach `helperd`. `helperd` never backs up the executable, so a bad on-disk write
means an App Store reinstall.

`helperd` no longer patches anything, so this currently applies only to manual
experiments — but the rule stands if on-disk writing ever comes back.

## Quick reference

| Need | Command |
| --- | --- |
| Read the abort reason | `grep -an "UNCAUGHT EXCEPTION\|FATAL SIGNAL" carsurf.log` |
| Dump a class | `carsurf-classes --methods <Class>` |
| Toggle an app | `tools/device-test.sh <bundle> enable\|disable` |
| Collect all logs | `/var/jb/usr/local/bin/carsurf-logs` (`-c` clears) |
| Build a debug deb | `THEOS=~/theos make package` |
| Reload CarPlay | kill `CarPlay.app` by pid, confirm new pid + hook line |
