#!/system/bin/sh
# logger.sh — JSONL session log + state helpers. Static code only. Sourced by other scripts.
# Usage: . "$CORE_DIR/logger.sh" ; fgc_log EVENT PKG ACTION RESULT [ERROR]

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/str.sh"
. "${FGC_MODDIR}/core/paths.sh"
FGC_LOGDIR="$FGC_LOGS"
FGC_STATEDIR="$FGC_STATE"

fgc_log() {
  _ev="$1"; _pkg="${2:-}"; _act="${3:-}"; _res="${4:-}"; _err="${5:-}"
  [ -f "$FGC_CONFIG/config.json" ] || return 0
  case "$(cat "$FGC_CONFIG/config.json" 2>/dev/null)" in
    *'"logging":false'*|*'"logging": false'*) return 0 ;;
  esac
  mkdir -p "$FGC_LOGDIR"
  _ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  # sanitize: strip tabs/newlines/CR/quotes (pure shell, no pipes)
  _fgc_clean "$_ev"; _ev="$_clean"
  _fgc_clean "$_pkg"; _pkg="$_clean"
  _fgc_clean "$_act"; _act="$_clean"
  _fgc_clean "$_res"; _res="$_clean"
  _fgc_clean "$_err"; _err="$_clean"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_ts" "$_ev" "$_pkg" "$_act" "$_res" "$_err" >> "$FGC_LOGDIR/session.log"
}

fgc_state_write() {
  # $1 = json string (already validated by caller), atomic write via tmp+rename
  mkdir -p "$FGC_STATEDIR"
  printf '%s' "$1" > "$FGC_STATEDIR/session.json.tmp" && mv "$FGC_STATEDIR/session.json.tmp" "$FGC_STATEDIR/session.json"
}
