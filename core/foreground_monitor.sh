#!/system/bin/sh
# foreground_monitor.sh — prints current foreground package (single shot, no loop).
# Tries dumpsys activity (root ok), falls back to dumpsys window.
# dumpsys calls are time-bounded (they can block under system contention).

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"
. "${FGC_MODDIR}/core/str.sh"

fgc_foreground_pkg() {
  command -v dumpsys >/dev/null 2>&1 || return 0
  _out="$(fgc_run_timed 10 dumpsys activity activities 2>/dev/null | grep -m1 'mFocusedApp\|ResumedActivity' )"
  if [ -z "$_out" ]; then
    _out="$(fgc_run_timed 10 dumpsys window windows 2>/dev/null | grep -m1 'mCurrentFocus\|mFocusedApp')"
  fi
  # extract last com.xxx / package token
  printf '%s' "$_out" | grep -o '[a-zA-Z][a-zA-Z0-9_]*\(\.[a-zA-Z0-9_][a-zA-Z0-9_]*\)\+' | tail -n1
}
# when executed directly, print it
case "$0" in *foreground_monitor.sh) fgc_foreground_pkg ;; esac
