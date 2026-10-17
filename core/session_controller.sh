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
. "$CORE_DIR/gamelist.sh"

LOCK="$FGC_STATE/session.lock"
SESSLOCK="$FGC_STATE/sessop.lock"

fgc_profile_for() {
  # $1 = game pkg. Per-game profile overrides default; 0/empty = default.
  # Auto(4) resolves by BATTERY level (user rule): 1-20 -> Balance(1),
  # 21-50 -> Performance(2), 51-100 -> Awaken(3). Unknown battery -> Balance.
  _g="$1"
  # Per-game profile lookup lives in core/gamelist.sh (layout-tolerant: the
  # gamelist is stored pretty, so a line-oriented [^}]* match would read
  # nothing and silently fall back to the default profile for every game).
  _prof="$(fgc_glist_profile "$FGC_CONFIG/gamelist.json" "$_g" 2>/dev/null)"
  [ -z "$_prof" ] || [ "$_prof" = "0" ] && _prof="$(fgc_cfg_get default_profile 2>/dev/null || echo 1)"
  if [ "$_prof" = "4" ]; then
    _batt="$(fgc_battery_pct 2>/dev/null)"
    if [ -z "$_batt" ]; then echo 1
    elif [ "$_batt" -le 20 ]; then echo 1
    elif [ "$_batt" -le 50 ]; then echo 2
    else echo 3; fi
  else echo "$_prof"; fi
}

fgc_sess_lock() {
  # Serialise the freeze/unfreeze critical section. Without this a daemon poll
  # and a manual CLI (WebUI Start/Stop) can run pm concurrently -> Android's
  # package service answers "Failed transaction (2147483646)" and the app stays
  # frozen after the session ended. Stale locks (dead pid) are reclaimed.
  mkdir -p "$FGC_STATE" 2>/dev/null
  _t=0
  while [ "$_t" -lt 15 ]; do
    if mkdir "$SESSLOCK" 2>/dev/null; then printf '%s' "$$" > "$SESSLOCK/pid" 2>/dev/null; return 0; fi
    _op="$(cat "$SESSLOCK/pid" 2>/dev/null)"
    # kill -0 alone is not enough: after a reboot the recorded PID is usually
    # taken by an unrelated process, so the lock looked held FOREVER and every
    # session end silently gave up (apps stayed disabled). The holder must also
    # be one of our own scripts.
    if [ -n "$_op" ] && [ "$_op" != "$$" ] && kill -0 "$_op" 2>/dev/null \
       && tr '\0' ' ' < "/proc/$_op/cmdline" 2>/dev/null \
          | grep -q -e 'core/main.sh' -e 'core/fgc-cli.sh'; then
      sleep 1; _t=$((_t+1)); continue
    fi
    rm -rf "$SESSLOCK" 2>/dev/null
  done
  return 1
}
fgc_sess_unlock() { rm -rf "$SESSLOCK" 2>/dev/null; }

fgc_session_start() {
  # $1 = game pkg. Serialised; re-entrant end (different game) uses the locked
  # internal so we never deadlock on our own sessop lock.
  _g="$1"; [ -n "$_g" ] || return 1
  fgc_sess_lock || { fgc_log "CORE_ERROR" "$_g" "session" "busy" "sessop-lock"; return 1; }
  _fgc_session_start_locked "$_g"
  _rc=$?
  fgc_sess_unlock
  return "$_rc"
}

_fgc_session_start_locked() {
  # $1 = game pkg. No-op if the same session lock already exists.
  _g="$1"
  mkdir -p "$FGC_STATE"
  if [ -f "$LOCK" ]; then
    _cur="$(cat "$LOCK" 2>/dev/null)"
    if [ "$_cur" = "$_g" ]; then return 0; fi
    _fgc_session_end_locked >/dev/null 2>&1
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
  # A lock we could not take means NOTHING was unfrozen: never report success
  # (the WebUI used to show "session ended" while the apps stayed disabled).
  fgc_sess_lock || { fgc_log "CORE_ERROR" "" "session" "busy" "sessop-lock"; return 1; }
  _fgc_session_end_locked
  _rc=$?
  fgc_sess_unlock
  return "$_rc"
}

_fgc_session_end_locked() {
  if [ ! -f "$LOCK" ]; then
    # No active session. Still drain leftover frozen entries: a failed unfreeze
    # must never leave an app disabled for the whole session (boot recovery and
    # the next session end also retry, but those can be far away).
    # Throttled to one attempt per minute: the daemon reaches this branch on
    # EVERY idle poll, and an app that keeps refusing `pm enable` would otherwise
    # turn the poll loop into a pm retry storm (the contention that started the
    # "Failed transaction" cascade in the first place).
    [ -s "$FGC_STATE/frozen.txt" ] || return 0
    _dt="$FGC_STATE/.drain_ts"
    _dn="$(cat "$_dt" 2>/dev/null)"; [ -n "$_dn" ] || _dn=0
    _now="$(date +%s 2>/dev/null)"; [ -n "$_now" ] || _now=0
    [ $((_now - _dn)) -ge 60 ] || return 0
    printf '%s' "$_now" > "$_dt" 2>/dev/null
    fgc_unfreeze_all "SESSION_ENDED"
    return 0
  fi
  _g="$(cat "$LOCK" 2>/dev/null)"
  # restore everything we froze this session (or a crashed one) first
  fgc_unfreeze_all "SESSION_ENDED"
  rm -f "$LOCK"
  _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  fgc_state_write "{\"game\":null,\"profile\":$(fgc_cfg_get default_profile 2>/dev/null || echo 1),\"started\":null,\"last_cleanup\":\"session $_g ended at $_ts\"}"
  fgc_log "SESSION_ENDED" "$_g" "session" "ended" ""
}
