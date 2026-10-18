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
. "$CORE_DIR/gamelist.sh"

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r\t'; }
# jbody <indent> <compact object> -> one `"k":v` per line, no trailing comma.
# For the flat scalar objects we emit (device, caps) a split on ',' is exact:
# every value is quote-sanitised and none can contain a comma or a brace.
# ponytail: a value with a comma needs a real parser; none of ours can have one.
jbody() {
  printf '%s\n' "$2" | awk -v i="$1" '{
    sub(/^[ \t]*\{/, ""); sub(/\}[ \t]*$/, "")
    n = split($0, a, ",")
    for (k = 1; k <= n; k++) {
      gsub(/^[ \t]+/, "", a[k])
      printf "%s%s%s\n", i, a[k], (k < n ? "," : "")
    }
  }'
}

_glist_ensure() {
  # Guarantee a usable gamelist.json: heal missing/corrupt files (backup +
  # reseed) instead of failing every later operation. Reads are retried:
  # a SINGLE empty read may be a transient FS flake, never wipe on that.
  # Returns 0 when the file is usable afterwards.
  _gf="$FGC_CONFIG/gamelist.json"
  _i=0
  while [ "$_i" -lt 3 ]; do
    _g="$(tr -d '\n\r' < "$_gf" 2>/dev/null)"
    case "$_g" in *'"games"'*) return 0 ;; esac
    _i=$((_i+1)); sleep 1
  done
  cp "$_gf" "$_gf.bak" 2>/dev/null
  printf '{"games": []}\n' > "$_gf" 2>/dev/null || return 1
  fgc_log "CORE_ERROR" "" "gamelist" "rescued" "missing-or-corrupt"
  return 0
}

_list_filter() {
  # $1=file $2=exact-pkg: drop pkg + !pkg lines, ATOMIC via tmp+rename.
  # Every stage is status-checked: a failed read must NEVER truncate the file
  # (grep -v exits 1 on empty-but-valid output, which is fine).
  _lf="$1"
  _le="$(printf '%s' "$2" | sed 's/\./\\./g')"
  grep -v "^$_le$" "$_lf" 2>/dev/null | grep -v "^!$_le$" > "$_lf.tmp"
  _grc=$?
  if [ "$_grc" -gt 1 ]; then rm -f "$_lf.tmp" 2>/dev/null; return 1; fi
  mv "$_lf.tmp" "$_lf" 2>/dev/null || return 1
}

_list_append() {
  # $1=file $2=line: atomic append. The baseline MUST be readable first —
  # appending blind onto an unreadable file would silently drop content.
  _lf="$1"
  _o="$(cat "$_lf" 2>/dev/null)" || return 1
  { [ -n "$_o" ] && printf '%s\n' "$_o"; printf '%s\n' "$2"; } > "$_lf.tmp" 2>/dev/null || return 1
  mv "$_lf.tmp" "$_lf" 2>/dev/null || return 1
}

