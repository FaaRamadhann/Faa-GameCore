#!/system/bin/sh
# config_manager.sh — single source of truth for config. Get/set via fgc-cli only.
# Sourced, not executed. Static code only; JSON edits done with grep/sed on known keys only.
#
# config.json is stored PRETTY (one key per line, 4-space indent) so a user can
# read or hand-edit it without a JSON formatter:
#   {
#       "enabled": true,
#       ...
#       "auto_profile_rules": {
#           "note": "...",
#           "game_foreground": 2,
#           "idle": 1
#       }
#   }
# Readers are layout-tolerant (every key sits on its own line, so the
# line-oriented grep/sed below keeps working for both the pretty form and the
# older single-line form); fgc_cfg_normalize upgrades an old file once.
FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"
. "${FGC_MODDIR}/core/paths.sh"

fgc_cfg_get() {
  # $1 = key ; $2 = optional file (default $FGC_CONFIG/config.json)
  # prints the raw value; works for single-line and pretty layouts alike.
  _k="$1"; _f="${2:-$FGC_CONFIG/config.json}"
  case "$_k" in
    enabled|detection_mode|poll_interval_sec|default_profile|cleanup_policy|logging|dry_run|freeze_system) ;;
    *) return 1 ;;
  esac
  grep -o "\"$_k\"[ ]*:[ ]*[^,}]*" "$_f" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d ' "'
}

fgc_cfg_nested() {
  # $1 = key inside "auto_profile_rules" (note|game_foreground|idle)
  # $2 = optional file (default $FGC_CONFIG/config.json)
  # Strings come back JSON-ESCAPED exactly as stored (never re-escaped later).
  case "$1" in note|game_foreground|idle) ;; *) return 1 ;; esac
  _nf="${2:-$FGC_CONFIG/config.json}"
  _no="$(tr -d '\n\r' < "$_nf" 2>/dev/null)"
  case "$1" in
    note)
      printf '%s' "$_no" | sed -n 's/.*"note"[ ]*:[ ]*"\([^}]*\)"[ ]*[,}].*/\1/p' | head -n 1 ;;
    *)
      printf '%s' "$_no" | sed -n "s/.*\"$1\"[ ]*:[ ]*\([0-9][0-9]*\).*/\1/p" | head -n 1 ;;
  esac
}

fgc_cfg_set() {
  # $1 = key, $2 = value (validated). Returns 0 on success.
  # Rewrites ONLY the matching key's line: the pretty layout (and any key a
  # future version adds) survives untouched.
  _k="$1"; _v="$2"; _f="$FGC_CONFIG/config.json"; _t="$_f.tmp"
  case "$_k" in
    enabled|logging|dry_run|freeze_system)
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

fgc_cfg_pretty() {
  # Prints the canonical pretty config document built from the CURRENT values.
  # Missing/invalid values fall back to the shipped default, so this doubles as
  # the one place that documents the schema and its defaults.
  # (_cf_* locals: fgc_cfg_get overwrites plain names like _f/_k.)
  _cf_en="$(fgc_cfg_get enabled 2>/dev/null)"; case "$_cf_en" in true|false) ;; *) _cf_en=true ;; esac
  _cf_dm="$(fgc_cfg_get detection_mode 2>/dev/null)"; case "$_cf_dm" in foreground|gamelist|hybrid) ;; *) _cf_dm=hybrid ;; esac
  _cf_pi="$(fgc_cfg_get poll_interval_sec 2>/dev/null)"; case "$_cf_pi" in ''|*[!0-9]*) _cf_pi=3 ;; esac
  { [ "$_cf_pi" -ge 2 ] && [ "$_cf_pi" -le 60 ]; } 2>/dev/null || _cf_pi=3
  _cf_dp="$(fgc_cfg_get default_profile 2>/dev/null)"; case "$_cf_dp" in 1|2|3|4) ;; *) _cf_dp=1 ;; esac
  _cf_cp="$(fgc_cfg_get cleanup_policy 2>/dev/null)"; case "$_cf_cp" in conservative|balanced|aggressive) ;; *) _cf_cp=balanced ;; esac
  _cf_lg="$(fgc_cfg_get logging 2>/dev/null)"; case "$_cf_lg" in true|false) ;; *) _cf_lg=true ;; esac
  _cf_dr="$(fgc_cfg_get dry_run 2>/dev/null)"; case "$_cf_dr" in true|false) ;; *) _cf_dr=false ;; esac
  _cf_fs="$(fgc_cfg_get freeze_system 2>/dev/null)"; case "$_cf_fs" in true|false) ;; *) _cf_fs=false ;; esac
  _cf_nt="$(fgc_cfg_nested note 2>/dev/null | tr -d '\t\n\r')"
  [ -n "$_cf_nt" ] || _cf_nt='Auto picks Performance when a listed game is foreground, else Balance. No AI claims.'
  _cf_gf="$(fgc_cfg_nested game_foreground 2>/dev/null)"; case "$_cf_gf" in 0|1|2|3|4) ;; *) _cf_gf=2 ;; esac
  _cf_idl="$(fgc_cfg_nested idle 2>/dev/null)"; case "$_cf_idl" in 0|1|2|3|4) ;; *) _cf_idl=1 ;; esac
  printf '{\n'
  printf '    "enabled": %s,\n' "$_cf_en"
  printf '    "detection_mode": "%s",\n' "$_cf_dm"
  printf '    "poll_interval_sec": %s,\n' "$_cf_pi"
  printf '    "default_profile": %s,\n' "$_cf_dp"
  printf '    "cleanup_policy": "%s",\n' "$_cf_cp"
  printf '    "logging": %s,\n' "$_cf_lg"
  printf '    "dry_run": %s,\n' "$_cf_dr"
  printf '    "freeze_system": %s,\n' "$_cf_fs"
  printf '    "auto_profile_rules": {\n'
  printf '        "note": "%s",\n' "$_cf_nt"
  printf '        "game_foreground": %s,\n' "$_cf_gf"
  printf '        "idle": %s\n' "$_cf_idl"
  printf '    }\n'
  printf '}\n'
}

