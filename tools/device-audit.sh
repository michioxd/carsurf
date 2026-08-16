#!/bin/bash
# device-audit.sh — reusable on-device audit for CarSurf.
#
#   tools/device-audit.sh [host] [--no-restart]
#
#   host          SSH alias (default: iphone-11-lan). Also in ~/.ssh/config:
#                 jailbroken-iphone-11 (192.168.6.34), iphone-10-roothide-16.7.12.
#   --no-restart  skip the leading userspace restart (default restarts).
#
# Flow: (1) reachability, (2) userspace restart for a clean baseline, then a full
# collection pass — package, injected dylibs, tools, helperd, preferences, symbol
# audit, filter list, prefs-bundle health, carsurf logs, patch log, crash reports
# and the good-state snapshots. Everything lands in a timestamped directory under
# docs/audits/ so the next run is `tools/device-audit.sh` and nothing else.

set -uo pipefail

HOST="${1:-iphone-11-lan}"
[[ "${2:-}" == "--no-restart" ]] && RESTART=0 || RESTART=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
OUT="$ROOT_DIR/docs/audits/$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/report.md"

# On-device absolute paths (rootless jailbreak: binaries live under /var/jb).
BIN=/var/jb/usr/local/bin
SSH() { ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" "$@"; }

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
die() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Append a headed section to the report.
hdr() { { echo; echo "## $1"; } >> "$REPORT"; }
code() { { echo; echo '```'; cat; echo '```'; } >> "$REPORT"; }

say "CarSurf device audit — $HOST ($STAMP)"
{ echo "# CarSurf device audit"; echo; echo "- device: \`$HOST\`"; echo "- ran: $STAMP"; } > "$REPORT"

# --- 1. reachability ---------------------------------------------------------
say "reachability"
SSH true || die "cannot reach $HOST"

# --- 2. userspace restart ----------------------------------------------------
if [[ "$RESTART" == 1 ]]; then
  say "restarting userspace (clean baseline)"
  SSH "launchctl reboot userspace 2>/dev/null || ldrestart" 2>/dev/null || true
  sleep 8
  back=0
  for _ in $(seq 1 30); do
    SSH true 2>/dev/null && { back=1; break; }
    sleep 2
  done
  [[ "$back" == 1 ]] || die "SSH did not return after userspace restart"
  say "userspace back up"
else
  say "skipping userspace restart"
fi

# --- 3. device + package -----------------------------------------------------
say "device + package"
hdr "Device"
SSH 'uname -a; echo "iOS: $(sw_vers -productVersion 2>/dev/null || sysctl -n kern.osversion)"; uptime' | code
hdr "Installed package"
SSH 'dpkg -s com.pavunato.carsurf 2>/dev/null | grep -E "^(Package|Status|Version|Installed-Size)"' | code

# --- 4. injected dylibs + filters -------------------------------------------
say "injected dylibs"
hdr "Injected dylibs"
SSH 'ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries/CSSystem.dylib /var/jb/Library/MobileSubstrate/DynamicLibraries/CSApp.dylib' | code
hdr "Injection filters (plist)"
SSH 'echo "-- CSSystem.plist --"; plutil -p /var/jb/Library/MobileSubstrate/DynamicLibraries/CSSystem.plist 2>/dev/null || cat /var/jb/Library/MobileSubstrate/DynamicLibraries/CSSystem.plist; echo "-- CSApp.plist --"; plutil -p /var/jb/Library/MobileSubstrate/DynamicLibraries/CSApp.plist 2>/dev/null || cat /var/jb/Library/MobileSubstrate/DynamicLibraries/CSApp.plist' | code

# --- 5. tools + helperd ------------------------------------------------------
say "tools + helperd"
hdr "Tools on device"
SSH "ls -la $BIN/carsurf-* 2>/dev/null" | code
hdr "helperd"
SSH 'ls -la /var/jb/usr/local/libexec/carsurf-helperd /var/jb/Library/LaunchDaemons/com.pavunato.carsurf.helperd.plist 2>/dev/null; echo "-- launchctl state --"; /var/jb/usr/bin/launchctl list 2>/dev/null | grep -i carsurf || echo "(helperd not loaded)"' | code

# --- 6. preferences ----------------------------------------------------------
say "preferences"
hdr "Preferences"
scp -q "$HOST:/var/mobile/Library/Preferences/com.pavunato.carsurf.plist" "$OUT/prefs.plist" 2>/dev/null \
  && plutil -p "$OUT/prefs.plist" | code \
  || echo "(no prefs plist — fresh install)" >> "$REPORT"

# --- 7. symbol audit ---------------------------------------------------------
say "symbol audit (carsurf-audit)"
hdr "Symbol audit"
SSH "$BIN/carsurf-audit" | code

# --- 8. filter + prefs-bundle health ----------------------------------------
say "filter list (carsurf-apps -k)"
hdr "Apps the filter keeps"
SSH "$BIN/carsurf-apps -k" | code
say "prefs-bundle health (carsurf-prefstest)"
hdr "Preferences bundle health"
SSH "$BIN/carsurf-prefstest" | code

# --- 9. logs -----------------------------------------------------------------
say "carsurf logs"
hdr "carsurf.log"
SSH "$BIN/carsurf-logs" | tee "$OUT/carsurf.log" | code
hdr "patch.log"
SSH 'cat /var/jb/Library/CarSurf/patch.log 2>/dev/null || echo "(no patch.log)"' | code

# --- 10. crash reports -------------------------------------------------------
say "crash reports"
hdr "Crash reports (last 24h, CarPlay/SpringBoard/DashBoard)"
SSH 'ls -lt /var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | head -20; echo; for f in /var/mobile/Library/Logs/CrashReporter/*.ips; do [ -f "$f" ] && find "$f" -mtime -1 2>/dev/null; done | while read f; do b=$(basename "$f"); case "$b" in CarPlay*|DashBoard*|SpringBoard*|CarPlayApp*|CarPlayTemplate*) echo "=== $b ==="; grep -m1 -E "^(Incident Identifier|CrashTime|Exception Type|Termination Reason)" "$f"; esac; done' | code

# --- 11. good-state snapshots ------------------------------------------------
say "good-state snapshots"
hdr "Good-state snapshots (/var/mobile/CarSurfGoodState)"
SSH 'ls -la /var/mobile/CarSurfGoodState/ 2>/dev/null || echo "(none)"' | code

# --- summary -----------------------------------------------------------------
say "done"
echo >> "$REPORT"
echo "---" >> "$REPORT"
echo "Report: $REPORT" >> "$REPORT"
printf '\n\033[1;32m✓ audit written to %s\033[0m\n' "$REPORT"
