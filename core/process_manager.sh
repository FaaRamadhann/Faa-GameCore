#!/system/bin/sh
# process_manager.sh — safe cleanup executor. No dynamic code, no command-string building.
# Only acts on exact package names passed as arguments.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
CORE_DIR="$FGC_MODDIR/core"
# shellcheck disable=SC1091
. "$CORE_DIR/policy_engine.sh"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/paths.sh"

fgc_pkg_running() {
  # $1 = pkg ; 0 if any process matches exact package (file-based, no pipe)
  _p="$1"
  ps -A > "$FGC_STATE/.ps" 2>/dev/null || return 1
  grep -q " $_p\$" "$FGC_STATE/.ps" 2>/dev/null && return 0
  grep -q " $_p:" "$FGC_STATE/.ps" 2>/dev/null
}

fgc_dry_run() {
  case "$(cat "$FGC_CONFIG/config.json" 2>/dev/null)" in
    *'"dry_run":true'*|*'"dry_run": true'*) return 0 ;; *) return 1 ;;
  esac
}

fgc_frozen_add() {
  # $1 = pkg; record in frozen list (unique). No pipes.
  _fp="$FGC_STATE/frozen.txt"
  [ -f "$_fp" ] || : > "$_fp" 2>/dev/null
  fgc_has_active "$_fp" "$1" 2>/dev/null && return 0
  printf '%s\n' "$1" >> "$_fp" 2>/dev/null
}

fgc_freeze() {
  # args: exact package names. pm disable-user (fully reversible, unlike
  # force-stop which apps can escape via autostart). User-type ONLY, always —
  # freezing system components risks bootloops and is never worth it.
  # Whitelist/protected/foreground gates identical to cleanup. Respects dry-run.
  # FAIL-CLOSED like cleanup: unreadable whitelist aborts the whole freeze.
  if ! cat "$FGC_CONFIG/whitelist.txt" >/dev/null 2>&1; then
    fgc_log "CORE_ERROR" "" "freeze" "aborted" "whitelist-unreadable"
    return 0
  fi
  _game="$FGC_GAME"
  # Snapshot of already-disabled packages (one pm call): we must never
  # "restore" (enable) something the USER disabled on purpose. Only packages
  # WE transition enabled->disabled are tracked for unfreeze.
  _fdl="$FGC_STATE/.disabled"
  fgc_run_timed 15 pm list packages -d --user 0 2>/dev/null | sort -u > "$_fdl.tmp" 2>/dev/null
  if [ -s "$_fdl.tmp" ]; then mv "$_fdl.tmp" "$_fdl" 2>/dev/null; else rm -f "$_fdl.tmp" 2>/dev/null; : > "$_fdl" 2>/dev/null; fi
  : > "$_fdl.rc" 2>/dev/null
  for _p in "$@"; do
    case "$_p" in
      ''|*[!a-zA-Z0-9._]*) fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "invalid package chars"; continue ;;
    esac
    if fgc_is_whitelisted "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "whitelisted"; continue; fi
    if fgc_is_protected "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "system-protected"; continue; fi
    if [ -n "$_game" ] && [ "$_p" = "$_game" ]; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "foreground-game"; continue; fi
    # System-type freeze is opt-in (config freeze_system) AND Awaken-only.
    # Protected/whitelisted above stay exempt no matter what; unknown type
    # always skips (cannot prove user-type). Default OFF = old behavior.
    _ptype="$(fgc_pkg_type "$_p")"
    if [ "$_ptype" != "user" ]; then
      if [ "$_ptype" = "system" ] && [ "${FGC_PROFILE:-2}" = "3" ]; then
        _fs="$(fgc_cfg_get freeze_system 2>/dev/null)"
        [ "$_fs" = "true" ] || { fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "system-type-nofreeze"; continue; }
      else
        fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "system-type-nofreeze"; continue
      fi
    fi
    if fgc_dry_run; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "dry-run"; continue; fi
    if grep -qx "package:$_p" "$_fdl" 2>/dev/null; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "already-disabled"; continue; fi
    # stdout MUST be silenced: pm prints "Package X new state: ..." on STDOUT,
    # which would corrupt the CLI's JSON response (captured by the WebUI) and
    # the fgc_cleanup summary line. Stderr too (binder "Failed transaction").
    fgc_run_timed 20 pm disable-user --user 0 "$_p" >/dev/null 2>&1
    printf '%s|%s\n' "$?" "$_p" >> "$_fdl.rc" 2>/dev/null
  done
  # Verify against ONE live snapshot: never record a package we did not actually
  # disable (honest success), and never lose one the ROM disabled despite a
  # binder error. Skipped silently if the package service is unreachable.
  _live="$FGC_STATE/.disabled_live"
  _canv=0
  if [ -s "$_fdl.rc" ]; then
    if fgc_run_timed 15 pm list packages -d --user 0 > "$_live" 2>/dev/null; then _canv=1; fi
  fi
  if [ -f "$_fdl.rc" ]; then
    while IFS= read -r _l || [ -n "$_l" ]; do
      [ -n "$_l" ] || continue
      _rc="${_l%%|*}"; _p="${_l#*|}"
      [ -n "$_p" ] || continue
      if [ "$_canv" = "1" ]; then
        if grep -qx "package:$_p" "$_live" 2>/dev/null; then
          fgc_log "CLEANUP_SUCCESS" "$_p" "freeze" "frozen" ""
          fgc_frozen_add "$_p"
        else
          fgc_log "CLEANUP_FAILED" "$_p" "freeze" "failed" "not-disabled-after-cmd"
        fi
      elif [ "$_rc" = "0" ]; then
        fgc_log "CLEANUP_SUCCESS" "$_p" "freeze" "frozen" "unverified"
        fgc_frozen_add "$_p"
      else
        fgc_log "CLEANUP_FAILED" "$_p" "freeze" "failed" "pm-error"
      fi
    done < "$_fdl.rc"
  fi
  rm -f "$_fdl.rc" "$_live" 2>/dev/null
}

