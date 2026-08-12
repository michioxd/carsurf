#!/bin/sh
# Collects CarSurf's log files. SpringBoard and CarPlay.app write to the
# shared path; sandboxed apps can only write inside their own container, so those
# have to be found.
#
#   carsurf-logs          print everything, newest last
#   carsurf-logs -c       clear all collected logs

SHARED="/var/mobile/Library/Logs/carsurf.log /var/tmp/carsurf.log /var/jb/Library/CarSurf/patch.log"
CONTAINERS="/var/mobile/Containers/Data/Application"

if [ "$1" = "-c" ]; then
    for f in $SHARED; do rm -f "$f"; done
    find "$CONTAINERS" -name carsurf.log -maxdepth 4 -delete 2>/dev/null
    echo "cleared"
    exit 0
fi

for f in $SHARED; do
    [ -f "$f" ] || continue
    echo "===== $f ====="
    cat "$f"
done

find "$CONTAINERS" -name carsurf.log -maxdepth 4 2>/dev/null | while read -r f; do
    echo "===== $f ====="
    cat "$f"
done
