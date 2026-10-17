#!/system/bin/sh
# str.sh — pure-shell string helpers. Zero forks, zero pipes.
# Rationale: multi-stage `a | b | grep -q` chains can hang on some
# runtimes (observed on msys; risky on minimal busybox/toybox builds)
# when the consumer exits early. These helpers never create a pipe.
# Sourced, not executed. Strictly POSIX (works in dash/mksh/busybox sh).

# _fgc_norm "$line" -> sets _norm (cleaned token) and _kind
# _kind: blank | comment | disabled | entry
_fgc_norm() {
  _norm="$1"
  while :; do case "$_norm" in [[:space:]]*) _norm="${_norm#?}" ;; *) break ;; esac; done
  while :; do case "$_norm" in *[[:space:]]) _norm="${_norm%?}" ;; *) break ;; esac; done
  _kind=entry
  case "$_norm" in
    '') _kind=blank ;;
    \#*) _kind=comment ;;
    \!*) _kind=disabled; _norm="${_norm#!}" ;;
  esac
  case "$_kind" in
    entry|disabled)
      _t=""; _r="$_norm"
      while [ -n "$_r" ]; do
        _c="${_r%"${_r#?}"}"
        case "$_c" in [[:space:]]) ;; *) _t="$_t$_c" ;; esac
        _r="${_r#?}"
      done
      _norm="$_t"
      [ -n "$_norm" ] || _kind=blank
      ;;
  esac
}

# _fgc_clean "$field" -> sets _clean (tabs/newlines/CR/quotes stripped, spaces kept)
_FGC_TAB="$(printf '\t')"; _FGC_CR="$(printf '\r')"
_FGC_NL='
'
# fgc_run_timed <secs> <cmd...> — guard against hanging Android commands
# (dumpsys/pm/cmd occasionally block for minutes under system contention).
# Uses `timeout` when present, else direct exec. Exit status passes through.
# No pipes are created here.
fgc_run_timed() {
  _t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_t" "$@"
  else "$@"; fi
}
# fgc_snap <file> <cmd...> — run cmd, write its stdout to <file>, keep its rc.
# NEVER redirect a Java tool's stdout straight to a file under /data/adb:
# pm/dumpsys are app_process wrappers, and the zygote context cannot write
# there, so `pm list packages -d > $FGC_STATE/x` makes app_process ABORT
# (SIGABRT) and the snapshot comes out empty/garbage. Every already-disabled
# check then failed, so FGC re-enabled apps the user had disabled and burned
# pm calls in a retry loop ("Failed transaction 2147483646"). Capturing in the
# shell (pipe is fine) and writing the file ourselves keeps output AND status.
fgc_snap() {
  _sf="$1"; shift
  _so="$("$@" 2>/dev/null)"; _src=$?
  if [ -n "$_so" ]; then printf '%s\n' "$_so" > "$_sf" 2>/dev/null
  else : > "$_sf" 2>/dev/null; fi
  return "$_src"
}
_fgc_clean() {  _clean=""; _r="$1"
  while [ -n "$_r" ]; do
    _c="${_r%"${_r#?}"}"
    case "$_c" in "$_FGC_TAB"|"$_FGC_NL"|"$_FGC_CR"|\") ;; *) _clean="$_clean$_c" ;; esac
    _r="${_r#?}"
  done
}