fgc_pkg_installed() {
  # 0 = installed, 1 = provably gone, 2 = unknown (probe itself failed).
  # `pm path` is the right probe: it answers for DISABLED packages too. But when
  # the package service is contended it can fail with "Failed transaction" —
  # in that case we must NOT conclude "gone" (that dropped the entry from
  # frozen.txt and left the app disabled forever with no boot retry).
  _o="$(fgc_run_timed 15 pm path "$1" 2>/dev/null)"; _rc=$?
  case "$_o" in
    package:*) return 0 ;;
  esac
  [ "$_rc" -ne 0 ] && return 2
  [ -n "$_o" ] && return 2
  return 1
}

fgc_pkg_disabled() {
  # 0 = package is listed disabled for user 0, 1 = enabled, 2 = probe failed.
  # `pm list packages -d` is served by the same package service as enable/disable,
  # so a failed probe must never be mistaken for "enabled".
  _f="$FGC_STATE/.disabled_probe"
  fgc_run_timed 15 pm list packages -d --user 0 > "$_f" 2>/dev/null || { rm -f "$_f"; return 2; }
  if grep -qx "package:$1" "$_f" 2>/dev/null; then rm -f "$_f"; return 0; fi
  rm -f "$_f"; return 1
}

fgc_unfreeze_all() {
  # $1 = log event (SESSION_ENDED normally, RECOVERY for stale). Restores
  # every package WE froze. A transient pm failure is RETRIED here and, if it
  # still fails, the entry is KEPT for the next retry (session end / boot).
  # Only a package that no longer EXISTS is retired.
  _ev="${1:-SESSION_ENDED}"
  _fp="$FGC_STATE/frozen.txt"
  [ -f "$_fp" ] || return 0
  _keep=""
  _oklist=""
  while IFS= read -r _p || [ -n "$_p" ]; do
    _kind=""; _norm=""
    _fgc_norm "$_p" 2>/dev/null || true
    [ "$_kind" = "entry" ] || continue
    _p="$_norm"
    [ -n "$_p" ] || continue
    _done=1; _try=0
    while [ "$_try" -lt 3 ]; do
      # stdout+stderr MUST be silenced: pm/cmd print to STDOUT, which would
      # corrupt the CLI's JSON reply. Two methods are tried: the `pm` wrapper
      # and the underlying `cmd package` (a ROM may reject one, accept the
      # other). Neither requires SELinux permissive.
      if [ "$_try" = "2" ]; then
        fgc_run_timed 20 cmd package enable --user 0 "$_p" >/dev/null 2>&1 && _done=0
      else
        fgc_run_timed 20 pm enable --user 0 "$_p" >/dev/null 2>&1 && _done=0
      fi
      [ "$_done" = "0" ] && break
      _try=$((_try+1))
      [ "$_try" -lt 3 ] && sleep 1
    done
    if [ "$_done" = "0" ]; then
      _oklist="$_oklist$_p
"
    else
      fgc_pkg_installed "$_p"; _has=$?
      if [ "$_has" = "1" ]; then
        # Provably gone (probe answered, empty): safe to retire.
        fgc_log "$_ev" "$_p" "unfreeze" "skipped" "package-gone"
      else
        # Still present, or we could not prove otherwise -> KEEP and retry.
        _keep="$_keep$_p
"
        fgc_log "$_ev" "$_p" "unfreeze" "failed" "kept-for-retry"
      fi
    fi
  done < "$_fp"
  # Honest verification: a zero exit status that did NOT actually enable the app
  # is not success. ONE live snapshot corrects the whole batch at once.
  if [ -n "$_oklist" ]; then
    _live="$FGC_STATE/.disabled_live"
    _canv=0
    if fgc_run_timed 15 pm list packages -d --user 0 > "$_live" 2>/dev/null; then _canv=1; fi
    while IFS= read -r _p || [ -n "$_p" ]; do
      [ -n "$_p" ] || continue
      if [ "$_canv" = "1" ] && grep -qx "package:$_p" "$_live" 2>/dev/null; then
        _keep="$_keep$_p
"
        fgc_log "$_ev" "$_p" "unfreeze" "failed" "still-disabled-after-cmd"
      elif [ "$_canv" = "1" ]; then
        fgc_log "$_ev" "$_p" "unfreeze" "enabled" ""
      else
        fgc_log "$_ev" "$_p" "unfreeze" "enabled" "unverified"
      fi
    done <<_FGC_OK
$_oklist
_FGC_OK
    rm -f "$_live" 2>/dev/null
  fi
  if [ -z "$_keep" ]; then
    : > "$_fp" 2>/dev/null
  else
    printf '%s' "$_keep" > "$_fp" 2>/dev/null
  fi
}