# Java helper (tools/java/FgcPm.java -> bin/fgc-pm.dex): real PackageManager
# labels/icons on every ROM. Absent/unrunnable -> pm/dumpsys fallback.
# NOTE: no `[ -f dex ]` pre-check here — stat() on module paths flakes on some
# devices while open()+exec keep working; readability is probed open-based
# and the exec itself IS the final check.
FGC_DEX="$MODDIR/bin/fgc-pm.dex"
# Icon renderer generation. Bumping it retires every cached bitmap exactly once
# (key "<appver>|g<GEN>"), e.g. after changing how icons are trimmed/scaled.
FGC_ICON_GEN=3
fgc_java() {
  command -v app_process >/dev/null 2>&1 || return 1
  cat "$FGC_DEX" >/dev/null 2>&1 || return 1
  # Keep PARTIAL output: `icons` renders a batch and exits non-zero only when it
  # rendered nothing, but a mid-batch failure still leaves valid rows on stdout.
  # Dropping them on rc!=0 threw away every icon that did render.
  # Time-bounded: a wedged JVM must not hang the WebUI call forever. 45s leaves
  # room inside the bridge's 60s budget for the APK fallback that runs after it.
  _jo="$(fgc_run_timed 45 app_process -Djava.class.path="$FGC_DEX" /system/bin FgcPm "$@" 2>/dev/null)"
  [ -n "$_jo" ] || return 1
  printf '%s' "$_jo"
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
  _run="false"
  # A lock DIR alone proves nothing: after a crash (SIGKILL) it stays behind, and
  # the UI then reports ACTIVE while nothing unfreezes the blacklist. Same PID
  # check as main.sh.
  if [ -d "$FGC_STATE/daemon.lock" ]; then
    _dpid="$(cat "$FGC_STATE/daemon.lock/pid" 2>/dev/null)"
    case "$_dpid" in
      ''|*[!0-9]*) ;;
      *) tr '\0' ' ' < "/proc/$_dpid/cmdline" 2>/dev/null | grep -q 'core/main.sh' && _run="true" ;;
    esac
  fi
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
  # Leftover freeze self-heal. An app can stay disabled after the game closed
  # when the daemon died before it saw IDLE, or when a session end could not
  # finish. While the daemon is alive it owns that decision; when it is gone,
  # finish the session here instead of leaving apps disabled until the next boot.
  # Throttled: the WebUI polls status, and an app that refuses to enable must not
  # turn every poll into a pm retry storm. No-op in the normal case.
  if [ -s "$FGC_STATE/frozen.txt" ] && [ "$_run" != "true" ]; then
    _heal="$FGC_STATE/.heal_ts"
    _hn="$(cat "$_heal" 2>/dev/null)"; [ -n "$_hn" ] || _hn=0
    _now="$(date +%s 2>/dev/null)"; [ -n "$_now" ] || _now=0
    if [ $((_now - _hn)) -ge 60 ]; then
      printf '%s' "$_now" > "$_heal" 2>/dev/null
      rm -f "$FGC_STATE/.drain_ts" 2>/dev/null
      . "$CORE_DIR/session_controller.sh"
      if [ -z "$_game" ] || ! fgc_pkg_running "$_game"; then
        fgc_session_end >/dev/null 2>&1
        _game=""
      fi
    fi
  fi
  _lc="$(printf '%s' "$_sj" | grep -o '"last_cleanup"[ ]*:[ ]*"[^"]*"' | cut -d'"' -f4)"
  _ver="$(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
  _dev="$(fgc_device_json 2>/dev/null)"; [ -n "$_dev" ] || _dev='{"manufacturer":"Unknown","model":"Unknown","android":"Unknown","sdk":"Unknown","root":"Not detected"}'
  printf '{\n'
  printf '    "core":"%s",\n' "$_core"
  printf '    "daemon_running":%s,\n' "$_run"
  printf '    "enabled":%s,\n' "$([ "$_en" = "false" ] && echo false || echo true)"
  printf '    "game":"%s",\n' "$(jesc "$_game")"
  printf '    "profile":%s,\n' "${_prof:-1}"
  printf '    "last_cleanup":"%s",\n' "$(jesc "$_lc")"
  printf '    "version":"%s",\n' "$(jesc "$_ver")"
  printf '    "device":{\n'
  jbody '        ' "$_dev"
  printf '    }\n}\n'
}

