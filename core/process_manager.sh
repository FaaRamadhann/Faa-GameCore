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
  _game="$FGC_GAME"
  # Snapshot of already-disabled packages (one pm call): we must never
  # "restore" (enable) something the USER disabled on purpose. Only packages
  # WE transition enabled->disabled are tracked for unfreeze.
  _fdl="$FGC_STATE/.disabled"
  fgc_run_timed 15 pm list packages -d --user 0 2>/dev/null | sort -u > "$_fdl.tmp" 2>/dev/null
  if [ -s "$_fdl.tmp" ]; then mv "$_fdl.tmp" "$_fdl" 2>/dev/null; else rm -f "$_fdl.tmp" 2>/dev/null; : > "$_fdl" 2>/dev/null; fi
  for _p in "$@"; do
    case "$_p" in
      ''|*[!a-zA-Z0-9._]*) fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "invalid package chars"; continue ;;
    esac
    if fgc_is_whitelisted "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "whitelisted"; continue; fi
    if fgc_is_protected "$_p"; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "system-protected"; continue; fi
    if [ -n "$_game" ] && [ "$_p" = "$_game" ]; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "foreground-game"; continue; fi
    if [ "$(fgc_pkg_type "$_p")" != "user" ]; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "system-type-nofreeze"; continue; fi
    if fgc_dry_run; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "dry-run"; continue; fi
    if grep -qx "package:$_p" "$_fdl" 2>/dev/null; then fgc_log "CLEANUP_SKIPPED" "$_p" "freeze" "skipped" "already-disabled"; continue; fi
    if fgc_run_timed 20 pm disable-user --user 0 "$_p" 2>/dev/null; then
      fgc_log "CLEANUP_SUCCESS" "$_p" "freeze" "frozen" ""
      fgc_frozen_add "$_p"
    else
      fgc_log "CLEANUP_FAILED" "$_p" "freeze" "failed" "pm-error"
    fi
  done
}

fgc_unfreeze_all() {
  # $1 = log event (SESSION_ENDED normally, RECOVERY for stale). Restores
  # every package WE froze. Entries that fail are kept for the next boot
  # retry, unless the package is gone entirely (then dropped + logged).
  _ev="${1:-SESSION_ENDED}"
  _fp="$FGC_STATE/frozen.txt"
  [ -f "$_fp" ] || return 0
  _keep=""
  while IFS= read -r _p || [ -n "$_p" ]; do
    _kind=""; _norm=""
    _fgc_norm "$_p" 2>/dev/null || true
    [ "$_kind" = "entry" ] || continue
    _p="$_norm"
    [ -n "$_p" ] || continue
    if fgc_run_timed 20 pm enable --user 0 "$_p" 2>/dev/null; then
      fgc_log "$_ev" "$_p" "unfreeze" "enabled" ""
    else
      # grep -c consumes all input (no early exit) -> always terminates
      if [ "$(fgc_run_timed 15 pm list packages 2>/dev/null | grep -c "^package:$_p$")" -gt 0 ] 2>/dev/null; then
        _keep="$_keep$_p
"
      else
        fgc_log "$_ev" "$_p" "unfreeze" "skipped" "package-gone"
      fi
    fi
  done < "$_fp"
  if [ -z "$_keep" ]; then
    : > "$_fp" 2>/dev/null
  else
    printf '%s' "$_keep" > "$_fp" 2>/dev/null
  fi
}

fgc_cleanup() {
  # args: exact package names. Respects dry-run. One force-stop per pkg, no loops.
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
    if fgc_run_timed 30 am force-stop "$_p" 2>/dev/null; then fgc_log "CLEANUP_SUCCESS" "$_p" "force-stop" "stopped" ""; _ok=$((_ok+1)); else fgc_log "CLEANUP_FAILED" "$_p" "force-stop" "failed" "am-error"; _fail=$((_fail+1)); fi
  done
  echo "$_ok stopped, $_skip skipped, $_fail failed"
}
