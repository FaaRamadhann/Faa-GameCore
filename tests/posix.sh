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
echo "--- $pass pass, $fail fail ---"
exit $fail
