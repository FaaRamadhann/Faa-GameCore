#!/system/bin/sh
# foreground_monitor.sh — prints current foreground package (single shot, no loop).
# Marker cascade across ROMs (stock and vendor formats differ):
#   1. topResumedActivity= (newer stock/vendor formats)
#   2. mFocusedApp / ResumedActivity (older formats)
#   3. dumpsys window mCurrentFocus/mFocusedApp (legacy fallback)
#   4. dumpsys activity top, first ACTIVITY line (last resort)
# dumpsys calls are time-bounded (they can block under system contention).

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"
. "${FGC_MODDIR}/core/str.sh"

_fgc_valid_tok() {
  # $1 = candidate token; 0 = plausible package name. Pure shell (no grep at
  # all): toybox grep lacks GNU BRE extensions, so validation lives here.
  # NOTE: no TAB/whitespace arm needed — the grep charset above can never
  # emit whitespace, so tokens are whitespace-free by construction.
  case "$1" in
    ''|.*|*.|*..*|*' '*|*/*|*'{'*|*'}'* ) return 1 ;;
  esac
  case "$1" in *.*) return 0 ;; *) return 1 ;; esac
}

_fgc_pkg_of() {
  # $1 = one dumpsys line; prints package or empty. Exact extractors first
  # (u0 pkg/, ACTIVITY pkg/, packageName=), token scan last. POSIX grep only:
  # no \( \), \+, \| anywhere (toybox 0.8.x lacks them and fails SILENTLY).
  _line="$1"
  _p="$(printf '%s' "$_line" | grep -o 'u0 [A-Za-z][A-Za-z0-9_.]*/' | head -n1 | sed 's|^u0 ||;s|/$||')"
  if _fgc_valid_tok "$_p"; then printf '%s' "$_p"; return 0; fi
  _p="$(printf '%s' "$_line" | grep -o 'ACTIVITY [A-Za-z][A-Za-z0-9_.]*/' | head -n1 | sed 's|^ACTIVITY ||;s|/$||')"
  if _fgc_valid_tok "$_p"; then printf '%s' "$_p"; return 0; fi
  _p="$(printf '%s' "$_line" | grep -o 'packageName=[A-Za-z][A-Za-z0-9_.]*' | head -n1 | cut -d= -f2)"
  if _fgc_valid_tok "$_p"; then printf '%s' "$_p"; return 0; fi
  _best=""
  for _t in $(printf '%s' "$_line" | grep -o '[A-Za-z][A-Za-z0-9_.]*'); do
    if _fgc_valid_tok "$_t"; then _best="$_t"; break; fi
  done
  [ -n "$_best" ] && printf '%s' "$_best"
  return 0
}

fgc_foreground_pkg() {
  command -v dumpsys >/dev/null 2>&1 || return 0
  _out="$(fgc_run_timed 10 dumpsys activity activities 2>/dev/null | grep -m1 -e 'topResumedActivity=' -e 'mFocusedApp' -e 'ResumedActivity' )"
  if [ -z "$_out" ]; then
    _out="$(fgc_run_timed 10 dumpsys window windows 2>/dev/null | grep -m1 -e 'mCurrentFocus' -e 'mFocusedApp')"
  fi
  if [ -z "$_out" ]; then
    _out="$(fgc_run_timed 10 dumpsys activity top 2>/dev/null | grep -m1 '^ *ACTIVITY ')"
  fi
  [ -z "$_out" ] && return 0
  _fgc_pkg_of "$_out"
}
case "$0" in *foreground_monitor.sh) fgc_foreground_pkg ;; esac