cmd_list() { # list [games|blacklist|whitelist|logs|config|packages] (bare = games)
  [ -z "$1" ] && set -- games
  case "$1" in
    games)
      _glist_ensure 2>/dev/null || { echo '{"error":"gamelist-missing"}'; return 1; }
      cat "$FGC_CONFIG/gamelist.json" 2>/dev/null || echo '{"error":"gamelist-missing"}' ;;
    blacklist) fgc_each_all "$FGC_CONFIG/blacklist.txt" ;;
    whitelist) fgc_each_all "$FGC_CONFIG/whitelist.txt" ;;
    logs) tail -n 100 "$FGC_LOGS/session.log" 2>/dev/null || true ;;
    config) cat "$FGC_CONFIG/config.json" 2>/dev/null || echo '{}' ;;
    packages)
      # list packages [all|user|system] -> pkg<TAB>label<TAB>user|system<TAB>ver
      # (real pm/Java data; the 4th column is the app's versionCode).
      _which="${2:-all}"
      # A missing state dir must not silently degrade to the slow pm+dumpsys
      # path (its temp files live here too).
      mkdir -p "$FGC_STATE" 2>/dev/null
      # fast path: Java PackageManager helper (single shot, correct labels)
      _jl="$FGC_STATE/.javapkgs"
      _tab="$(printf '\t')"
      if fgc_snap "$_jl" fgc_java list; then
        _head="$(head -n 1 "$_jl" 2>/dev/null)"
        case "$_head" in *"$_tab"*)
          if [ "$_which" = "all" ]; then cat "$_jl"
          else
            # Field-precise: split on tabs and compare ONLY the type column, so
            # a trailing column (versionCode) can never break -- or fake -- a
            # filter. Never match the whole line (labels may contain "user").
            while IFS="$_tab" read -r _pp _pl _pt _pv || [ -n "$_pp" ]; do
              [ "$_pt" = "$_which" ] || continue
              printf '%s\t%s\t%s\t%s\n' "$_pp" "$_pl" "$_pt" "$_pv"
            done < "$_jl"
          fi
          rm -f "$_jl"
          return 0 ;;
        esac
      fi
      rm -f "$_jl"
      _sysf="$FGC_STATE/.syspkgs"
      # fgc_snap, not a redirect: app_process cannot write to /data/adb (see str.sh)
      fgc_snap "$_sysf" pm list packages -s
      sed 's/^package://' "$_sysf" 2>/dev/null | sort -u > "$_sysf.n" 2>/dev/null
      mv "$_sysf.n" "$_sysf" 2>/dev/null
      pm list packages < /dev/null 2>/dev/null | sed 's/^package://' | sort -u | while IFS= read -r p; do
        [ -n "$p" ] || continue
        if grep -qx "$p" "$_sysf" 2>/dev/null; then _t=system; else _t=user; fi
        case "$_which" in all) ;; "$_t") ;; *) continue ;; esac
        _l=""; _vc=""
        if fgc_snap "$FGC_STATE/.pkgout" dumpsys package "$p"; then
          _l="$(_fgc_pick_label "$FGC_STATE/.pkgout" 2>/dev/null)" || _l=""
          # best effort (POSIX BRE only): versionCode feeds the icon cache key
          _vc="$(sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' "$FGC_STATE/.pkgout" 2>/dev/null | head -n 1)"
        fi
        rm -f "$FGC_STATE/.pkgout"
        [ -z "$_l" ] && _l="$p"
        printf '%s\t%s\t%s\t%s\n' "$p" "$_l" "$_t" "$_vc"
      done
      rm -f "$_sysf"
      ;;
    *) echo '{"error":"unknown list"}' >&2; return 1 ;;
  esac
}

valid_pkg() { # exact package chars only (fgc_pkg_ok: shared with core/gamelist.sh)
  fgc_pkg_ok "$1"
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
      _glist_ensure || { echo '{"error":"add-failed"}'; return 1; }
      _gf="$FGC_CONFIG/gamelist.json"; _dump="$_gf.list"; _tab="$(printf '\t')"
      fgc_glist_dump "$_gf" > "$_dump" 2>/dev/null || { rm -f "$_dump" 2>/dev/null; echo '{"error":"add-failed"}'; return 1; }
      _dupe=0
      while IFS="$_tab" read -r _gp _gl _gpf; do
        [ "$_gp" = "$_p" ] && _dupe=1
      done < "$_dump"
      if [ "$_dupe" = "1" ]; then
        rm -f "$_dump" 2>/dev/null; echo '{"error":"duplicate"}'; return 1
      fi
      # jesc: the label travels as JSON-escaped text, exactly what the file stores
      _l="$(jesc "$_label")"
      printf '%s\t%s\t%s\n' "$_p" "$_l" "${_prof:-0}" >> "$_dump" 2>/dev/null \
        || { rm -f "$_dump" 2>/dev/null; echo '{"error":"add-failed"}'; return 1; }
      if fgc_glist_write "$_gf" < "$_dump"; then
        rm -f "$_dump" 2>/dev/null
        fgc_log "SESSION_STARTED" "$_p" "gamelist-add" "added" ""
        echo '{"ok":true}'
      else
        rm -f "$_dump" 2>/dev/null; echo '{"error":"add-failed"}'; return 1
      fi ;;
    blacklist|whitelist)
      _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
      grep -qx "$_p" "$_f" 2>/dev/null && { echo '{"error":"duplicate"}'; return 1; }
      # remove disabled twin line then append — both atomic, both verified
      _list_filter "$_f" "$_p" || { echo '{"error":"add-failed"}'; return 1; }
      _list_append "$_f" "$_p" || { echo '{"error":"add-failed"}'; return 1; }
      echo '{"ok":true}' ;;
    *) echo '{"error":"unknown target"}'; return 1 ;;
  esac
}

