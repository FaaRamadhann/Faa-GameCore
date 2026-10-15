#!/system/bin/sh
# caps.sh — runtime capability detection. No model-name checks, no brand assumptions.
# Probes which Android commands exist and which detection methods actually work.
# Writes state/caps.json (best effort) and shell-sets FGC_CAPS_* vars. Sourced, not executed.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"
. "${FGC_MODDIR}/core/str.sh"

fgc_has_cmd() { command -v "$1" >/dev/null 2>&1; }

fgc_detect_launcher() {
  # Best-effort current launcher package. Prints package or empty. Never fails hard.
  # File-based (no cmd|grep pipe): avoids early-exit pipe hazards on some runtimes.
  _r=""
  if fgc_has_cmd cmd; then
    _cout="$FGC_STATE/.cmdout"
    if fgc_run_timed 15 cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME > "$_cout" 2>/dev/null; then
      while IFS= read -r _cl || [ -n "$_cl" ]; do
        case "$_cl" in */*) _r="${_cl%%/*}"; break ;; esac
      done < "$_cout"
    fi
    rm -f "$_cout"
  fi
  if [ -z "$_r" ] && fgc_has_cmd dumpsys; then
    _dout="$FGC_STATE/.dout"
    if fgc_run_timed 15 dumpsys activity activities > "$_dout" 2>/dev/null; then
      _r="$(grep -m1 'mFocusedApp' "$_dout" 2>/dev/null | grep -o '[a-zA-Z][a-zA-Z0-9_]*\(\.[a-zA-Z0-9_][a-zA-Z0-9_]*\)\+' | tail -n1)"
    fi
    rm -f "$_dout"
    case "$_r" in *launcher*|*home*) ;; *) _r="" ;; esac
  fi
  case "$_r" in ''|*[!a-zA-Z0-9._]*) printf '' ;; *) printf '%s' "$_r" ;; esac
}

fgc_detect_caps() {
  # Prints compact JSON. Also refreshes state/protected_extra.txt (dynamic launcher).
  _pm=no;     fgc_has_cmd pm && _pm=yes
  _dumpsys=no; fgc_has_cmd dumpsys && _dumpsys=yes
  _am=no;     fgc_has_cmd am && _am=yes
  _cmd=no;    fgc_has_cmd cmd && _cmd=yes
  _getprop=no; fgc_has_cmd getprop && _getprop=yes
  _fg=none
  if [ "$_dumpsys" = yes ]; then
    # grep -c consumes all input (no early exit) -> always terminates
    if [ "$(fgc_run_timed 20 dumpsys activity activities 2>/dev/null | grep -c 'mFocusedApp\|ResumedActivity')" -gt 0 ] 2>/dev/null; then _fg=activity
    elif [ "$(fgc_run_timed 20 dumpsys window windows 2>/dev/null | grep -c 'mCurrentFocus\|mFocusedApp')" -gt 0 ] 2>/dev/null; then _fg=window
    else _fg=dumpsys-present-unverified; fi
  fi
  _pkg=none; [ "$_pm" = yes ] && _pkg=pm
  _kill=none; [ "$_am" = yes ] && _kill=am
  mkdir -p "$FGC_STATE"
  # system-package snapshot for profile policy (Balance = user-type only).
  # No early-exit pipes: pm output fully consumed, empty result removes stale data.
  _sys="$FGC_STATE/.syspkgs"
  if fgc_has_cmd pm; then
    fgc_run_timed 20 pm list packages -s 2>/dev/null | sed 's/^package://' | sort -u > "$_sys.tmp" 2>/dev/null
    if [ -s "$_sys.tmp" ]; then mv "$_sys.tmp" "$_sys"; else rm -f "$_sys.tmp" "$_sys"; fi
  else
    rm -f "$_sys"
  fi
  # dynamic extra protection: detected launcher (universal, not brand-specific)
  _lc="$(fgc_detect_launcher)"
  if [ -n "$_lc" ]; then printf '%s\n' "$_lc" > "$FGC_STATE/protected_extra.txt"
  else : > "$FGC_STATE/protected_extra.txt"; fi
  printf '{"pm":"%s","dumpsys":"%s","am":"%s","cmd":"%s","getprop":"%s","foreground":"%s","pkg_query":"%s","kill":"%s","launcher":"%s"}\n' \
    "$_pm" "$_dumpsys" "$_am" "$_cmd" "$_getprop" "$_fg" "$_pkg" "$_kill" "$_lc" | tee "$FGC_STATE/caps.json" 2>/dev/null
}
case "$0" in *caps.sh) fgc_detect_caps ;; esac
