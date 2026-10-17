#!/usr/bin/env bash
# tests/posix.sh — strict-POSIX regression suite. Runs core flows with a grep
# that REFUSES GNU BRE extensions (\|, \+, intervals), proving the code works
# on minimal greps (toybox 0.8.x fails those SILENTLY — this exact class broke
# game detection + config migration on-device once).
cd "$(dirname "$0")/.." || exit 1
export MSYS=winsymlinks:native
command -v /usr/bin/grep >/dev/null 2>&1 || { echo "SKIP posix (no reference grep)"; exit 0; }
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod" "$T/bin" "$T/strict"
cp module.prop "$T/mod/"; cp -r core config system "$T/mod/"
M="$T/mod"
export FGC_MODDIR="$M" FGC_DATA="$T/data"
cat > "$T/strict/grep" <<'EOF'
#!/usr/bin/env bash
for _a in "$@"; do
  case "$_a" in *'\\|'*|*'\\+'*) echo "STRICT-GREP rejects GNU alternation/plus: $_a" >&2; exit 99 ;; esac
  case "$_a" in *'\{[0-9]'*) echo "STRICT-GREP rejects interval: $_a" >&2; exit 99 ;; esac
done
exec /usr/bin/grep "$@"
EOF
chmod +x "$T/strict/grep"
cat > "$T/bin/getprop" <<'EOF'
#!/usr/bin/env bash
case "$1" in sys.boot_completed) echo 1 ;; esac
EOF
cat > "$T/bin/pm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/dumpsys" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "activity" ] && [ "$2" = "top" ]; then echo "  ACTIVITY com.top.game/.Main 1 pid=1"; exit 0; fi
if [ "$1" = "activity" ]; then echo "    topResumedActivity=ActivityRecord{9ab u0 com.miui.game/com.miui.game.Play} t1"; exit 0; fi
if [ "$1" = "window" ]; then echo "  mCurrentFocus=Window{com.top.game}"; exit 0; fi
EOF
cat > "$T/bin/cmd" <<'EOF'
#!/usr/bin/env bash
echo "priority=0 isDefault=true"
echo "com.miui.home/.launcher.Launcher"
EOF
cat > "$T/bin/am" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/strict:$T/bin:$PATH"
bash "$M/core/data_init.sh"

pass=0; fail=0
. "$M/core/foreground_monitor.sh"
# real device-line fixtures
out=$(_fgc_pkg_of '    topResumedActivity=ActivityRecord{1274f72 u0 io.github.x0eg0.magisk/com.topjohnwu.magisk.ui.webui.WebUIActivity} t4974}')
[ "$out" = "io.github.x0eg0.magisk" ] && { echo "PASS pkg miui-line"; pass=$((pass+1)); } || { echo "FAIL pkg miui-line -- got: $out"; fail=$((fail+1)); }
out=$(_fgc_pkg_of '  mFocusedApp=ActivityRecord{abc u0 com.foo/.Bar}')
[ "$out" = "com.foo" ] && { echo "PASS pkg old-line"; pass=$((pass+1)); } || { echo "FAIL pkg old-line -- got: $out"; fail=$((fail+1)); }
out=$(_fgc_pkg_of '  mCurrentFocus=Window{123 com.win/com.win.Main}')
[ "$out" = "com.win" ] && { echo "PASS pkg window-line"; pass=$((pass+1)); } || { echo "FAIL pkg window-line -- got: $out"; fail=$((fail+1)); }
out=$(_fgc_pkg_of '  ACTIVITY com.miui.home/.launcher.Launcher 195001b pid=3376')
[ "$out" = "com.miui.home" ] && { echo "PASS pkg top-line"; pass=$((pass+1)); } || { echo "FAIL pkg top-line -- got: $out"; fail=$((fail+1)); }
out=$(_fgc_pkg_of 'garbage [[[ ')
[ -z "$out" ] && { echo "PASS pkg garbage-empty"; pass=$((pass+1)); } || { echo "FAIL pkg garbage -- got: $out"; fail=$((fail+1)); }
# live flows under strict grep
CLI="bash $M/core/fgc-cli.sh"
out=$($CLI add games com.miui.game MiuiGame 0)
[[ "$out" == *'"ok":true'* ]] && { echo "PASS strict add"; pass=$((pass+1)); } || { echo "FAIL strict add -- got: $out"; fail=$((fail+1)); }
out=$(bash "$M/core/event_detector.sh")
[ "$out" = "GAME|com.miui.game" ] && { echo "PASS strict detect"; pass=$((pass+1)); } || { echo "FAIL strict detect -- got: $out"; fail=$((fail+1)); }
out=$($CLI set profile 2 com.miui.game)
[[ "$out" == *'"ok":true'* ]] && { echo "PASS strict setprof"; pass=$((pass+1)); } || { echo "FAIL strict setprof -- got: $out"; fail=$((fail+1)); }
out=$($CLI remove games com.miui.game)
[[ "$out" == *'"ok":true'* ]] && grep -q '"games": \[\]' "$T/data/config/gamelist.json" && { echo "PASS strict remove"; pass=$((pass+1)); } || { echo "FAIL strict remove"; fail=$((fail+1)); }
. "$M/core/caps.sh"
out=$(fgc_detect_caps)
case "$out" in *'"foreground":"activity"'*|*'"foreground":"window"'*) echo "PASS strict caps-fg"; pass=$((pass+1)) ;; *) echo "FAIL strict caps-fg -- got: $out"; fail=$((fail+1)); ;; esac
case "$out" in *'"launcher":"com.miui.home"'*) echo "PASS strict caps-launcher"; pass=$((pass+1)) ;; *) echo "FAIL strict caps-launcher"; fail=$((fail+1)); ;; esac
n1=$(md5sum "$T/data/config/config.json" | cut -d' ' -f1)
bash "$M/core/data_init.sh" >/dev/null 2>&1
n2=$(md5sum "$T/data/config/config.json" | cut -d' ' -f1)
[ "$n1" = "$n2" ] && { echo "PASS strict migrate-idempotent"; pass=$((pass+1)); } || { echo "FAIL strict migrate changed file"; fail=$((fail+1)); }
# shipped defaults are already in the PRETTY layout, and the canonical writer in
# core/config_manager.sh reproduces them byte for byte (strict grep active: the
# whole format layer must stay POSIX-clean).
grep -q '^{"games": \[\]}$' "$M/config/gamelist.json" && { echo "PASS shipped gamelist empty form"; pass=$((pass+1)); } || { echo "FAIL shipped gamelist empty form"; fail=$((fail+1)); }
if [ "$(cat "$M/config/config.json")" = "$(. "$M/core/config_manager.sh" 2>/dev/null; fgc_cfg_pretty)" ]; then echo "PASS shipped config is canonical"; pass=$((pass+1)); else echo "FAIL shipped config not canonical"; fail=$((fail+1)); fi
# gamelist write -> read round-trip (pretty on disk, values intact)
. "$M/core/gamelist.sh"
GL="$T/data/config/gamelist.json"
printf 'com.miui.aa\tAlpha, One\t3\ncom.miui.bb\tBeta\t0\n' | fgc_glist_write "$GL"
if grep -q '^        "package": "com.miui.aa",$' "$GL" && grep -q '^        "label": "Alpha, One",$' "$GL" \
   && [ "$(fgc_glist_profile "$GL" com.miui.aa)" = "3" ] \
   && [ "$(fgc_glist_dump "$GL" | grep -c "^com.miui.bb$(printf '\t')")" = "1" ]; then
  echo "PASS strict gamelist pretty round-trip"; pass=$((pass+1))
