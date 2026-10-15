#!/system/bin/sh
# uninstall.sh — cleanup runtime state. USER DATA in /data/adb/fgc is
# deliberately preserved so reinstalls keep config/gamelist/lists/logs.
MODDIR=${0%/*}
rm -f "$MODDIR/state/session.lock" "$MODDIR/state/session.json" 2>/dev/null
rm -f "${FGC_DATA:-/data/adb/fgc}/state/session.lock" "${FGC_DATA:-/data/adb/fgc}/state/session.json" 2>/dev/null
exit 0
