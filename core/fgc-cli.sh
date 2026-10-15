#!/system/bin/sh
# fgc-cli.sh — Backend Interface for WebUI adapter + manual shell use.
# Every command prints JSON to stdout, exit 0 on success. Static code, no arbitrary shell.
# Usage: fgc-cli.sh <cmd> [args...]
MODDIR="${FGC_MODDIR:-${0%/*}/..}"
export FGC_MODDIR="$MODDIR"
CORE_DIR="$MODDIR/core"
. "$CORE_DIR/paths.sh"
. "$CORE_DIR/config_manager.sh"
. "$CORE_DIR/logger.sh"
. "$CORE_DIR/policy_engine.sh"
. "$CORE_DIR/device.sh"
. "$CORE_DIR/caps.sh"

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }

# Java helper (tools/java/FgcPm.java -> bin/fgc-pm.dex): real PackageManager
# labels/icons on every ROM. Absent/unrunnable -> pm/dumpsys fallback.
FGC_DEX="$MODDIR/bin/fgc-pm.dex"
fgc_java() {
  [ -f "$FGC_DEX" ] || return 1
  command -v app_process >/dev/null 2>&1 || return 1
  app_process -Djava.class.path="$FGC_DEX" /system/bin FgcPm "$@" 2>/dev/null
}

_fgc_pick_label() {
  # $1 = dumpsys output file; prints app label or empty (exit 1).
  # Tolerant across ROM dumpsys formats; pure shell, no pipe chains.
  _raw="$(grep -m1 'application-label' "$1" 2>/dev/null)"
  [ -z "$_raw" ] && _raw="$(grep -i -m1 'label' "$1" 2>/dev/null)"
  [ -z "$_raw" ] && return 1
  _v="${_raw#*:}"
  [ "$_v" = "$_raw" ] && _v="${_raw#*=}"
  while :; do case "$_v" in ' '*) _v="${_v#?}" ;; *) break ;; esac; done
  while :; do case "$_v" in *' ') _v="${_v%?}" ;; *) break ;; esac; done
  case "$_v" in \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;; \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;; esac
  case "$_v" in *'/'*) return 1 ;; esac
  [ -n "$_v" ] || return 1
  printf '%s' "$_v"
}

cmd_status() {
  _en="$(fgc_cfg_get enabled)"; _dp="$(fgc_cfg_get default_profile)"
  _run="false"; [ -d "$FGC_STATE/daemon.lock" ] && _run="true"
  _boot="$(getprop sys.boot_completed 2>/dev/null)"
  # Honest core states (never hardcoded PID, never stale PID file):
  #   DISABLED = master switch off
  #   ACTIVE   = daemon lock held (daemon alive; game session reported separately)
  #   STARTING = enabled, boot not finished yet, daemon not up
  #   ERROR    = enabled, boot done, daemon down, recent CORE_ERROR logged
  #   STOPPED  = enabled, boot done, daemon down, no recent error
  _core="STOPPED"
  if [ "$_en" = "false" ]; then _core="DISABLED"
  elif [ "$_run" = "true" ]; then _core="ACTIVE"
  elif [ "$_boot" != "1" ]; then _core="STARTING"
  elif tail -n 20 "$FGC_LOGS/session.log" 2>/dev/null | grep -q 'CORE_ERROR'; then _core="ERROR"
  fi
  _game=""; _started=""; _prof="$_dp"; _lc=""
  _sj="$(cat "$FGC_STATE/session.json" 2>/dev/null)"
  [ -f "$FGC_STATE/session.lock" ] && _game="$(cat "$FGC_STATE/session.lock" 2>/dev/null)"
  _lc="$(printf '%s' "$_sj" | grep -o '"last_cleanup"[ ]*:[ ]*"[^"]*"' | cut -d'"' -f4)"
  _ver="$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
  _dev="$(fgc_device_json 2>/dev/null)"; [ -n "$_dev" ] || _dev='{"manufacturer":"Unknown","model":"Unknown","android":"Unknown","sdk":"Unknown","root":"Not detected"}'
  printf '{"core":"%s","daemon_running":%s,"enabled":%s,"game":"%s","profile":%s,"last_cleanup":"%s","version":"%s","device":%s}\n' \
    "$_core" "$_run" "$([ "$_en" = "false" ] && echo false || echo true)" "$(jesc "$_game")" "${_prof:-1}" "$(jesc "$_lc")" "$(jesc "$_ver")" "$_dev"
}

cmd_list() { # list [games|blacklist|whitelist|logs|packages] (bare = games)
  [ -z "$1" ] && set -- games
  case "$1" in
    games) cat "$FGC_CONFIG/gamelist.json" 2>/dev/null || echo '{"error":"gamelist-missing"}' ;;
    blacklist) fgc_each_all "$FGC_CONFIG/blacklist.txt" ;;
    whitelist) fgc_each_all "$FGC_CONFIG/whitelist.txt" ;;
    logs) tail -n 100 "$FGC_LOGS/session.log" 2>/dev/null || true ;;
    packages)
      # list packages [all|user|system] -> pkg<TAB>label<TAB>user|system (real pm data)
      _which="${2:-all}"
      # fast path: Java PackageManager helper (single shot, correct labels)
      _jl="$FGC_STATE/.javapkgs"
      _tab="$(printf '\t')"
      if fgc_java list > "$_jl" 2>/dev/null; then
        _head="$(head -n 1 "$_jl" 2>/dev/null)"
        case "$_head" in *"$_tab"*)
          if [ "$_which" = "all" ]; then cat "$_jl"
          else
            while IFS= read -r _pl || [ -n "$_pl" ]; do
              case "$_pl" in *"$_tab$_which") printf '%s\n' "$_pl" ;; esac
            done < "$_jl"
          fi
          rm -f "$_jl"
          return 0 ;;
        esac
      fi
      rm -f "$_jl"
      _sysf="$FGC_STATE/.syspkgs"
      pm list packages -s 2>/dev/null | sed 's/^package://' | sort -u > "$_sysf" 2>/dev/null
      pm list packages 2>/dev/null | sed 's/^package://' | sort -u | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if grep -qx "$p" "$_sysf" 2>/dev/null; then _t=system; else _t=user; fi
        case "$_which" in all) ;; "$_t") ;; *) continue ;; esac
        _l=""
        if dumpsys package "$p" > "$FGC_STATE/.pkgout" 2>/dev/null; then
          _l="$(_fgc_pick_label "$FGC_STATE/.pkgout" 2>/dev/null)" || _l=""
        fi
        rm -f "$FGC_STATE/.pkgout"
        [ -z "$_l" ] && _l="$p"
        printf '%s\t%s\t%s\n' "$p" "$_l" "$_t"
      done
      rm -f "$_sysf"
      ;;
    *) echo '{"error":"unknown list"}' >&2; return 1 ;;
  esac
}

