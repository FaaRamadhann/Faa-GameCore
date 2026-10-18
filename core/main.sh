#!/system/bin/sh
# main.sh — daemon entry. Poll loop with sleep (no busy loop). Single instance via lock dir.
# Usage: main.sh [MODDIR]
MODDIR="${1:-${0%/*}/..}"
export FGC_MODDIR="$MODDIR"
CORE_DIR="$MODDIR/core"
. "$CORE_DIR/config_manager.sh"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/event_detector.sh"
. "$CORE_DIR/session_controller.sh"
. "$CORE_DIR/paths.sh"

mkdir -p "$FGC_STATE" "$FGC_LOGS"
LOCKDIR="$FGC_STATE/daemon.lock"
fgc_daemon_alive() {
  # 0 = a live main.sh owns the lock (refuse start); 1 = stale/missing.
  # Uses /proc cmdline (universal on Android, no pgrep needed); unreadable
  # or mismatched PID is treated as STALE so a crash can never wedge startup.
  # A concurrent starter racing us may still win the mkdir below — harmless:
  # both share canonical state and the session lock serializes cleanups.
  [ -d "$LOCKDIR" ] || return 1
  _dpid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
  [ -n "$_dpid" ] || return 1
  case "$_dpid" in *[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$_dpid/cmdline" ] && tr '\0' ' ' < "/proc/$_dpid/cmdline" | grep -q 'core/main.sh'; then return 0; fi
  return 1
}
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # A starter may have created the dir and not yet written its pid. Treating
  # that window as "stale" made TWO starters both win (each rm -rf'd the other's
  # lock) and left several daemons polling the same state forever — observed
  # on-device as 5 concurrent main.sh. Wait for the pid before deciding — but a
  # pid that IS written and dead is definitively stale, so reclaim it at once.
  _try=0
  while :; do
    if fgc_daemon_alive; then
      echo "FGC already running"; exit 0
    fi
    if [ -s "$LOCKDIR/pid" ]; then _try=99; fi
    _try=$((_try+1))
    if [ "$_try" -gt 6 ]; then
      rm -rf "$LOCKDIR" 2>/dev/null
      mkdir "$LOCKDIR" 2>/dev/null && break
      echo "FGC lock busy"; exit 0
    fi
    sleep 1
  done
fi
printf '%s' "$$" > "$LOCKDIR/pid" 2>/dev/null
# Only remove the lock if it is still OURS: a daemon that exits late must not
# delete the lock a freshly started daemon already owns.
_d_cleanup() {
  [ "$(cat "$LOCKDIR/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCKDIR" 2>/dev/null
}
trap '_d_cleanup; exit 0' TERM INT

sh "$CORE_DIR/recovery.sh" >/dev/null 2>&1 || true
# capability snapshot for diagnostics + degraded-mode decision
. "$CORE_DIR/caps.sh"
FGC_CAPS_JSON="$(fgc_detect_caps 2>/dev/null)"
case "$FGC_CAPS_JSON" in
  *'"foreground":"none"'*)
    fgc_log "CORE_ERROR" "" "daemon" "no-foreground-source" "dumpsys unavailable; detection disabled" ;;
esac
fgc_log "SESSION_STARTED" "" "daemon" "core-started" ""

# FGC_MAX_ITER: lifecycle hook for automated tests (default 0 = run forever).
# Production is unaffected; tests set e.g. FGC_MAX_ITER=3 for a bounded run
# with clean lock release, proving start/stop/single-instance behavior.
_n=0
# Restart epoch: service.sh rewrites this on every "Restart core"/boot start. A
# daemon that outlived the restart (deferred signal while inside a long pm call)
# retires here instead of polling alongside the new one.
_ep="$(cat "$FGC_STATE/core.epoch" 2>/dev/null)"
if [ -z "$_ep" ]; then _ep="$$"; printf '%s' "$_ep" > "$FGC_STATE/core.epoch" 2>/dev/null; fi
while true; do
  if [ "$(cat "$FGC_STATE/core.epoch" 2>/dev/null)" != "$_ep" ]; then
    fgc_log "SESSION_ENDED" "" "daemon" "retired-superseded" ""
    break
  fi
  _int="$(fgc_cfg_get poll_interval_sec)"; [ -n "$_int" ] || _int=3
  _res="$(fgc_detect_once)"
  case "$_res" in
    # mksh portability: inside a ${...} expansion a bare '|' is PATTERN
    # ALTERNATION on Android's /system/bin/sh, so the original "#GAME|" strip
    # silently returned the WHOLE string ("GAME|com.x") and every session start
    # was rejected as unregistered — auto game detection never fired on-device.
    # Stripping "GAME" plus one separator char with ${_res#GAME?} behaves
    # identically on mksh, dash and bash.
    GAME\|*) _pkg="${_res#GAME?}"; FGC_GAME="$_pkg" fgc_session_start "$_pkg" ;;
    IDLE) fgc_session_end ;;
    DISABLED) fgc_session_end ;;
  esac
  _n=$((_n+1))
  if [ "${FGC_MAX_ITER:-0}" -gt 0 ] 2>/dev/null && [ "$_n" -ge "$FGC_MAX_ITER" ]; then break; fi
  sleep "$_int"
done
_d_cleanup