cmd_remove() { # remove <games|blacklist|whitelist> <package> [package...]
  _t="$1"; shift
  [ "$#" -gt 0 ] || { echo '{"error":"invalid package"}'; return 1; }
  case "$_t" in
    blacklist|whitelist)
      # Bulk form. A shell `for` loop cannot be passed through an `su -c`/adb
      # wrapper (the wrapper splits the string, so the shell receives a bare
      # `for`), and removing a dozen entries one call at a time is how users end
      # up hand-editing the file. Accept the whole list in one call.
      _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
      _bad=""
      for _p in "$@"; do
        valid_pkg "$_p" || { _bad="$_bad $_p"; continue; }
        _list_filter "$_f" "$_p" || _bad="$_bad $_p"
      done
      if [ -z "$_bad" ]; then echo '{"ok":true}'; return 0; fi
      echo "{\"error\":\"remove-failed\",\"packages\":\"${_bad# }\"}"; return 1 ;;
  esac
  _p="$1"
  valid_pkg "$_p" || { echo '{"error":"invalid package"}'; return 1; }
  case "$_t" in
    games)
      _glist_ensure || { echo '{"error":"remove-failed"}'; return 1; }
      _gf="$FGC_CONFIG/gamelist.json"; _dump="$_gf.list"; _tab="$(printf '\t')"
      fgc_glist_dump "$_gf" > "$_dump" 2>/dev/null || { rm -f "$_dump" 2>/dev/null; echo '{"error":"remove-failed"}'; return 1; }
      # Rebuild WITHOUT the target (exact package compare, never a regex on a
      # label) and re-emit the pretty document.
      while IFS="$_tab" read -r _gp _gl _gpf; do
        [ "$_gp" = "$_p" ] && continue
        printf '%s\t%s\t%s\n' "$_gp" "$_gl" "$_gpf"
      done < "$_dump" > "$_dump.2"
      if fgc_glist_write "$_gf" < "$_dump.2"; then
        rm -f "$_dump" "$_dump.2" 2>/dev/null; echo '{"ok":true}'
      else
        rm -f "$_dump" "$_dump.2" 2>/dev/null; echo '{"error":"remove-failed"}'; return 1
      fi ;;
    *) echo '{"error":"unknown target"}'; return 1 ;;
  esac
}

cmd_toggle() { # toggle <blacklist|whitelist> <package> on|off  (off = prefix !)
  _t="$1"; _p="$2"; _s="$3"
  valid_pkg "$_p" || { echo '{"error":"invalid package"}'; return 1; }
  _f="$FGC_CONFIG/$([ "$_t" = blacklist ] && echo blacklist.txt || echo whitelist.txt)"
  _list_filter "$_f" "$_p" || { echo '{"error":"toggle-failed"}'; return 1; }
  if [ "$_s" = "on" ]; then _list_append "$_f" "$_p" || { echo '{"error":"toggle-failed"}'; return 1; }
  else _list_append "$_f" "!$_p" || { echo '{"error":"toggle-failed"}'; return 1; }; fi
  echo '{"ok":true}'
}

