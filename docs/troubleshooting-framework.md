# CarSurf troubleshooting framework

How we debug CarSurf on a jailbroken device. This is the method that resolved the
CarPlay-host launch crash and the disable/re-enable icon flicker (2026-08-17).
Follow it in order; each step produces the evidence the next one needs. The rule
that ties it together: **capture the real failure before changing any code — never
guess, never whack-a-mole.**

## The devices and where things live

- `jailbroken-iphone-11` (192.168.6.34, iOS 18.5) and `iphone-10-roothide-16.7.12`
  (192.168.6.11) in `~/.ssh/config`. Key: `~/.ssh/carbridge_iphone`.
- Shared log: `/var/mobile/Library/Logs/carsurf.log` (SpringBoard + CarPlay UI
  processes). Sandboxed apps write `carsurf.log` inside their own container under
  `/var/mobile/Containers/Data/Application`.
- Tools are NOT on the SSH PATH — call them by full path
  `/var/jb/usr/local/bin/carsurf-*`.
- Prefs plist: `/var/mobile/Library/Preferences/com.pavunato.carsurf.plist`.
- Per-vehicle layout: `/var/mobile/Library/SpringBoard/<vehicleUUID>-CarDisplayIconState.plist`.

## 1. Capture the real failure — do not guess

The CarPlay host (`CarPlay`, `CarPlayTemplateUIHost`) exits with `SIGABRT` and
respawns faster than ReportCrash can persist an `.ips`, and iOS ships no `log`
binary — so the abort reason is unrecoverable after the fact **unless we record it
ourselves**. `sbtweak/CSCrashDiag.m` (`CSInstallCrashDiagnostics`, installed only
in the CarPlay UI processes from `CSSystem.m`) writes the uncaught-exception
name/reason/symbolicated stack and a fatal-signal backtrace **synchronously** to
`carsurf.log` before the process dies, then chains the previous handler so the
normal crash path is preserved. Keep it in the debug build as a safety net.

This is what turned "CarPlay reloads or crashes, not sure" into the exact line:
`-[DBApplication applicationIdentity]: unrecognized selector`. Read it with:

```sh
ssh jailbroken-iphone-11 'grep -an "UNCAUGHT EXCEPTION\|FATAL SIGNAL\|unrecognized selector" \
  /var/mobile/Library/Logs/carsurf.log | tail'
```

## 2. Introspect the live runtime — confirm the real API

Never assume a class's selectors or types. `carsurf-classes` (source
`tools/carsurf-classes.m`) dlopens the CarPlay/DashBoard frameworks and dumps
what is actually registered:

```sh
ssh jailbroken-iphone-11 '/var/jb/usr/local/bin/carsurf-classes --methods DBApplication'
ssh jailbroken-iphone-11 '/var/jb/usr/local/bin/carsurf-classes --methods FBSApplicationInfo'
ssh jailbroken-iphone-11 '/var/jb/usr/local/bin/carsurf-classes --grep ApplicationIdentity'
```

This proved `DBApplication` (superclass `NSObject`) implements neither
`applicationIdentity` nor the rest of the identity family — they live on its
`-info` (a `DBApplicationInfo` : `FBSApplicationInfo`). Note the boundary: a
standalone tool cannot see a category added by our injected dylib, and its class
copies are pristine — the *crash itself* is the authority on what the live process
answers.

## 3. Reproduce over SSH — no car UI needed for the toggle

- `tools/device-test.sh <bundle> <enable|disable|hide|show>` edits the prefs plist
  and posts `com.pavunato.carsurf/reload` + `.../application-library-change` via
  `carsurf-notify` (the device has no `notifyutil`/`python`). It then prints the
  recent sync lines.
- The **physical icon tap / app open on the car screen cannot be done over SSH** —
  that is the one step the tester (Tony) performs. Stage everything else first, then
  hand off just the tap.

## 4. Build → deploy → reload → verify by log delta

1. **Build** the debug package: `THEOS=~/theos make package` (no `FINALPACKAGE`).
   Theos stamps an incrementing `0.1.4-27-N+debug` so `dpkg -l` shows which build
   is on device. Match the last build's variant (debug vs release) to stay
   incremental — switching variants recompiles every subproject. Never pipe a
   build through `head` (the closed pipe kills it and looks like success).
2. **Deploy**: `scp` the deb to `/tmp`, `dpkg -i` it.
3. **Reload the injected dylib**: the new code only runs after the host process
   respawns. `killall CarPlay CarPlayTemplateUIHost` may leave `CarPlay.app`
   running (same pid) — kill it **by pid** and confirm a new pid. Watch for the
   hook-install line (e.g. `installed DBApplication -forwardingTargetForSelector:
   bridge`, `CarKit policy hook installed`) to confirm the build is live.
4. **Verify by delta**: capture `wc -l` of the log as a mark *before* the repro,
   then read only `tail -n +$MARK`. Prove the fix by the absence of the crash
   markers and the presence of the expected new lines — and by the host **not**
   respawning (stable pid).

## 5. Root-cause, not whack-a-mole

When a fix surfaces the *next* instance of the same shape (bridging
`carPlayDeclaration` → then `applicationIdentity` → then `processIdentity`), stop
and fix the **class** of bug. The thin `DBApplication` wrapper was missing the
whole `FBSApplicationInfo` family, so one `-forwardingTargetForSelector:` that
routes any unhandled selector to `-info` replaced the growing per-selector list.
Prefer a mechanism that cannot regress native behaviour: forwarding leaves
`-respondsToSelector:` at `NO`, so native feature-detection is unchanged.

Corollary — **distinguish the code paths**. The launch crash was specific to the
in-place re-enable path (`_loadApplicationWithInfo:` → `_didAddApplications:`),
which leaves a bare wrapper; a full reload rebuilds via `allInstalledApplications`
through the native pipeline that caches the launch identity, so it never crashed.
Knowing *which* path fails tells you where the fix belongs.

## 6. Reason about lifetime and supersession

State that is scheduled to reassert itself must reconcile against the *current*
config when it fires, not replay a frozen snapshot. The icon flicker was two
`CSVerifyHiddenDeltaAfterDelay` chains replaying opposite frozen deltas for 60s;
the fix prunes each reassertion against the live enabled set and stops a chain
once a newer toggle supersedes it. Ask of any retry/timer: *what cancels it, and
what does it read when it wakes up?*

## 7. Prove it on device before it reaches `helperd`

Standing rule: any patch-mechanism change is proven with `carsurf-patch-app.sh`
over SSH on a test app Tony picks, before it can reach `helperd` — because
`helperd` never backs up the executable, so a bad on-disk write means an App Store
reinstall. Runtime-admission and dashboard changes are verified live in the
CarPlay process as above; on-disk patching gets the stricter treatment.

## Quick reference

| Need | Command |
| --- | --- |
| Read the abort reason | `grep -an "UNCAUGHT EXCEPTION\|FATAL SIGNAL" carsurf.log` |
| Dump a class | `carsurf-classes --methods <Class>` |
| Toggle an app | `tools/device-test.sh <bundle> enable\|disable` |
| Collect all logs | `/var/jb/usr/local/bin/carsurf-logs` (`-c` to clear) |
| Build debug deb | `THEOS=~/theos make package` |
| Reload CarPlay | kill `CarPlay.app` by pid, confirm new pid + hook line |
