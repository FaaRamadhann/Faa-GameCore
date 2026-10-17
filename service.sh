#!/system/bin/sh
# service.sh — boot service, starts FGC core in background.
# Portable: only POSIX sh + getprop/sleep/sh (no nohup/setsid dependency).
# Idempotent: safe to run anytime (post-boot manual runs included) —
# main.sh single-instance-guards itself, so re-running never duplicates.
# WebUI "Restart core" also execs this file via the WebView bridge.
MODDIR=${0%/*}
CORE="$MODDIR/core/main.sh"
. "$MODDIR/core/paths.sh"
LOGDIR="$FGC_LOGS"
mkdir -p "$LOGDIR" 2>/dev/null
# Wait for boot completion, then launch (bounded wait, no busy loop)
(
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; then break; fi
    sleep 10
  done
  if ! ls "${CORE%/*}" 2>/dev/null | grep -qx "${CORE##*/}"; then
    echo "FGC service: missing $CORE" >>"$LOGDIR/service.log" 2>&1
    exit 0
  fi
  # Bounded run = test hook (FGC_MAX_ITER): start once, never supervise.
  if [ "${FGC_MAX_ITER:-0}" -gt 0 ] 2>/dev/null; then
    sh "$CORE" "$MODDIR" >>"$LOGDIR/service.log" 2>&1 < /dev/null &
    exit 0
  fi
  # Supervise. The core is the ONLY thing that re-enables a blacklist app when
  # the game closes, so if it dies (crash, low-memory kill, a hung `pm`) those
  # apps stay disabled forever — "session ended but still disabled". Restart it.
  # A duplicate supervisor is harmless: main.sh holds daemon.lock, so the extra
  # one finds the lock and only sleeps.
  while :; do
    [ -d "$FGC_STATE/daemon.lock" ] || sh "$CORE" "$MODDIR" >>"$LOGDIR/service.log" 2>&1 < /dev/null
    sleep 15
  done
) &