cmd_set() { # set <key> <value> | set profile <1..4> [package]
  if [ "$1" = "profile" ]; then
    _pv="$2"; _pkg="$3"
    # 0 = follow default-profile (valid for per-game entries only)
    case "$_pv" in 0|1|2|3|4) ;; *) echo '{"error":"invalid profile"}'; return 1 ;; esac
    if [ -n "$_pkg" ] && [ "$_pv" = "0" ]; then :; elif [ -z "$_pkg" ] && [ "$_pv" = "0" ]; then echo '{"error":"invalid profile"}'; return 1; fi
    if [ -n "$_pkg" ]; then
      valid_pkg "$_pkg" || { echo '{"error":"invalid package"}'; return 1; }
      _glist_ensure || { echo '{"error":"set-failed"}'; return 1; }
      _gf="$FGC_CONFIG/gamelist.json"; _dump="$_gf.list"; _tab="$(printf '\t')"
      fgc_glist_dump "$_gf" > "$_dump" 2>/dev/null || { rm -f "$_dump" 2>/dev/null; echo '{"error":"set-failed"}'; return 1; }
      _found=0
      while IFS="$_tab" read -r _gp _gl _gpf; do
        if [ "$_gp" = "$_pkg" ]; then _gpf="$_pv"; _found=1; fi
        printf '%s\t%s\t%s\n' "$_gp" "$_gl" "$_gpf"
      done < "$_dump" > "$_dump.2" 2>/dev/null
      if [ "$_found" != "1" ]; then
        rm -f "$_dump" "$_dump.2" 2>/dev/null
        echo '{"error":"not-a-game"}'; return 1
      fi
      if fgc_glist_write "$_gf" < "$_dump.2"; then
        rm -f "$_dump" "$_dump.2" 2>/dev/null; echo '{"ok":true}'
      else
        rm -f "$_dump" "$_dump.2" 2>/dev/null; echo '{"error":"set-failed"}'; return 1
      fi
    else
      fgc_cfg_set default_profile "$_pv" && echo '{"ok":true}' || echo '{"error":"set-failed"}'
    fi
  else
    if [ "$1" = "enabled" ] && [ "$2" = "false" ] && [ -s "$FGC_STATE/frozen.txt" ]; then
      # Turning the core OFF must not leave blacklist apps disabled: the daemon
      # stops polling, so nothing would ever unfreeze them again. Bypass the
      # 1/minute drain throttle — this is the last chance.
      rm -f "$FGC_STATE/.drain_ts" 2>/dev/null
      . "$CORE_DIR/session_controller.sh"
      fgc_session_end >/dev/null 2>&1
    fi
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
      _glist_ensure 2>/dev/null || { echo '{"error":"not-a-game"}'; return 1; }
      grep -q "\"package\"[ ]*:[ ]*\"$2\"" "$FGC_CONFIG/gamelist.json" 2>/dev/null \
        || { echo '{"error":"not-a-game"}'; return 1; }
      FGC_GAME="$2" fgc_session_start "$2" && echo '{"ok":true}' ;;
    session-end)
      fgc_session_end && echo '{"ok":true}' \
        || { echo '{"error":"session-busy"}'; return 1; } ;;
    *) echo '{"error":"unknown session cmd"}'; return 1 ;;
  esac
}

fgc_apk_icon() {
  # $1 = pkg -> base64 PNG taken straight out of the APK (no PackageManager).
  # Last resort for ROMs where resource inflation throws (seen when the ROM's
  # theme-compat file is missing): the app still ships a real launcher bitmap, so the row never has to fall back to a letter.
  # Prints nothing and returns 1 when no usable entry exists (caller keeps its
  # letter avatar), so this can never make an icon worse than it is today.
  command -v unzip >/dev/null 2>&1 || return 1
  _ak_pkg="$1"
  _ak_apk=""
  _ak_pm="$(fgc_run_timed 15 pm path "$_ak_pkg" 2>/dev/null)"
  while IFS= read -r _ak_l || [ -n "$_ak_l" ]; do
    case "$_ak_l" in package:*) _ak_apk="${_ak_l#package:}"; break ;; esac
  done <<_FGC_AKPM
$_ak_pm
_FGC_AKPM
  [ -n "$_ak_apk" ] && [ -f "$_ak_apk" ] || return 1
  # Highest-density launcher bitmap wins. Foreground/background layers are
  # skipped: they are partial (transparent) art, not a standalone icon.
  # The listing is filtered first: a game APK can hold tens of thousands of
  # entries, and only these few can ever be candidates.
  _ak_best=""; _ak_score=-1
  _ak_ls="$(unzip -l "$_ak_apk" 2>/dev/null | grep -e ic_launcher -e app_icon -e '/icon\.png')"
  while IFS= read -r _ak_l || [ -n "$_ak_l" ]; do
    # `unzip -l` pads size/date columns, so the entry is the LAST field (APK
    # entry names never contain a space).
    _ak_f=""
    for _ak_w in $_ak_l; do _ak_f="$_ak_w"; done
    [ -n "$_ak_f" ] || continue
    case "$_ak_f" in *foreground*|*background*) continue ;; esac
    case "$_ak_f" in *ic_launcher*|*app_icon*|*/icon.png) ;; *) continue ;; esac
    case "$_ak_f" in *.png) ;; *) continue ;; esac
    _ak_s=0
    case "$_ak_f" in
      *xxxhdpi*) _ak_s=6 ;; *xxhdpi*) _ak_s=5 ;; *xhdpi*) _ak_s=4 ;;
      *hdpi*) _ak_s=3 ;; *mdpi*) _ak_s=2 ;; *ldpi*) _ak_s=1 ;;
    esac
    if [ "$_ak_s" -gt "$_ak_score" ]; then _ak_score="$_ak_s"; _ak_best="$_ak_f"; fi
  done <<_FGC_AKLS
