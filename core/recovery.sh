#!/system/bin/sh
# recovery.sh — boot/self-heal: clear stale locks, validate config files.
FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
CORE_DIR="$FGC_MODDIR/core"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/paths.sh"
. "$CORE_DIR/process_manager.sh"
. "$CORE_DIR/config_manager.sh"
. "$CORE_DIR/gamelist.sh"

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
  _live_sess=0
  if [ -f "$FGC_STATE/session.lock" ]; then
    _g="$(cat "$FGC_STATE/session.lock" 2>/dev/null)"
    if ps -A > "$FGC_STATE/.ps" 2>/dev/null; then
      if ! grep -q "$_g" "$FGC_STATE/.ps" 2>/dev/null; then
        rm -f "$FGC_STATE/session.lock"
        fgc_log "RECOVERY" "$_g" "stale-lock" "cleared" ""
      else
        _live_sess=1
      fi
    fi
  fi
  # stale freeze: a crash mid-session can leave apps disabled — restore them.
  # Runs at every boot; fgc_unfreeze_all is idempotent and keeps entries whose
  # enable failed but whose package still exists (retried next boot).
  # NEVER while a session is still live: service.sh restarts the core after a
  # crash, and unfreezing there would re-enable the blacklist mid-game.
  if [ "$_live_sess" = "1" ]; then
    fgc_log "RECOVERY" "$_g" "unfreeze" "skipped-session-active" ""
  else
    # A daemon killed mid-freeze (LMK SIGKILL, or the user swiping it away) can
    # have a `pm disable-user` already in flight. That disable lands AFTER the
    # pass below has drained the journal — the entry was retired because the app
    # still looked enabled — and the app stays disabled with an EMPTY journal,
    # which is the one state with no way back. Keep a copy of the entries we are
    # about to retire and re-check them once the dust settles.
    _prev="$FGC_STATE/.frozen_prev"
    rm -f "$_prev" 2>/dev/null
    [ -s "$FGC_STATE/frozen.txt" ] && cp "$FGC_STATE/frozen.txt" "$_prev" 2>/dev/null
    fgc_unfreeze_all "RECOVERY"
    if [ -s "$_prev" ]; then
      # Re-arm the entries we just retired and run the SAME verified pass again:
      # a package still enabled is retired again, one that is provably gone stays
      # gone, and one whose disable landed late is restored.
      sleep 2
      sort -u "$_prev" "$FGC_STATE/frozen.txt" 2>/dev/null > "$_prev.new"
      mv "$_prev.new" "$FGC_STATE/frozen.txt" 2>/dev/null
      fgc_unfreeze_all "RECOVERY"
      rm -f "$_prev" "$_prev.new" 2>/dev/null
    fi
  fi
  # config.json: upgrade to the canonical pretty layout (readable + hand-editable)
  # plus any key a newer release added. Data-preserving — the helper verifies
  # every value before it renames, and refuses when it sees an unknown key.
  fgc_cfg_normalize "$FGC_CONFIG/config.json" >/dev/null 2>&1 || true
  # gamelist.json: same treatment — a legacy one-line file is rewritten pretty
  # (readable + hand-editable). An already-pretty file is never touched.
  fgc_glist_normalize "$FGC_CONFIG/gamelist.json" >/dev/null 2>&1 || true
  # validate configs exist
  for _f in config.json gamelist.json blacklist.txt whitelist.txt; do
    [ -f "$FGC_CONFIG/$_f" ] || fgc_log "CORE_ERROR" "" "recovery" "missing-$_f" ""
  done
  echo "recovery done"
}
case "$0" in *recovery.sh) fgc_recovery ;; esac
