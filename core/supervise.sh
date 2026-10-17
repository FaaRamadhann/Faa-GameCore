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
# Bounded run = test hook (FGC_MAX_ITER): start once, never supervise.
if [ "${FGC_MAX_ITER:-0}" -gt 0 ] 2>/dev/null; then
  sh "$CORE" "$MODDIR" </dev/null
  exit 0
fi
# Lock check = avoid a fork every cycle; it validates the PID like main.sh, so a
# stale lock (SIGKILL) is never mistaken for a live daemon — that would stall the
# supervisor forever. main.sh removes a stale lock itself when started.
_cyc=0
while :; do
  _d=""
  if [ -d "$FGC_STATE/daemon.lock" ]; then
    _d="$(cat "$FGC_STATE/daemon.lock/pid" 2>/dev/null)"
    case "$_d" in ''|*[!0-9]*) _d="" ;; esac
    if [ -n "$_d" ]; then
      tr '\0' ' ' < "/proc/$_d/cmdline" 2>/dev/null | grep -q 'core/main.sh' || _d=""
    fi
  fi
  if [ -z "$_d" ]; then
    sh "$CORE" "$MODDIR" </dev/null
    _cyc=$((_cyc+1))
    # FGC_SUPERVISE_MAX: lifecycle hook for automated tests (default 0 = forever).
    if [ "${FGC_SUPERVISE_MAX:-0}" -gt 0 ] 2>/dev/null && [ "$_cyc" -ge "$FGC_SUPERVISE_MAX" ]; then break; fi
  else
    sleep 10
  fi
done
