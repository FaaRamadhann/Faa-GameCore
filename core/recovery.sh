#!/system/bin/sh
# recovery.sh — boot/self-heal: clear stale locks, validate config files.
FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
CORE_DIR="$FGC_MODDIR/core"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/paths.sh"
. "$CORE_DIR/process_manager.sh"
. "$CORE_DIR/config_manager.sh"

fgc_recovery() {
  mkdir -p "$FGC_STATE" "$FGC_LOGS" "$FGC_CONFIG"
  # persistent data first: re-seed/re-link after updates, before anything writes
  if ls "$CORE_DIR" 2>/dev/null | grep -qx 'data_init.sh'; then
    . "$CORE_DIR/data_init.sh"
    fgc_data_init "$FGC_MODDIR" >/dev/null 2>&1 || true
  fi
  # fresh boot: any daemon lock is definitionally stale, but removal lives in
  # main.sh's pid-verified guard (recovery also runs nested inside main starts,
  # where blindly clearing the lock would defeat single-instance protection).
  # refresh capability snapshot + dynamic launcher protection (universal, best effort)
  if ls "$CORE_DIR" 2>/dev/null | grep -qx 'caps.sh'; then
    . "$CORE_DIR/caps.sh"
    fgc_detect_caps >/dev/null 2>&1 || true
  fi
  # stale lock: if no game process match, drop it (safe, never kills)
  if [ -f "$FGC_STATE/session.lock" ]; then
    _g="$(cat "$FGC_STATE/session.lock" 2>/dev/null)"
    if ps -A > "$FGC_STATE/.ps" 2>/dev/null; then
      if ! grep -q "$_g" "$FGC_STATE/.ps" 2>/dev/null; then
        rm -f "$FGC_STATE/session.lock"
        fgc_log "RECOVERY" "$_g" "stale-lock" "cleared" ""
      fi
    fi
  fi
  # stale freeze: a crash mid-session can leave apps disabled — restore them.
  # Runs at every boot; fgc_unfreeze_all is idempotent and keeps entries whose
  # enable failed but whose package still exists (retried next boot).
  fgc_unfreeze_all "RECOVERY"
  # config.json: upgrade to the canonical pretty layout (readable + hand-editable)
  # plus any key a newer release added. Data-preserving — the helper verifies
  # every value before it renames, and refuses when it sees an unknown key.
  fgc_cfg_normalize "$FGC_CONFIG/config.json" >/dev/null 2>&1 || true
  # validate configs exist
  for _f in config.json gamelist.json blacklist.txt whitelist.txt; do
    [ -f "$FGC_CONFIG/$_f" ] || fgc_log "CORE_ERROR" "" "recovery" "missing-$_f" ""
  done
  echo "recovery done"
}
case "$0" in *recovery.sh) fgc_recovery ;; esac
