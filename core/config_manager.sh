#!/system/bin/sh
# config_manager.sh — single source of truth for config. Get/set via fgc-cli only.
# Sourced, not executed. Static code only; JSON edits done with grep/sed on known keys only.
FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"

fgc_cfg_get() {
  # $1 = key ; prints raw value
  _k="$1"; _f="$FGC_CONFIG/config.json"
  case "$_k" in
    enabled|detection_mode|poll_interval_sec|default_profile|cleanup_policy|logging|dry_run) ;;
    *) return 1 ;;
  esac
  grep -o "\"$_k\"[ ]*:[ ]*[^,}]*" "$_f" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d ' "'
}

fgc_cfg_set() {
  # $1 = key, $2 = value (validated). Returns 0 on success.
  _k="$1"; _v="$2"; _f="$FGC_CONFIG/config.json"; _t="$_f.tmp"
  case "$_k" in
    enabled|logging|dry_run)
      case "$_v" in true|false) ;; *) echo "invalid boolean" >&2; return 1 ;; esac ;;
    detection_mode)
      case "$_v" in foreground|gamelist|hybrid) ;; *) echo "invalid mode" >&2; return 1 ;; esac ;;
    cleanup_policy)
      case "$_v" in conservative|balanced|aggressive) ;; *) echo "invalid policy" >&2; return 1 ;; esac ;;
    poll_interval_sec)
      case "$_v" in *[!0-9]*) echo "invalid interval" >&2; return 1 ;; *) ;;
      esac
      [ "$_v" -ge 2 ] 2>/dev/null || { echo "interval min 2" >&2; return 1; }
      [ "$_v" -le 60 ] 2>/dev/null || { echo "interval max 60" >&2; return 1; } ;;
    default_profile)
      case "$_v" in 1|2|3|4) ;; *) echo "invalid profile" >&2; return 1 ;; esac ;;
    *) echo "unknown key" >&2; return 1 ;;
  esac
  # Replace "key": old -> "key": new (numbers/bools unquoted, strings quoted)
  case "$_k" in
    detection_mode|cleanup_policy) _nv="\"$_v\"" ;;
    *) _nv="$_v" ;;
  esac
  sed "s/\"$_k\"[ ]*:[ ]*[^,}]*/\"$_k\": $_nv/" "$_f" > "$_t" 2>/dev/null || return 1
  # sanity: file still has all required keys
  for _rk in enabled detection_mode poll_interval_sec default_profile cleanup_policy logging dry_run; do
    grep -q "\"$_rk\"" "$_t" || return 1
  done
  mv "$_t" "$_f"
}
