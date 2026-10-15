#!/system/bin/sh
# data_init.sh — persistent user data at $FGC_DATA (default /data/adb/fgc).
# Magisk wipes $MODDIR on every module update; user data must survive that.
# Strategy: real files live in $FGC_DATA/{config,state,logs}; the module dir
# only carries symlinks, so ALL existing core paths keep working unchanged.
# Guarantees: never overwrites existing user files; imports previous
# module-dir storage (pre-persistence versions); backfills config keys
# added by newer releases; stale session locks are never migrated.
# Sourced or executed. Needs only POSIX sh + cp/mkdir/ln/rm/grep/sed.

FGC_DATA="${FGC_DATA:-/data/adb/fgc}"
FGC_SCHEMA=1

_mfile() {
  # readdir-based existence (see system/bin/fgc): stat() on module paths can
  # flake during Magisk mount churn while readdir keeps working.
  [ -n "$1" ] || return 1
  ls "${1%/*}" 2>/dev/null | grep -qx "${1##*/}"
}

fgc_migrate_keys() {
  # $1 = config.json — backfill keys added by newer releases (missing only).
  # Single grep in the common case (nothing missing): minimal forks.
  # Returns 1 when keys are STILL missing afterwards (corrupt file) so the
  # caller can rescue instead of silently keeping garbage.
  _mf="$1"
  [ -f "$_mf" ] || return 1
  _alt='"enabled"\|"detection_mode"\|"poll_interval_sec"\|"default_profile"\|"cleanup_policy"\|"logging"\|"dry_run"\|"auto_profile_rules"'
  _all_present() {
    _have="$(grep -o "$_alt" "$_mf" 2>/dev/null | sort -u)"
    for _k in enabled detection_mode poll_interval_sec default_profile cleanup_policy logging dry_run auto_profile_rules; do
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
  _add_key auto_profile_rules '{"note":"Auto picks Performance when a listed game is foreground, else Balance. No AI claims.","game_foreground":2,"idle":1}'
  _all_present
}

fgc_data_init() {
  # $1 = new module dir, $2 = old module dir (update imports; empty on boot)
  _new="${1:-$FGC_MODDIR}"; _old="$2"
  [ -n "$_new" ] || return 1
  mkdir -p "$FGC_DATA/config" "$FGC_DATA/state" "$FGC_DATA/logs" || return 1
  # 1. import previous storage, then shipped seeds — missing files ONLY
  for _f in config.json gamelist.json blacklist.txt whitelist.txt; do
    if [ ! -f "$FGC_DATA/config/$_f" ]; then
      if [ -n "$_old" ] && [ "$_old" != "$_new" ] && _mfile "$_old/config/$_f"; then
        cp "$_old/config/$_f" "$FGC_DATA/config/$_f" 2>/dev/null
      fi
      if [ ! -f "$FGC_DATA/config/$_f" ] && [ ! -L "$_new/config" ] && _mfile "$_new/config/$_f"; then
        cp "$_new/config/$_f" "$FGC_DATA/config/$_f" 2>/dev/null || true
      fi
    fi
  done
  # old session log = history worth keeping (copy once, never merge/overwrite)
  if [ ! -f "$FGC_DATA/logs/session.log" ] && [ -n "$_old" ] && [ "$_old" != "$_new" ] && _mfile "$_old/logs/session.log"; then
    cp "$_old/logs/session.log" "$FGC_DATA/logs/session.log" 2>/dev/null || true
  fi
  # 2. schema: backfill keys added by newer releases; rescue corrupt files
  if [ -f "$FGC_DATA/config/config.json" ]; then
    fgc_migrate_keys "$FGC_DATA/config/config.json" \
    || {
      cp "$FGC_DATA/config/config.json" "$FGC_DATA/config/config.json.bak" 2>/dev/null
      # embedded defaults (= shipped config/config.json): the module dir may
      # already be a symlink to this very file, so it cannot serve as seed
      printf '%s' '{"enabled":true,"detection_mode":"hybrid","poll_interval_sec":3,"default_profile":1,"cleanup_policy":"balanced","logging":true,"dry_run":false,"auto_profile_rules":{"note":"Auto picks Performance when a listed game is foreground, else Balance. No AI claims.","game_foreground":2,"idle":1}}' \
        > "$FGC_DATA/config/config.json" 2>/dev/null || true
    }
  fi
  printf '%s' "$FGC_SCHEMA" > "$FGC_DATA/.schema" 2>/dev/null
  # 3. link module dirs -> data (idempotent; real dirs absorbed first)
  for _d in config state logs; do
    if [ -L "$_new/$_d" ]; then
      if [ "$(readlink "$_new/$_d" 2>/dev/null)" = "$FGC_DATA/$_d" ]; then continue; fi
      rm -f "$_new/$_d"
    elif [ -d "$_new/$_d" ]; then
      # absorb: copy anything still missing (paranoid; step 1 normally covered it)
      if [ "$_d" = "logs" ] && [ -f "$_new/$_d/session.log" ]; then
        if [ ! -f "$FGC_DATA/$_d/session.log" ]; then
          mv "$_new/$_d/session.log" "$FGC_DATA/$_d/session.log" 2>/dev/null || true
        else
          cat "$_new/$_d/session.log" >> "$FGC_DATA/$_d/session.log" 2>/dev/null || true
        fi
      else
        for _af in "$_new/$_d"/*; do
          [ -f "$_af" ] || continue
          _bn="${_af##*/}"
          [ -f "$FGC_DATA/$_d/$_bn" ] || mv "$_af" "$FGC_DATA/$_d/$_bn" 2>/dev/null || true
        done
      fi
      rm -rf "$_new/$_d"
    fi
    ln -s "$FGC_DATA/$_d" "$_new/$_d" 2>/dev/null || return 1
  done
  # verify: a non-symlink here (e.g. copy-fallback runtimes) would silently
  # diverge user data — fail loudly instead
  for _d in config state logs; do
    [ -L "$_new/$_d" ] || return 1
  done
}
case "$0" in *data_init.sh) fgc_data_init "$FGC_MODDIR" "$2" ;; esac
