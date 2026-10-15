#!/system/bin/sh
# policy_engine.sh — decides cleanup targets. Whitelist wins. System protected. Static code only.
# Outputs newline-separated package list to stdout.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"
. "${FGC_MODDIR}/core/str.sh"

# Universal critical packages — never cleaned on ANY device/ROM.
# Brand/launcher names are NOT hardcoded here; the detected launcher is
# appended dynamically via state/protected_extra.txt (see core/caps.sh).
FGC_PROTECTED_BASE="android com.android.systemui com.android.phone com.android.shell"

fgc_is_whitelisted() {
  # exact match against whitelist.txt (ignores # comments, ! disabled, blank)
  _p="$1"
  [ -n "$_p" ] || return 1
  fgc_has_active "$FGC_CONFIG/whitelist.txt" "$_p"
}

# --- list-file readers: pure shell, no multi-stage pipes.
# (A trailing grep -q/-m1 in a pipe chain can hang on some runtimes
#  when the consumer exits early. These readers consume files
#  directly, so they always terminate on any POSIX shell.)
_fgc_strip() { _fgc_norm "$1"; printf '%s' "$_norm"; }

fgc_each_active() {
  # $1 = list file; prints active entries in file order, deduplicated
  [ -f "$1" ] || return 0
  _seen="|"
  while IFS= read -r _l || [ -n "$_l" ]; do
    _fgc_norm "$_l"
    case "$_kind" in entry) ;; *) continue ;; esac
    case "$_seen" in *"|$_norm|"*) continue ;; esac
    _seen="$_seen$_norm|"
    printf '%s\n' "$_norm"
  done < "$1"
}

fgc_has_active() {
  # $1 = list file, $2 = package; exact active match (exit 0 = active)
  [ -n "$2" ] || return 1
  [ -f "$1" ] || return 1
  while IFS= read -r _l || [ -n "$_l" ]; do
    _fgc_norm "$_l"
    [ "$_kind" = entry ] && [ "$_norm" = "$2" ] && return 0
  done < "$1"
  return 1
}

fgc_each_all() {
  # $1 = list file; active lines as-is plus disabled '!pkg' lines.
  # Active wins on conflict. Lets the UI show real ON/OFF toggle state.
  [ -f "$1" ] || return 0
  fgc_each_active "$1"
  _seen="|"
  while IFS= read -r _l || [ -n "$_l" ]; do
    _fgc_norm "$_l"
    [ "$_kind" = disabled ] || continue
    _want="$_norm"  # save: fgc_has_active reuses _norm/_kind/_l internally
    case "$_seen" in *"|$_want|"*) continue ;; esac
    _seen="$_seen$_want|"
    fgc_has_active "$1" "$_want" && continue
    printf '!%s\n' "$_want"
  done < "$1"
}

fgc_is_protected() {
  _p="$1"
  for _s in $FGC_PROTECTED_BASE; do [ "$_p" = "$_s" ] && return 0; done
  # dynamic extras (detected launcher, one package per line, exact match)
  if [ -f "$FGC_STATE/protected_extra.txt" ]; then
    grep -qx "$_p" "$FGC_STATE/protected_extra.txt" 2>/dev/null && return 0
  fi
  return 1
}

fgc_blacklist_active() {
  # prints active (non-commented, non-disabled) blacklist entries, exact lines
  fgc_each_active "$FGC_CONFIG/blacklist.txt"
}

fgc_pkg_type() {
  # $1 = pkg; prints user|system|unknown (needs state/.syspkgs snapshot).
  # Grep reads a FILE (no pipe), so this always terminates.
  [ -n "$1" ] || { echo unknown; return 0; }
  [ -f "$FGC_STATE/.syspkgs" ] || { echo unknown; return 0; }
  if grep -qx "$1" "$FGC_STATE/.syspkgs" 2>/dev/null; then echo system; else echo user; fi
}

fgc_policy_targets() {
  # $1 = profile (1..4, Auto pre-resolved), $2 = foreground game pkg (may be empty)
  # Real per-profile behavior (documented, enforced, tested):
  #   1 Balance     (conservative): user-type targets ONLY; system/unknown skipped.
  #   2 Performance (standard)    : all active targets, single sweep per session.
  #   3 Awaken      (aggressive)  : same scope as 2; the session controller adds
  #                                 ONE bounded second sweep for still-running targets.
  _prof="$1"; _fg="$2"
  for _p in $(fgc_blacklist_active); do
    # exact-match precedence checks
    if fgc_is_whitelisted "$_p"; then continue; fi
    if fgc_is_protected "$_p"; then continue; fi
    # never kill the foreground game itself
    if [ -n "$_fg" ] && [ "$_p" = "$_fg" ]; then continue; fi
    if [ "$_prof" = "1" ] && [ "$(fgc_pkg_type "$_p")" != "user" ]; then continue; fi
    echo "$_p"
  done
}
