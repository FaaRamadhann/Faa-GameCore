#!/system/bin/sh
# service.sh — boot service: starts the FGC supervisor in the background.
# Portable: only POSIX sh + getprop/sleep/sh (no nohup/setsid dependency).
# Idempotent: safe to run anytime (post-boot manual runs included) — main.sh
# single-instance-guards itself, so re-running never duplicates.
# WebUI "Restart core" execs this file through the bridge, which reads until EOF,
# so this script MUST return: the supervisor owns its own stdout/stderr below and
# never holds the caller's pipe.
MODDIR=${0%/*}
. "$MODDIR/core/paths.sh"
LOGDIR="$FGC_LOGS"
mkdir -p "$LOGDIR" 2>/dev/null
sh "$MODDIR/core/supervise.sh" >>"$LOGDIR/service.log" 2>&1 </dev/null &
exit 0