valid_pkg() { # exact package chars only
  case "$1" in ''|*[!a-zA-Z0-9._]*) return 1 ;; *) return 0 ;; esac
}

cmd_add() { # add <games|blacklist|whitelist> <package> [label...] [profile]
  _t="$1"; _p="$2"
  valid_pkg "$_p" || { echo '{"error":"invalid package"}'; return 1; }
  # Label may contain spaces (it arrives as separate shell words): the profile
  # is always the LAST arg, everything between package and profile is label.
  # Static code only, pure shift loop.
  _prof=0; _label=""
  shift 2
  if [ $# -eq 0 ]; then _label="$_p"
  elif [ $# -eq 1 ]; then
    case "$1" in ''|*[!0-9]*) _label="$1" ;; *) _label="$_p"; _prof="$1" ;; esac
  else
    while [ $# -gt 1 ]; do _label="${_label}${_label:+ }$1"; shift; done
    case "${1:-0}" in ''|*[!0-9]*) _prof=0 ;; *) _prof="$1" ;; esac
  fi
  [ -z "$_label" ] && _label="$_p"
  case "$_t" in
    games)
      grep -q "\"$_p\"" "$FGC_CONFIG/gamelist.json" 2>/dev/null && { echo '{"error":"duplicate"}'; return 1; }
      _l="$(jesc "$_label")"
      python3 - "$FGC_CONFIG/gamelist.json" "$_p" "$_l" "$_prof" 2>/dev/null <<'EOF' || {
import json,sys
f,pkg,label,prof=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
try: d=json.load(open(f))
except: d={"games":[]}
d.setdefault("games",[]).append({"package":pkg,"label":label,"profile":int(prof or 0)})
json.dump(d,open(f,"w"),indent=1)
EOF
        # fallback without python (on-device: python3 never exists, THIS is the
        # real path): append into the games array, empty or not. Normalized to
        # single-line first so pretty-printed files work too.
        _tmp="$FGC_CONFIG/gamelist.json.tmp"
        _esc="$(printf '%s' "$_l" | sed 's/[\/&|\\]/\\&/g')"
        _one="$(tr -d '\n\r' < "$FGC_CONFIG/gamelist.json" 2>/dev/null)"
        _new='{"package": "'$_p'", "label": "'$_esc'", "profile": '${_prof:-0}'}'
        if printf '%s' "$_one" | grep -q '"games"[ ]*:[ ]*\[[ ]*\]'; then
          printf '%s' "$_one" | sed "s/\"games\"[ ]*:[ ]*\[[ ]*\]/\"games\": [$_new]/" > "$_tmp" && mv "$_tmp" "$FGC_CONFIG/gamelist.json" || { echo '{"error":"add-failed"}'; return 1; }
        elif printf '%s' "$_one" | grep -q '"games"'; then
          printf '%s' "$_one" | sed "s/\(.*\)\]}[[:space:]]*\$/\1, $_new]}/" > "$_tmp" && mv "$_tmp" "$FGC_CONFIG/gamelist.json" || { echo '{"error":"add-failed"}'; return 1; }
        else
          echo '{"error":"add-failed"}'; return 1
        fi
      }
      fgc_log "SESSION_STARTED" "$_p" "gamelist-add" "added" ""
      echo '{"ok":true}' ;;
    blacklist|whitelist)
      _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
      grep -qx "$_p" "$_f" 2>/dev/null && { echo '{"error":"duplicate"}'; return 1; }
      # remove disabled twin line then append
      grep -v "^$_p$" "$_f" 2>/dev/null | grep -v "^!$_p$" > "$_f.tmp"; mv "$_f.tmp" "$_f"
      printf '%s\n' "$_p" >> "$_f"
      echo '{"ok":true}' ;;
    *) echo '{"error":"unknown target"}'; return 1 ;;
  esac
}

