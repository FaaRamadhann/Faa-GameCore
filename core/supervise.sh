#!/system/bin/sh
# supervise.sh — keeps core/main.sh alive. Started in the background by
# service.sh; safe to run anytime (main.sh single-instance-guards itself).
# The core is the ONLY thing that re-enables a blacklist app when the game
# closes, so if it dies (crash, low-memory kill, a hung `pm`) those apps stay
# disabled until the next reboot. Restarting it is the last line of defence
# behind the write-ahead freeze journal.
MODDIR=${0%/*}
MODDIR=${MODDIR%/core}
CORE="$MODDIR/core/main.sh"
. "$MODDIR/core/paths.sh"
# Wait for boot completion (bounded, no busy loop)
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then break; fi
  sleep 10
done
if ! ls "${CORE%/*}" 2>/dev/null | grep -qx "${CORE##*/}"; then
  echo "FGC supervise: missing $CORE"
  exit 0
fi
# Single instance. Two supervisors double every fork and both race to restart
# the same daemon (observed after tapping "Restart core" while one was alive).
# PID-validated like main.sh's lock, so a SIGKILLed supervisor never wedges it.
_SLOCK="$FGC_STATE/supervise.lock"
if ! mkdir "$_SLOCK" 2>/dev/null; then
  _stry=0
  while :; do
    _sp="$(cat "$_SLOCK/pid" 2>/dev/null)"
    case "$_sp" in ''|*[!0-9]*) _sp="" ;; esac
    # Our own pid = we are the re-exec of this same supervisor: keep the lock.
    [ "$_sp" = "$$" ] && break
    if [ -n "$_sp" ] && [ -r "/proc/$_sp/cmdline" ] && tr '\0' ' ' < "/proc/$_sp/cmdline" | grep -q 'core/supervise.sh'; then
      exit 0
    fi
    # Same start-up window as main.sh: a sibling may not have written its pid yet.
    # A written pid that is dead is definitively stale, so reclaim at once.
    if [ -s "$_SLOCK/pid" ]; then _stry=99; fi
    _stry=$((_stry+1))
    if [ "$_stry" -gt 6 ]; then
      rm -rf "$_SLOCK" 2>/dev/null
      mkdir "$_SLOCK" 2>/dev/null && break
      exit 0
    fi
    sleep 1
  done
fi
printf '%s' "$$" > "$_SLOCK/pid" 2>/dev/null
# Only remove the lock if it is still OURS. A supervisor that exits late would
# otherwise delete the lock a fresh supervisor had just created.
_sl_cleanup() {
  [ -n "${_dpid:-}" ] && kill "$_dpid" 2>/dev/null
  [ "$(cat "$_SLOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$_SLOCK" 2>/dev/null
}
trap '_sl_cleanup; exit 0' TERM INT
# Bounded run = test hook (FGC_MAX_ITER): start once, never supervise.
if [ "${FGC_MAX_ITER:-0}" -gt 0 ] 2>/dev/null; then
  sh "$CORE" "$MODDIR" </dev/null
  _sl_cleanup
  exit 0
fi
# Lock check = avoid a fork every cycle; it validates the PID like main.sh, so a
# stale lock (SIGKILL) is never mistaken for a live daemon — that would stall the
# supervisor forever. main.sh removes a stale lock itself when started.
_cyc=0
# Self-reload: "Restart core" no longer replaces the supervisor, so an update to
# this file must still take effect. exec keeps the PID (and the lock) and re-reads
# the file from disk.
_self_sig="$(stat -c '%Y %s' "$0" 2>/dev/null)"
while :; do
  if [ "${FGC_SUPERVISE_MAX:-0}" -gt 0 ] 2>/dev/null; then :; else
    _now_sig="$(stat -c '%Y %s' "$0" 2>/dev/null)"
    if [ -n "$_self_sig" ] && [ -n "$_now_sig" ] && [ "$_now_sig" != "$_self_sig" ]; then
      exec sh "$0"
    fi
  fi
  _d=""
  if [ -d "$FGC_STATE/daemon.lock" ]; then
    _d="$(cat "$FGC_STATE/daemon.lock/pid" 2>/dev/null)"
    case "$_d" in ''|*[!0-9]*) _d="" ;; esac
    if [ -n "$_d" ] && [ -r "/proc/$_d/cmdline" ]; then
      tr '\0' ' ' < "/proc/$_d/cmdline" | grep -q 'core/main.sh' || _d=""
    else
      _d=""
    fi
  fi
  if [ -z "$_d" ]; then
    # Background + wait, NOT a foreground call: a foreground daemon made this
    # supervisor unresponsive to TERM (the trap only runs once the child exits),
    # so "Restart core" could not retire the old pair and left two daemons.
    sh "$CORE" "$MODDIR" </dev/null &
    _dpid=$!
    wait "$_dpid"
    _cyc=$((_cyc+1))
    # FGC_SUPERVISE_MAX: lifecycle hook for automated tests (default 0 = forever).
    if [ "${FGC_SUPERVISE_MAX:-0}" -gt 0 ] 2>/dev/null && [ "$_cyc" -ge "$FGC_SUPERVISE_MAX" ]; then break; fi
  else
    sleep 10
  fi
done
_sl_cleanup
