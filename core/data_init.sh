#!/system/bin/sh
# data_init.sh — persistent user data at $FGC_DATA (default /data/adb/fgc).
# Magisk wipes $MODDIR on every module update; user data must survive that.
# FAACC-style: real files live ONLY in $FGC_DATA/{config,state,logs} and the
# core addresses them by ABSOLUTE canonical paths (core/paths.sh). The module
# dir carries plain shipped defaults and is NEVER linked, symlinked, or
# written by the core — so updates cannot touch user data, by construction.
# Write discipline (this device flakes stat() during mount churn):
#   - seed/import ONLY after a path is readdir-missing TWICE in a row;
#   - migrate retries before any rescue; rescue always backups first;
#   - user files are never overwritten, moved, or appended-to blindly.
# Sourced or executed. Needs only POSIX sh + cp/mkdir/rm/grep/sed/sleep.

FGC_DATA="${FGC_DATA:-/data/adb/fgc}"
FGC_SCHEMA=1

_mfile() {
  # readdir-based existence (see system/bin/fgc): stat() on module paths can
  # flake during Magisk mount churn while readdir keeps working.
  [ -n "$1" ] || return 1
  ls "${1%/*}" 2>/dev/null | grep -qx "${1##*/}"
}

_dmissing() {
  # True only if readdir misses the path TWICE: a single miss may be a
  # transient flake, and seeding over a flake would DESTROY user data.
  [ -n "$1" ] || return 1
  _mp="$1"
  ls "${_mp%/*}" 2>/dev/null | grep -qx "${_mp##*/}" && return 1
  sleep 1
  ls "${_mp%/*}" 2>/dev/null | grep -qx "${_mp##*/}" && return 1
  return 0
}

fgc_migrate_keys() {
  # $1 = config.json — backfill keys added by newer releases (missing only).
  # Retried: a single failed read must never trigger a rescue-reseed.
  # Returns 1 when keys are STILL missing afterwards (corrupt file) so the
  # caller can rescue instead of silently keeping garbage.
  _mf="$1"
  _try=0
  while [ "$_try" -lt 3 ]; do
    if [ -f "$_mf" ]; then
      _alt() {
        # One key per line (POSIX grep -o with -e list; NO \| alternation:
        # toybox grep lacks it and fails SILENTLY, which once caused endless
        # duplicate-key appends + false corrupt-rescues on-device).
        grep -o -e '"enabled"' -e '"detection_mode"' -e '"poll_interval_sec"' \
          -e '"default_profile"' -e '"cleanup_policy"' -e '"logging"' \
          -e '"dry_run"' -e '"freeze_system"' -e '"auto_profile_rules"' "$_mf" 2>/dev/null | sort -u
      }
      _all_present() {
        _have="$(_alt)"
        for _k in enabled detection_mode poll_interval_sec default_profile cleanup_policy logging dry_run freeze_system auto_profile_rules; do
          case "$_have" in *"\"$_k\""*) ;; *) return 1 ;; esac
        done
        return 0
      }
      _all_present && return 0
      _add_key() {
        # $1=key $2=default-json
        _esc="$(printf '%s' "$2" | sed 's/[&\\]/\\&/g')"
        _one="$(tr -d '\n\r' < "$_mf" 2>/dev/null)"
        printf '%s' "$_one" | sed "s/[[:space:]]*}[[:space:]]*\$/,\"$1\": $_esc}/" > "$_mf.tmp" 2>/dev/null || return 1
        mv "$_mf.tmp" "$_mf" 2>/dev/null || return 1
      }
      _add_key enabled true
      _add_key detection_mode '"hybrid"'
      _add_key poll_interval_sec 3
      _add_key default_profile 1
      _add_key cleanup_policy '"balanced"'
      _add_key logging true
      _add_key dry_run false
      _add_key freeze_system false
      _add_key auto_profile_rules '{"note":"Auto picks Performance when a listed game is foreground, else Balance. No AI claims.","game_foreground":2,"idle":1}'
      _all_present && return 0
    fi
    _try=$((_try+1)); sleep 1
  done
  return 1
}

fgc_data_init() {
  # $1 = new module dir, $2 = old module dir (update imports; empty on boot)
  _new="${1:-$FGC_MODDIR}"; _old="$2"
  [ -n "$_new" ] || return 1
  mkdir -p "$FGC_DATA/config" "$FGC_DATA/state" "$FGC_DATA/logs" || return 1
  # 1. import previous storage, then shipped seeds — genuinely-missing ONLY
  for _f in config.json gamelist.json blacklist.txt whitelist.txt; do
    if _dmissing "$FGC_DATA/config/$_f"; then
      if [ -n "$_old" ] && [ "$_old" != "$_new" ] && _mfile "$_old/config/$_f"; then
        cp "$_old/config/$_f" "$FGC_DATA/config/$_f" 2>/dev/null
      fi
      if _dmissing "$FGC_DATA/config/$_f" && [ ! -L "$_new/config" ] && _mfile "$_new/config/$_f"; then
        cp "$_new/config/$_f" "$FGC_DATA/config/$_f" 2>/dev/null || true
      fi
    fi
  done
  # old session log = history worth keeping (copy once, never merge/overwrite)
  if _dmissing "$FGC_DATA/logs/session.log" && [ -n "$_old" ] && [ "$_old" != "$_new" ] && _mfile "$_old/logs/session.log"; then
    cp "$_old/logs/session.log" "$FGC_DATA/logs/session.log" 2>/dev/null || true
  fi
  # 2. schema: backfill keys added by newer releases; rescue corrupt files
  if [ -f "$FGC_DATA/config/config.json" ]; then
    fgc_migrate_keys "$FGC_DATA/config/config.json" \
    || {
      cp "$FGC_DATA/config/config.json" "$FGC_DATA/config/config.json.bak" 2>/dev/null
      # embedded defaults (= shipped config/config.json): never sourced from
      # any live dir, so a half-written tree cannot poison the reseed.
      printf '%s' '{"enabled":true,"detection_mode":"hybrid","poll_interval_sec":3,"default_profile":1,"cleanup_policy":"balanced","logging":true,"dry_run":false,"freeze_system":false,"auto_profile_rules":{"note":"Auto picks Performance when a listed game is foreground, else Balance. No AI claims.","game_foreground":2,"idle":1}}' \
        > "$FGC_DATA/config/config.json" 2>/dev/null || true
    }
  fi
  printf '%s' "$FGC_SCHEMA" > "$FGC_DATA/.schema" 2>/dev/null
  # 3. module dirs stay PLAIN shipped defaults (never symlinked, never
  # absorbed). Remove stray symlinks left by very old FGC versions so a
  # dirty tree can never shadow or divert the canonical data paths.
  for _d in config state logs; do
    if [ -L "$_new/$_d" ]; then
      rm -f "$_new/$_d" 2>/dev/null
    fi
    mkdir -p "$_new/$_d" 2>/dev/null
  done
}
case "$0" in *data_init.sh) fgc_data_init "$FGC_MODDIR" "$2" ;; esac