fgc_cfg_normalize() {
  # $1 = config.json (default $FGC_CONFIG/config.json)
  # Upgrades the file to the canonical PRETTY layout — once — and returns 0.
  # Data-preserving by construction:
  #   * an unknown key means "a human or a newer build put something here", so
  #     the file is left EXACTLY as it is (we never drop what we don't know);
  #   * the candidate is written to a temp file, EVERY value is read back out of
  #     it and compared against the original, and only then is it renamed over
  #     the original. A mismatch leaves the original byte-identical.
  _cf_f="${1:-$FGC_CONFIG/config.json}"
  [ -f "$_cf_f" ] || return 1
  _cf_keys="$(grep -o '"[a-z_][a-z_]*"[ ]*:' "$_cf_f" 2>/dev/null | tr -d ' ')"
  for _cf_k in $_cf_keys; do
    case "$_cf_k" in
      '"enabled":'|'"detection_mode":'|'"poll_interval_sec":'|'"default_profile":'|\
      '"cleanup_policy":'|'"logging":'|'"dry_run":'|'"freeze_system":'|\
      '"auto_profile_rules":'|'"note":'|'"game_foreground":'|'"idle":') ;;
      *) return 1 ;;
    esac
  done
  _cf_cur="$(cat "$_cf_f" 2>/dev/null)"
  _cf_new="$(fgc_cfg_pretty)"
  [ -n "$_cf_new" ] || return 1
  [ "$_cf_cur" = "$_cf_new" ] && return 0
  printf '%s\n' "$_cf_new" > "$_cf_f.tmp" 2>/dev/null || { rm -f "$_cf_f.tmp" 2>/dev/null; return 1; }
  _cf_ok=1
  _cf_gaps=0
  for _cf_k in enabled detection_mode poll_interval_sec default_profile cleanup_policy logging dry_run freeze_system; do
    _cf_a="$(fgc_cfg_get "$_cf_k" "$_cf_f" 2>/dev/null)"
    if [ -z "$_cf_a" ]; then _cf_gaps=1; continue; fi   # absent: default is intended
    [ "$_cf_a" = "$(fgc_cfg_get "$_cf_k" "$_cf_f.tmp" 2>/dev/null)" ] || { _cf_ok=0; break; }
  done
  if [ "$_cf_ok" = "1" ]; then
    for _cf_k in note game_foreground idle; do
      _cf_a="$(fgc_cfg_nested "$_cf_k" "$_cf_f" 2>/dev/null)"
      if [ -z "$_cf_a" ]; then _cf_gaps=1; continue; fi
      [ "$_cf_a" = "$(fgc_cfg_nested "$_cf_k" "$_cf_f.tmp" 2>/dev/null)" ] || { _cf_ok=0; break; }
    done
  fi
  if [ "$_cf_ok" != "1" ]; then rm -f "$_cf_f.tmp" 2>/dev/null; return 1; fi
  # A gap means the original was unreadable/incomplete: this is a REPAIR, not a
  # reformat, so keep a backup of what was there (same rule as every other
  # rescue in this module).
  [ "$_cf_gaps" = "1" ] && cp "$_cf_f" "$_cf_f.bak" 2>/dev/null
  mv "$_cf_f.tmp" "$_cf_f" 2>/dev/null || { rm -f "$_cf_f.tmp" 2>/dev/null; return 1; }
  return 0
}