else echo "FAIL strict gamelist round-trip -- got: $(cat "$GL")"; fail=$((fail+1)); fi
# legacy COMPACT gamelist (the shape every v1.2.5 device still has) is upgraded
# to pretty at boot; values survive, and a second run is a no-op.
printf '{"games": [{"package": "com.miui.cc", "label": "Cee: C", "profile": 2}]}\n' > "$GL"
fgc_glist_normalize "$GL"
if grep -q '^        "package": "com.miui.cc",$' "$GL" && [ "$(fgc_glist_profile "$GL" com.miui.cc)" = "2" ] \
   && [ "$(fgc_glist_dump "$GL" | cut -f2)" = "Cee: C" ]; then
  echo "PASS strict gamelist compact->pretty"; pass=$((pass+1))
else echo "FAIL strict gamelist compact->pretty -- got: $(cat "$GL")"; fail=$((fail+1)); fi
_m1=$(md5sum "$GL" | cut -d' ' -f1); fgc_glist_normalize "$GL"; _m2=$(md5sum "$GL" | cut -d' ' -f1)
[ "$_m1" = "$_m2" ] && { echo "PASS strict gamelist normalize idempotent"; pass=$((pass+1)); } || { echo "FAIL strict gamelist normalize rewrote"; fail=$((fail+1)); }
printf '{"games": []}\n' > "$GL"; fgc_glist_normalize "$GL"
[ "$(cat "$GL")" = '{"games": []}' ] && { echo "PASS strict empty gamelist untouched"; pass=$((pass+1)); } || { echo "FAIL strict empty gamelist changed"; fail=$((fail+1)); }
# app_process-backed tools (pm/dumpsys/cmd) MUST NOT write straight to a file:
# the zygote context cannot write under /data/adb, so a bare redirect makes the
# tool ABORT and every snapshot reads empty (on-device: all "already disabled"
# checks failed, FGC re-enabled user-disabled apps and spun a pm retry loop).
# Capture in the shell instead (fgc_snap / $(...)). Static check, no device.
_bad=$(grep -nE '\b(pm|dumpsys|cmd) [^|;>]*> *"?\$' "$M"/core/*.sh 2>/dev/null | grep -v ':[0-9]*: *#')
[ -z "$_bad" ] && { echo "PASS no app_process redirect-to-file"; pass=$((pass+1)); } || { echo "FAIL app_process redirect -- $_bad"; fail=$((fail+1)); }
# The icon batch MUST stream from app_process straight into the read loop.
# Round-tripping it through `$(...)` + `printf '%s' "$batch"` hits MAX_ARG_STRLEN
# (~128 KB, and one icon is ~17 KB of base64): the shell drops the WHOLE chunk
# with "Argument list too long" and every full batch keeps its letter avatars.
_ic=$(grep -n 'FgcPm icons' "$M/core/fgc-cli.sh" | grep -v ':[0-9]*: *#')
case "$_ic" in *'$('*) echo "FAIL icons batch captured into a variable -- $_ic"; fail=$((fail+1)) ;; *) echo "PASS icons batch streams"; pass=$((pass+1)) ;; esac
# Every app_process exec MUST be time-bounded: a wedged JVM would otherwise hang
# the WebUI call (and the bridge) forever with no icon and no error.
_ub=$(grep -nE '(^|[^_a-z])app_process ' "$M/core/fgc-cli.sh" | grep -vE '^[0-9]+: *#' | grep -v 'fgc_run_timed' | grep -v 'command -v')
[ -z "$_ub" ] && { echo "PASS app_process calls time-bounded"; pass=$((pass+1)); } || { echo "FAIL unbounded app_process -- $_ub"; fail=$((fail+1)); }
echo "--- $pass pass, $fail fail ---"
exit $fail
