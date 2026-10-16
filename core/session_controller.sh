#!/system/bin/sh
# session_controller.sh — start/end game sessions with lock file. Single cleanup per session.
FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
CORE_DIR="$FGC_MODDIR/core"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/policy_engine.sh"
. "$CORE_DIR/process_manager.sh"
. "$CORE_DIR/config_manager.sh"
. "$CORE_DIR/device.sh"
. "$CORE_DIR/paths.sh"

LOCK="$FGC_STATE/session.lock"

fgc_profile_for() {
  # $1 = game pkg. Per-game profile overrides default; 0/empty = default.
  # Auto(4) resolves by BATTERY level (user rule): 1-20 -> Balance(1),
  # 21-50 -> Performance(2), 51-100 -> Awaken(3). Unknown battery -> Balance.
  _g="$1"
  _prof="$(grep -o "\"package\"[ ]*:[ ]*\"$_g\"[^}]*\"profile\"[ ]*:[ ]*[0-9]" "$FGC_CONFIG/gamelist.json" 2>/dev/null | grep -o '[0-9]$' | head -n1)"
  [ -z "$_prof" ] || [ "$_prof" = "0" ] && _prof="$(fgc_cfg_get default_profile 2>/dev/null || echo 1)"
  if [ "$_prof" = "4" ]; then
    _batt="$(fgc_battery_pct 2>/dev/null)"
    if [ -z "$_batt" ]; then echo 1
    elif [ "$_batt" -le 20 ]; then echo 1
    elif [ "$_batt" -le 50 ]; then echo 2
    else echo 3; fi
  else echo "$_prof"; fi
}

fgc_session_start() {
  # $1 = game pkg. No-op if lock exists (no repeated cleanup).
  _g="$1"; [ -n "$_g" ] || return 1
  mkdir -p "$FGC_STATE"
  if [ -f "$LOCK" ]; then
    _cur="$(cat "$LOCK" 2>/dev/null)"
    if [ "$_cur" = "$_g" ]; then return 0; fi
    fgc_session_end >/dev/null 2>&1
  fi
  printf '%s' "$_g" > "$LOCK"
  _prof="$(fgc_profile_for "$_g")"
  _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  fgc_state_write "{\"game\":\"$_g\",\"profile\":$_prof,\"started\":\"$_ts\",\"last_cleanup\":null}"
  fgc_log "GAME_DETECTED" "$_g" "detect" "info" ""
  fgc_log "SESSION_STARTED" "$_g" "session" "profile-$_prof" ""
  export FGC_GAME="$_g"
  export FGC_PROFILE="$_prof"
  _targets="$(fgc_policy_targets "$_prof" "$_g")"
  # Per-profile action matrix (user-defined):
  #   1 Balance     = Normal: session tracked, NO force-stop, NO freeze.
  #   2 Performance = force-stop blacklist, no freeze/unfreeze involved.
  #   3 Awaken      = force-stop + freeze, unfreezed at session end.
  _sum="no action (balance normal)"
  if [ "$_prof" != "1" ]; then
    # shellcheck disable=SC2086 — word splitting on exact package lines intended
    _sum="$(fgc_cleanup $_targets)"
  fi
  # Freeze (Awaken only): disable-user AFTER force-stop so targets cannot
  # autostart back mid-session. Fully reversible: unfreezed at session end.
  # User-type only (all profiles); system-type needs freeze_system + Awaken.
  if [ "$_prof" = "3" ]; then
    # shellcheck disable=SC2086 — word splitting on exact package lines intended
    fgc_freeze $_targets
  fi
  # Awaken: ONE bounded second sweep for targets still running afterwards.
  if [ "$_prof" = "3" ]; then
    _again=""
    for _p in $_targets; do
      if fgc_pkg_running "$_p"; then _again="$_again $_p"; fi
    done
    if [ -n "$_again" ]; then
      for _rp in $_again; do
        fgc_log "CLEANUP_SUCCESS" "$_rp" "second-sweep" "retry-still-running" ""
      done
      _sum2="$(fgc_cleanup $_again)"
      _sum="$_sum; second-sweep: $_sum2"
    fi
  fi
  fgc_state_write "{\"game\":\"$_g\",\"profile\":$_prof,\"started\":\"$_ts\",\"last_cleanup\":\"$_sum at $_ts\"}"
  fgc_log "CLEANUP_SUCCESS" "$_g" "cleanup" "$_sum" ""
}

fgc_session_end() {
  [ -f "$LOCK" ] || return 0
  _g="$(cat "$LOCK" 2>/dev/null)"
  # restore everything we froze this session (or a crashed one) first
  fgc_unfreeze_all "SESSION_ENDED"
  rm -f "$LOCK"
  _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  fgc_state_write "{\"game\":null,\"profile\":$(fgc_cfg_get default_profile 2>/dev/null || echo 1),\"started\":null,\"last_cleanup\":\"session $_g ended at $_ts\"}"
  fgc_log "SESSION_ENDED" "$_g" "session" "ended" ""
}