$_ak_ls
_FGC_AKLS
  [ -n "$_ak_best" ] || return 1
  _ak_b64="$(unzip -p "$_ak_apk" "$_ak_best" 2>/dev/null | base64 2>/dev/null | tr -d '\n\r ')"
  case "$_ak_b64" in ''|*[!a-zA-Z0-9+/=]*) return 1 ;; esac
  printf '%s' "$_ak_b64"
}

cmd_icon() {
  # icon <pkg> [ver] -> base64 PNG (144px) on stdout. Disk-cached under state/icons.
  # Optional ver (app versionName): when it differs from the cached key the icon
  # is regenerated (covers app updates without extra version lookups here).
  # .ver key is "<appver>|gGEN": the GEN marker retires caches made by older
  # renderer generations (e.g. pre-transparency, pre-full-bleed), exactly once
  # even when no version is passed.
  valid_pkg "$1" || { echo '{"error":"invalid package"}'; return 1; }
  _cdir="$FGC_STATE/icons"
  _gen="$FGC_ICON_GEN"
  mkdir -p "$_cdir" 2>/dev/null
  _cf="$_cdir/$1.b64"; _vf="$_cdir/$1.ver"
  # Cache key = "<appver>|g<GEN>". An empty appver is fine: the key becomes
  # "|gGEN", so a legacy cache (no .ver) or one written by an older renderer is
  # retired EXACTLY ONCE even when the caller passes no version (the WebUI
  # usually passes none because the package list carries no versionName).
  _want="$2|g$_gen"
  if [ -s "$_cf" ] && [ "$(cat "$_vf" 2>/dev/null)" = "$_want" ]; then cat "$_cf"; return 0; fi
  _out="$(fgc_java icon "$1" 2>/dev/null)"
  case "$_out" in ''|*[!a-zA-Z0-9+/=]*) _out="$(fgc_apk_icon "$1" 2>/dev/null)" ;; esac
  case "$_out" in
    ''|*[!a-zA-Z0-9+/=]*)
      # Regeneration failed. A stale-but-real icon still beats a letter avatar,
      # and accepting it (key updated) stops a broken helper from being
      # re-executed on every single render.
      if [ -s "$_cf" ]; then printf '%s' "$_want" > "$_vf" 2>/dev/null; cat "$_cf"; return 0; fi
      echo '{"error":"icon-unavailable"}'; return 1 ;;
  esac
  printf '%s' "$_out" > "$_cf" 2>/dev/null
  printf '%s' "$_want" > "$_vf" 2>/dev/null
  printf '%s' "$_out"
}

