#!/system/bin/sh
# event_detector.sh — single-shot detection: is a registered game in foreground?
# Prints: GAME|<pkg> | IDLE | DISABLED. No loops.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
CORE_DIR="$FGC_MODDIR/core"
. "$CORE_DIR/foreground_monitor.sh"
. "$CORE_DIR/paths.sh"

fgc_detect_once() {
  case "$(cat "$FGC_CONFIG/config.json" 2>/dev/null)" in
    *'"enabled":false'*|*'"enabled": false'*) echo "DISABLED"; return 0 ;;
  esac
  _fg="$(fgc_foreground_pkg)"
  [ -z "$_fg" ] && { echo "IDLE"; return 0; }
  if grep -q "\"package\"[ ]*:[ ]*\"$_fg\"" "$FGC_CONFIG/gamelist.json" 2>/dev/null; then
    echo "GAME|$_fg"
  else
    # detection_mode=foreground treats any fullscreen app? No — only gamelist counts.
    # gamelist/hybrid/foreground all gate on gamelist membership (documented).
    echo "IDLE"
  fi
}
case "$0" in *event_detector.sh) fgc_detect_once ;; esac