cmd_remove() { # remove <games|blacklist|whitelist> <package>
  _t="$1"; _p="$2"
  valid_pkg "$_p" || { echo '{"error":"invalid package"}'; return 1; }
  case "$_t" in
    games)
      python3 - "$FGC_CONFIG/gamelist.json" "$_p" 2>/dev/null <<'EOF' || {
import json,sys
f,pkg=sys.argv[1],sys.argv[2]
d=json.load(open(f)); d["games"]=[g for g in d.get("games",[]) if g.get("package")!=pkg]
json.dump(d,open(f,"w"),indent=1)
EOF
        # fallback without python: exact-object surgery (line-based delete
        # would nuke the whole file when JSON is single-line). Normalized
        # first; removes the object with optional trailing comma, then
        # collapses a leftover ", ]".
        _gf="$FGC_CONFIG/gamelist.json"
        _one="$(tr -d '\n\r' < "$_gf" 2>/dev/null)"
        _re="$(printf '%s' "$_p" | sed 's/\./\\./g')"
        printf '%s' "$_one" | sed "s/{\"package\": \"$_re\"[^}]*\}\(, *\)\{0,1\}//; s/, *\]/]/" > "$_gf.tmp" 2>/dev/null \
          && grep -q '"games"' "$_gf.tmp" 2>/dev/null \
          && mv "$_gf.tmp" "$_gf" || { rm -f "$_gf.tmp"; echo '{"error":"remove-failed"}'; return 1; }
      }
      echo '{"ok":true}' ;;
    blacklist|whitelist)
      _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
      grep -v "^$_p$" "$_f" 2>/dev/null > "$_f.tmp"; mv "$_f.tmp" "$_f"
      echo '{"ok":true}' ;;
    *) echo '{"error":"unknown target"}'; return 1 ;;
  esac
}

cmd_toggle() { # toggle <blacklist|whitelist> <package> on|off  (off = prefix !)
  _t="$1"; _p="$2"; _s="$3"
  valid_pkg "$_p" || return 1
  _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
  grep -v "^$_p$" "$_f" 2>/dev/null | grep -v "^!$_p$" > "$_f.tmp"; mv "$_f.tmp" "$_f"
  if [ "$_s" = "on" ]; then printf '%s\n' "$_p" >> "$_f"; else printf '!%s\n' "$_p" >> "$_f"; fi
  echo '{"ok":true}'
}

cmd_set() { # set <key> <value> | set profile <1..4> [package]
  if [ "$1" = "profile" ]; then
    _pv="$2"; _pkg="$3"
    case "$_pv" in 1|2|3|4) ;; *) echo '{"error":"invalid profile"}'; return 1 ;; esac
    if [ -n "$_pkg" ]; then
      valid_pkg "$_pkg" || return 1
      python3 - "$FGC_CONFIG/gamelist.json" "$_pkg" "$_pv" 2>/dev/null <<'EOF' || return 1
import json,sys
f,pkg,pv=sys.argv[1],sys.argv[2],int(sys.argv[3])
d=json.load(open(f))
for g in d.get("games",[]):
  if g.get("package")==pkg: g["profile"]=pv
