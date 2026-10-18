#!/system/bin/sh
# service.sh — boot service: starts the FGC supervisor in the background.
# Portable: only POSIX sh + getprop/sleep/sh (no nohup/setsid dependency).
# A restart must run the code that is on disk NOW: after a module update the
# previous daemon would otherwise keep running the old files (an old unfreeze bug
# stayed alive until the next reboot). So the daemon is always replaced here; the
# supervisor restarts it from disk, and re-execs itself if its own file changed.
# The new daemon's recovery skips unfreeze while a session is live, so this never
# re-enables a blacklist app mid-game.
# WebUI "Restart core" execs this file through the bridge, which reads until EOF,
# so this script MUST return: the supervisor owns its own stdout/stderr below and
# never holds the caller's pipe.
MODDIR=${0%/*}
. "$MODDIR/core/paths.sh"
LOGDIR="$FGC_LOGS"
mkdir -p "$LOGDIR" 2>/dev/null

# Restart epoch: a daemon that survives the kill (a TERM is deferred while it sits
# inside a long pm/dumpsys call) retires on its next poll instead of polling
# beside the new one.
printf '%s' "$(date +%s)-$$" > "$FGC_STATE/core.epoch" 2>/dev/null

_sup="$(cat "$FGC_STATE/supervise.lock/pid" 2>/dev/null)"
case "$_sup" in ''|*[!0-9]*) _sup="" ;; esac
if [ -n "$_sup" ] && [ -r "/proc/$_sup/cmdline" ] \
   && tr '\0' ' ' < "/proc/$_sup/cmdline" | grep -q 'core/supervise.sh'; then
  # A live supervisor owns the restart loop: kill only the daemon. Restarting the
  # supervisor here is what used to duplicate it (it can fork a daemon right
  # after a scan), and the supervisor already reloads itself when its file
  # changes. Nothing to do when it is busy starting the daemon right now.
  _d="$(cat "$FGC_STATE/daemon.lock/pid" 2>/dev/null)"
  case "$_d" in ''|*[!0-9]*) _d="" ;; esac
  if [ -n "$_d" ] && tr '\0' ' ' < "/proc/$_d/cmdline" 2>/dev/null | grep -q 'core/main.sh'; then
    kill "$_d" 2>/dev/null
    # The daemon is the only thing that unfreezes when the game closes, so a
    # restart that silently fails to replace it leaves old code running. TERM is
    # deferred while it sits inside a long pm/dumpsys call: escalate to KILL.
    # Safe because the freeze journal is write-ahead and the next daemon's
    # recovery skips unfreeze while a session is live.
    _w=0
    while [ "$_w" -lt 4 ]; do
      kill -0 "$_d" 2>/dev/null || break
      _w=$((_w+1)); sleep 1
    done
    kill -0 "$_d" 2>/dev/null && kill -9 "$_d" 2>/dev/null
  fi
  exit 0
fi

# No usable supervisor: first start, or one from a version that kept no lock (or
# a stale lock from a crash). Clear every old core process so nothing keeps
# running stale code, then start one fresh supervisor. TERM first (clean lock
# release), then KILL: a daemon inside a long pm/dumpsys call defers TERM, and a
# survivor whose lock we are about to delete would poll beside the new daemon.
_killcore() {
  for _pd in /proc/[0-9]*; do
    _p="${_pd#/proc/}"
    [ "$_p" = "$$" ] && continue
    [ -r "$_pd/cmdline" ] || continue
    case "$(tr '\0' ' ' < "$_pd/cmdline" 2>/dev/null)" in
      *"$MODDIR/core/main.sh"*|*"$MODDIR/core/supervise.sh"*) kill $1 "$_p" 2>/dev/null ;;
    esac
  done
}
_killcore ""
sleep 1
_killcore -9
sleep 1
rm -rf "$FGC_STATE/supervise.lock" "$FGC_STATE/daemon.lock" 2>/dev/null
sh "$MODDIR/core/supervise.sh" >>"$LOGDIR/service.log" 2>&1 </dev/null &
exit 0
