#!/bin/sh
# carsurf-vehicle — show the CarPlay vehicle identifier(s) for quick testing.
#
#   carsurf-vehicle          per-vehicle icon-state plists, newest first
#   carsurf-vehicle -l       latest vehicle id seen in the carsurf log

DIR=/var/mobile/Library/SpringBoard
LOG=/var/mobile/Library/Logs/carsurf.log

if [ "$1" = "-l" ]; then
    grep -oE "vehicle=[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}" "$LOG" 2>/dev/null | tail -1 || echo "(no vehicle id in log)"
    exit 0
fi

echo "per-vehicle icon-state plists (newest first):"
for f in "$DIR"/*-CarDisplayIconState.plist; do
    [ -e "$f" ] || continue
    uuid=${f##*/}
    uuid=${uuid%-CarDisplayIconState.plist}
    mtime=$(date -r "$f" '+%m-%d %H:%M:%S' 2>/dev/null || echo "?")
    case "$uuid" in
        7245D718-*) label="CarPlay Simulator" ;;
        E7F18C8C-*) label="LYNK&CO (real car)" ;;
        *) label="" ;;
    esac
    printf "  %s  %s  %s\n" "$mtime" "$uuid" "$label"
done
