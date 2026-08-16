#!/bin/bash
# device-test.sh — self-test a CarSurf toggle over SSH, without the Settings UI.
#
#   tools/device-test.sh <bundle-id> <enable|disable>     toggle the enabled flag
#   tools/device-test.sh <bundle-id> <hide|show>          toggle dashboardDisabled
#
# Edits the on-device prefs plist, posts the change notifications, then prints
# the hiddenIcons-sync lines from the carsurf log so the result is visible.

set -uo pipefail

HOST="${CARSURF_HOST:-iphone-11-lan}"
BUNDLE="${1:?usage: device-test.sh <bundle-id> <enable|disable|hide|show>}"
ACTION="${2:?usage: device-test.sh <bundle-id> <enable|disable|hide|show>}"

P=/var/mobile/Library/Preferences/com.pavunato.carsurf.plist
TMP=$(mktemp -d)
PLIST="$TMP/carsurf.plist"

scp -q "$HOST:$P" "$PLIST" || { echo "cannot read plist from $HOST" >&2; exit 1; }

python3 - "$PLIST" "$BUNDLE" "$ACTION" <<'PY'
import plistlib, sys
path, bundle, action = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as f:
    root = plistlib.load(f)
apps = root.setdefault("apps", {})
entry = apps.setdefault(bundle, {})
if action in ("enable", "disable"):
    entry["enabled"] = (action == "enable")
    if action == "enable" and isinstance(root.get("dashboardDisabled"), list):
        root["dashboardDisabled"] = [x for x in root["dashboardDisabled"] if x != bundle]
else:
    dd = root.setdefault("dashboardDisabled", [])
    if action == "hide" and bundle not in dd:
        dd.append(bundle)
    elif action == "show" and bundle in dd:
        dd.remove(bundle)
with open(path, "wb") as f:
    plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
print(f"{action} {bundle}")
PY

scp -q "$PLIST" "$HOST:$P"
ssh "$HOST" "chown mobile:mobile $P 2>/dev/null; chmod 644 $P; /var/jb/usr/local/bin/carsurf-notify com.pavunato.carsurf/reload com.pavunato.carsurf/application-library-change"

sleep 4
echo "--- recent sync activity ---"
ssh "$HOST" "grep -aE 'hiddenIcons sync|wrote new state|hiding |un-hiding|adding |no vehicle|using persisted|delta disabled' /var/mobile/Library/Logs/carsurf.log | tail -20"
rm -rf "$TMP"