cmd_icons() {
  # icons [pkg[=ver]...] -> pkg<TAB>base64 per line.
  #  - no args: dump the WHOLE disk cache (no generation, one cheap exec).
  #  - with args: return the cached icons for those packages and RENDER the
  #    missing ones in a single helper exec. JVM startup dominates icon cost,
  #    so one exec per row left long lists sitting on their letter avatar for
  #    a minute or more (looked like "icons randomly fall back to letters").
  #  - `pkg=ver` uses the same cache key as `icon <pkg> <ver>`, so both paths
  #    share one cache and an app update retires exactly one bitmap.
  _cdir="$FGC_STATE/icons"
  mkdir -p "$_cdir" 2>/dev/null
  [ $# -gt 0 ] || {
    for _cf in "$_cdir"/*.b64; do
      [ -f "$_cf" ] || continue
      _bn="${_cf##*/}"; _bp="${_bn%.b64}"
      valid_pkg "$_bp" || continue
      printf '%s\t%s\n' "$_bp" "$(cat "$_cf" 2>/dev/null)"
    done
    return 0
  }
  _miss=""; _jargs=""
  for _arg in "$@"; do
    _p="${_arg%%=*}"; _v=""
    case "$_arg" in *=*) _v="${_arg#*=}" ;; esac
    case "$_v" in ''|*[!a-zA-Z0-9._]*) _v="" ;; esac
    valid_pkg "$_p" || continue
    if [ -s "$_cdir/$_p.b64" ] && [ "$(cat "$_cdir/$_p.ver" 2>/dev/null)" = "$_v|g$FGC_ICON_GEN" ]; then
      printf '%s\t%s\n' "$_p" "$(cat "$_cdir/$_p.b64" 2>/dev/null)"
    else
      _miss="$_miss $_p=$_v"; _jargs="$_jargs $_p"
    fi
  done
  [ -n "$_jargs" ] || return 0
  _verof() {
    for _t in $_miss; do
      case "$_t" in "$1="*) printf '%s' "${_t#*=}"; return 0 ;; "$1") return 0 ;; esac
    done
    return 0
  }
  _tab="$(printf '\t')"
  # Stream the helper STRAIGHT into the loop. The old path captured the batch in
  # `$(...)` and re-emitted it with `printf '%s' "$batch"`: one icon is ~17 KB of
  # base64, so a full batch (~133 KB) blew past MAX_ARG_STRLEN (128 KB) and the
  # shell dropped the WHOLE chunk with "Argument list too long" (rc 126). Every
  # full 8-icon batch therefore vanished and those rows kept their letter avatar
  # — the "icons sometimes show as letters" report. `|| [ -n "$_gp" ]` also keeps
  # the last row, which arrives without a trailing newline.
  # Java helper (fast path). Skipped entirely when app_process is unavailable —
  # the APK fallback below needs no Java.
  if command -v app_process >/dev/null 2>&1; then
    fgc_run_timed 45 app_process -Djava.class.path="$FGC_DEX" /system/bin FgcPm icons $_jargs 2>/dev/null | while IFS="$_tab" read -r _gp _gb || [ -n "$_gp" ]; do
      [ -n "$_gp" ] && [ -n "$_gb" ] || continue
      case "$_gb" in *[!a-zA-Z0-9+/=]*) continue ;; esac
      valid_pkg "$_gp" || continue
      _gv="$(_verof "$_gp")"
      printf '%s' "$_gb" > "$_cdir/$_gp.b64" 2>/dev/null
      printf '%s' "$_gv|g$FGC_ICON_GEN" > "$_cdir/$_gp.ver" 2>/dev/null
      printf '%s\t%s\n' "$_gp" "$_gb"
    done
  fi
  # Shell fallback for the packages the Java helper could not render. Runs only
  # for rows that are still uncached, so a normal batch pays nothing for it.
  for _p in $_jargs; do
    [ -s "$_cdir/$_p.b64" ] && [ "$(cat "$_cdir/$_p.ver" 2>/dev/null)" = "$(_verof "$_p")|g$FGC_ICON_GEN" ] && continue
    _gb="$(fgc_apk_icon "$_p" 2>/dev/null)"
    [ -n "$_gb" ] || continue
    _gv="$(_verof "$_p")"
    printf '%s' "$_gb" > "$_cdir/$_p.b64" 2>/dev/null
    printf '%s' "$_gv|g$FGC_ICON_GEN" > "$_cdir/$_p.ver" 2>/dev/null
    printf '%s\t%s\n' "$_p" "$_gb"
  done
}