fgc_cleanup() {
  # args: exact package names. Respects dry-run. One force-stop per pkg, no loops.
  # FAIL-CLOSED: if the whitelist itself is unreadable we must NOT clean —
  # an unreadable whitelist would otherwise fail-open (treated as empty).
  # cat is open-based (works where stat() flakes); missing file = same path.
  if ! cat "$FGC_CONFIG/whitelist.txt" >/dev/null 2>&1; then
    fgc_log "CORE_ERROR" "" "force-stop" "aborted" "whitelist-unreadable"
    echo "0 stopped, 0 skipped, 0 failed"
    return 0
  fi
  _game="$FGC_GAME"
  _ok=0; _skip=0; _fail=0
  for _p in "$@"; do
    case "$_p" in
      ''|*[!a-zA-Z0-9._]*) fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "skipped" "invalid package chars"; _skip=$((_skip+1)); continue ;;
    esac
    if fgc_is_whitelisted "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "skipped" "whitelisted"; _skip=$((_skip+1)); continue; fi
    if fgc_is_protected "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "skipped" "system-protected"; _skip=$((_skip+1)); continue; fi
    if [ -n "$_game" ] && [ "$_p" = "$_game" ]; then fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "skipped" "foreground-game"; _skip=$((_skip+1)); continue; fi
    if ! fgc_pkg_running "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "skipped" "not-running"; _skip=$((_skip+1)); continue; fi
    if fgc_dry_run; then fgc_log "CLEANUP_SKIPPED" "$_p" "force-stop" "dry-run" ""; _skip=$((_skip+1)); continue; fi
    if fgc_run_timed 30 am force-stop "$_p" >/dev/null 2>&1; then fgc_log "CLEANUP_SUCCESS" "$_p" "force-stop" "stopped" ""; _ok=$((_ok+1)); else fgc_log "CLEANUP_FAILED" "$_p" "force-stop" "failed" "am-error"; _fail=$((_fail+1)); fi
  done
  echo "$_ok stopped, $_skip skipped, $_fail failed"
}