json.dump(d,open(f,"w"),indent=1)
EOF
      echo '{"ok":true}'
    else
      fgc_cfg_set default_profile "$_pv" && echo '{"ok":true}' || echo '{"error":"set-failed"}'
    fi
  else
    fgc_cfg_set "$1" "$2" && echo '{"ok":true}' || echo '{"error":"set-failed"}'
  fi
}

cmd_session() {
  # Companion-trigger interface (Zygisk/LSPosed/Tasker): explicit session control.
  # session-start only accepts REGISTERED games; session-end always safe (lock rm).
  # Usage: cmd_session session-start <pkg> | session-end
  . "$CORE_DIR/session_controller.sh"
  case "$1" in
    session-start)
      valid_pkg "$2" || { echo '{"error":"invalid package"}'; return 1; }
      grep -q "\"package\"[ ]*:[ ]*\"$2\"" "$FGC_CONFIG/gamelist.json" 2>/dev/null \
        || { echo '{"error":"not-a-game"}'; return 1; }
      FGC_GAME="$2" fgc_session_start "$2" && echo '{"ok":true}' ;;
    session-end)
      fgc_session_end && echo '{"ok":true}' ;;
    *) echo '{"error":"unknown session cmd"}'; return 1 ;;
  esac
}

cmd_icon() {
  # icon <pkg> -> base64 PNG (144px) on stdout. Disk-cached under state/icons.
  valid_pkg "$1" || { echo '{"error":"invalid package"}'; return 1; }
  _cdir="$FGC_STATE/icons"
  mkdir -p "$_cdir" 2>/dev/null
  _cf="$_cdir/$1.b64"
  if [ -s "$_cf" ]; then cat "$_cf"; return 0; fi
  _out="$(fgc_java icon "$1" 2>/dev/null)" || { echo '{"error":"icon-unavailable"}'; return 1; }
  case "$_out" in '') echo '{"error":"icon-unavailable"}'; return 1 ;; esac
  case "$_out" in *[!a-zA-Z0-9+/=]*) echo '{"error":"icon-unavailable"}'; return 1 ;; esac
  printf '%s' "$_out" > "$_cf" 2>/dev/null
  printf '%s' "$_out"
}

cmd_diag() {
  _cmds="pm dumpsys am cmd getprop grep sed"; _ok=""
  for _c in $_cmds; do command -v "$_c" >/dev/null 2>&1 && _ok="$_ok $_c:yes" || _ok="$_ok $_c:no"; done
  _lock="absent"; [ -f "$FGC_STATE/session.lock" ] && _lock="held:$(cat "$FGC_STATE/session.lock" 2>/dev/null)"
  # file presence via readdir (ls+grep): stat() on module paths can flake
  # during Magisk mount churn while readdir+open keep working.
  _files=""; for _f in config/config.json config/gamelist.json config/blacklist.txt config/whitelist.txt core/main.sh core/caps.sh core/device.sh core/str.sh core/policy_engine.sh; do
    if ls "$MODDIR/${_f%/*}" 2>/dev/null | grep -qx "${_f##*/}"; then _files="$_files $_f:ok"; else _files="$_files $_f:missing"; fi
  done
  _caps="$(cat "$FGC_STATE/caps.json" 2>/dev/null)"
  [ -n "$_caps" ] || _caps="$(fgc_detect_caps 2>/dev/null)"
  [ -n "$_caps" ] || _caps='{"foreground":"unknown"}'
  _jv="$(fgc_java ping 2>/dev/null)"
  _jh=no; [ "$_jv" = "pong" ] && _jh=yes
  _caps="$(printf '%s' "$_caps" | sed 's/}$//')"
  _caps="$_caps,\"javahlp\":\"$_jh\"}"
  _dev="$(fgc_device_json 2>/dev/null)"; [ -n "$_dev" ] || _dev='{"manufacturer":"Unknown","model":"Unknown","android":"Unknown","sdk":"Unknown","root":"Not detected"}'
  printf '{"commands":"%s","session_lock":"%s","files":"%s","boot_completed":"%s","caps":%s,"device":%s}\n' "$_ok" "$(jesc "$_lock")" "$_files" "$(getprop sys.boot_completed 2>/dev/null)" "$_caps" "$_dev"
}

case "$1" in
  status) cmd_status ;;
  list) shift; cmd_list "$@" ;;
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  toggle) shift; cmd_toggle "$@" ;;
  set) shift; cmd_set "$@" ;;
  session-start|session-end) cmd_session "$1" "$2" ;;
  icon) cmd_icon "$2" ;;
  diag) cmd_diag ;;
  *) echo "usage: fgc-cli.sh status|list|add|remove|toggle|set|session-start|session-end|icon|diag" >&2; exit 1 ;;
esac