cmd_clearlog() {
  # clearlog -> truncate the persistent session log. Prints {"ok":true} ONLY
  # after the file is verified empty (or was already absent): a failed clear
  # must never be reported as success. Safe against the live daemon — it opens
  # the log O_APPEND, so its next write lands at the new EOF (offset 0).
  # Idempotent: clearing an absent/empty log is a no-op success.
  _lf="$FGC_LOGS/session.log"
  if [ -e "$_lf" ]; then
    : > "$_lf" 2>/dev/null || { echo '{"error":"clear-failed"}'; return 1; }
    _sz="$(wc -c < "$_lf" 2>/dev/null | tr -d ' ')"
    [ "$_sz" = "0" ] || { echo '{"error":"clear-failed"}'; return 1; }
  fi
  echo '{"ok":true}'
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
  _caps=""
  if [ -s "$FGC_STATE/caps.json" ]; then
    _caps="$(cat "$FGC_STATE/caps.json" 2>/dev/null)"
  fi
  # Opportunistic refresh: absent snapshot, or a boot-time snapshot that
  # predates ready services (empty launcher, unverified foreground). Probe
  # instead of reporting stale degradation forever.
  _stale=1
  case "$_caps" in
    *'"foreground":"activity"'*|*'"foreground":"window"'*) _stale=0 ;;
  esac
  case "$_caps" in *'"launcher":""'*) _stale=1 ;; esac
  if [ "$_stale" = 1 ]; then
    _fresh="$(fgc_detect_caps 2>/dev/null)"
    [ -n "$_fresh" ] && _caps="$_fresh"
  fi
  [ -n "$_caps" ] || _caps='{"foreground":"unknown"}'
  _jv="$(fgc_java ping 2>/dev/null)"
  # A single app_process exec can fail while another app_process/pm is starting
  # (transient, seen as javahlp:"no" with a working dex). One retry keeps the
  # capability report honest instead of flapping to degraded.
  [ "$_jv" = "pong" ] || _jv="$(fgc_java ping 2>/dev/null)"
  _jh=no; [ "$_jv" = "pong" ] && _jh=yes
  _caps="$(printf '%s' "$_caps" | sed 's/}$//')"
  _caps="$_caps,\"javahlp\":\"$_jh\"}"
  _dev="$(fgc_device_json 2>/dev/null)"; [ -n "$_dev" ] || _dev='{"manufacturer":"Unknown","model":"Unknown","android":"Unknown","sdk":"Unknown","root":"Not detected"}'
  _nic=0; _nic="$(ls "$FGC_STATE/icons" 2>/dev/null | grep -c '\.b64$' 2>/dev/null)"; [ -n "$_nic" ] || _nic=0
  # Counts as the CORE sees them: the WebUI shows its own parsed counts next to
  # these, so "page doesn't match the file" is a one-glance comparison instead
  # of a guess (a mismatch means the bridge read, not the config, is at fault).
  _ng=0; _ng="$(grep -c '"package"' "$FGC_CONFIG/gamelist.json" 2>/dev/null)"; [ -n "$_ng" ] || _ng=0
  _nw="$(fgc_each_active "$FGC_CONFIG/whitelist.txt" 2>/dev/null | grep -c . 2>/dev/null)"; [ -n "$_nw" ] || _nw=0
  _nb="$(fgc_each_active "$FGC_CONFIG/blacklist.txt" 2>/dev/null | grep -c . 2>/dev/null)"; [ -n "$_nb" ] || _nb=0
  # Frozen entries still waiting to be re-enabled. Non-zero outside a session is
  # the "session ended but apps still disabled" state; the WebUI drains it.
  _nf=0; _nf="$(grep -c . "$FGC_STATE/frozen.txt" 2>/dev/null)"; [ -n "$_nf" ] || _nf=0
  printf '{\n'
  printf '    "commands":"%s",\n' "${_ok# }"
  printf '    "session_lock":"%s",\n' "$(jesc "$_lock")"
  printf '    "files":"%s",\n' "${_files# }"
  printf '    "boot_completed":"%s",\n' "$(getprop sys.boot_completed 2>/dev/null)"
  printf '    "icons_cached":%s,\n' "$_nic"
  printf '    "cfg_games":%s,\n' "$_ng"
  printf '    "cfg_white":%s,\n' "$_nw"
  printf '    "cfg_black":%s,\n' "$_nb"
  printf '    "frozen":%s,\n' "$_nf"
  printf '    "caps":{\n'
  jbody '        ' "$_caps"
  printf '    },\n'
  printf '    "device":{\n'
  jbody '        ' "$_dev"
  printf '    }\n}\n'
}

case "$1" in
  status) cmd_status ;;
  list) shift; cmd_list "$@" ;;
  add) shift; cmd_add "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  toggle) shift; cmd_toggle "$@" ;;
  set) shift; cmd_set "$@" ;;
  session-start|session-end) cmd_session "$1" "$2" ;;
  icon) shift; cmd_icon "$@" ;;
  icons) shift; cmd_icons "$@" ;;
  clearlog) cmd_clearlog ;;
  diag) cmd_diag ;;
  *) echo "usage: fgc-cli.sh status|list|add|remove|toggle|set|session-start|session-end|icon|icons|clearlog|diag" >&2; exit 1 ;;
esac
