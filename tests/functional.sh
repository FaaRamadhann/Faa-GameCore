#!/usr/bin/env bash
# tests/functional.sh — end-to-end core test under Git Bash with stubbed Android commands.
export MSYS=winsymlinks:native  # real symlinks (default msys silently COPIES)
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod" "$T/bin" "$T/mod/state" "$T/mod/logs"
cp module.prop "$T/mod/"
cp -r core config system "$T/mod/"
M="$T/mod"
export FGC_MODDIR="$M"
export FGC_DATA="$T/data"
# simulate install: seed + link persistent storage (no old module dir)
bash "$M/core/data_init.sh"

# ---- stubs ----
cat > "$T/bin/getprop" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  sys.boot_completed) echo "${STUB_BOOT:-1}" ;;
  ro.product.manufacturer) echo TestMan ;;
  ro.product.model) echo TestModel ;;
  ro.build.version.release) echo 15 ;;
  ro.build.version.sdk) echo 35 ;;
esac
EOF
cat > "$T/bin/magisk" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-v" ] && echo "27.0:MAGISK"
EOF
cat > "$T/bin/cmd" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_PM_LOG"
if [ "$1" = "package" ] && [ "$2" = "enable" ]; then
  case "${@: -1}" in com.gone.app|com.flaky.app) exit 1 ;; esac
  grep -v "^package:${@: -1}$" "$STUB_DISABLED" 2>/dev/null > "$STUB_DISABLED.tmp" || true
  mv "$STUB_DISABLED.tmp" "$STUB_DISABLED" 2>/dev/null || true
  exit 0
fi
echo "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true"
echo "com.test.launcher/com.test.launcher.Home"
EOF
cat > "$T/bin/pm" <<'EOF'
#!/usr/bin/env bash
echo "$@" >> "$STUB_PM_LOG"
if [ "$1" = "disable-user" ]; then
  echo "Package ${@: -1} new state: disabled-user"   # real pm prints on STDOUT
  [ "$STUB_DISABLE_LIE" = "1" ] && exit 0             # lie: claims ok, no change
  printf 'package:%s\n' "${@: -1}" >> "$STUB_DISABLED"; exit 0
fi
if [ "$1" = "enable" ]; then
  case "${@: -1}" in
    com.gone.app|com.flaky.app)
      echo "cmd: Failure calling service package: Failed transaction (2147483646)"; exit 1 ;;
  esac
  echo "Package ${@: -1} new state: enabled"          # real pm prints on STDOUT
  [ "$STUB_ENABLE_LIE" = "1" ] && exit 0               # lie: claims ok, stays disabled
  grep -v "^package:${@: -1}$" "$STUB_DISABLED" 2>/dev/null > "$STUB_DISABLED.tmp" || true
  mv "$STUB_DISABLED.tmp" "$STUB_DISABLED" 2>/dev/null || true
  exit 0
fi
if [ "$1" = "path" ]; then
  # existence probe: answers for DISABLED packages too; gone => no output.
  case "${@: -1}" in com.gone.app) exit 0 ;; esac
  echo "package:/data/app/${@: -1}/base.apk"; exit 0
fi
if [ "$1" = "list" ] && [ "$3" = "-d" ]; then cat "$STUB_DISABLED" 2>/dev/null; exit 0; fi
if [ "$3" = "-s" ]; then echo "package:android"; echo "package:com.android.systemui"; echo "package:com.android.settings"; exit 0; fi
echo "package:com.test.game"
echo "package:com.evil.app"
echo "package:com.whatsapp"
echo "package:android"
echo "package:com.android.systemui"
EOF
cat > "$T/bin/dumpsys" <<'EOF'
#!/usr/bin/env bash
if [ "${STUB_DUMPSYS:-new}" = "weird" ] && [ "$1" != "package" ]; then echo "??? unknown rom format ???"; exit 0; fi
if [ "$1" = "package" ]; then
  case "$2" in com.evil.app) echo "    application-label:'Evil App'";; *) echo "  application-label:StubApp";; esac
  exit 0
fi
if [ "$1" = "activity" ] && [ "$2" = "top" ]; then echo "  ACTIVITY com.test.game/.Main 12345 pid=999"; exit 0; fi
if [ "$1" = "activity" ]; then
  # MIUI/HyperOS style (default); STUB_DUMPSYS=old selects legacy AOSP style
  if [ "${STUB_DUMPSYS:-new}" = "old" ]; then echo "  mFocusedApp=ActivityRecord{com.test.game/.Main}";
  else echo "    topResumedActivity=ActivityRecord{1274f72 u0 com.test.game/com.test.game.Main} t123}"; fi
  exit 0
fi
if [ "$1" = "window" ]; then
  echo "  mCurrentFocus=Window{com.test.game}"; exit 0
fi
EOF
cat > "$T/bin/am" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_AM_LOG"
exit 0
EOF
cat > "$T/bin/app_process" <<'EOF'
#!/usr/bin/env bash
# stub Java helper: responds like FgcPm for ping/list/icon
if [ "$4" = "ping" ]; then echo pong; exit 0; fi
if [ "$4" = "list" ]; then
  printf 'com.stub.game\tStub Game\tuser\ncom.stub.sys\tStub Sys\tsystem\n'
  exit 0
fi
if [ "$4" = "icon" ]; then echo "aVBORw0KGgo="; exit 0; fi
exit 1
EOF
cat > "$T/bin/ps" <<'EOF'
#!/usr/bin/env bash
cat "$STUB_PS_FILE" 2>/dev/null
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export STUB_AM_LOG="$T/am.log" STUB_PS_FILE="$T/ps.txt" STUB_PM_LOG="$T/pm.log" STUB_DISABLED="$T/disabled.txt"
: > "$T/am.log"; : > "$T/ps.txt"; : > "$T/pm.log"; : > "$T/disabled.txt"
CLI="bash $M/core/fgc-cli.sh"

pass=0; fail=0
ck() { # ck <desc> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1 -- got: $3"; fail=$((fail+1)); fi
}

out=$($CLI status);            ck "status STOPPED (no daemon)" '"core":"STOPPED"' "$out"
out=$(STUB_BOOT=0 $CLI status); ck "status STARTING pre-boot" '"core":"STARTING"' "$out"
printf 'x\tCORE_ERROR\t\tx\ty\tz\n' >> "$T/data/logs/session.log"
out=$($CLI status);             ck "status ERROR on core error" '"core":"ERROR"' "$out"
sed -i '/CORE_ERROR/d' "$T/data/logs/session.log"
out=$($CLI add games com.test.game TestGame 0); ck "add game" '"ok":true' "$out"
out=$($CLI add games com.test.game TestGame 0); ck "reject duplicate game" 'duplicate' "$out"
out=$($CLI add games com.multi.word My Cool Game 2); ck "add multiword label" '"ok":true' "$out"
grep -q '"package": "com.multi.word"' "$T/data/config/gamelist.json" && grep -q 'My Cool Game' "$T/data/config/gamelist.json" && { echo "PASS label stored exact"; pass=$((pass+1)); } || { echo "FAIL label stored"; fail=$((fail+1)); }
out=$($CLI remove games com.multi.word); ck "remove multiword" '"ok":true' "$out"
printf '{\n "games": [\n  {"package": "com.keep.me", "label": "Keep Me", "profile": 0},\n  {"package": "com.drop.me", "label": "Drop Me", "profile": 2}\n ]\n}' > "$T/data/config/gamelist.json"
out=$($CLI remove games com.drop.me); ck "remove pretty-listed" '"ok":true' "$out"
if grep -q '"package": "com.keep.me"' "$T/data/config/gamelist.json" && ! grep -q 'com.drop.me' "$T/data/config/gamelist.json"; then echo "PASS pretty remove preserves"; pass=$((pass+1)); else echo "FAIL pretty remove"; fail=$((fail+1)); fi
out=$($CLI add games com.test.game TestGame 0); ck "restore test game" '"ok":true' "$out"
out=$($CLI set profile 3 com.test.game); ck "set per-game profile" '"ok":true' "$out"
grep -q '"package": "com.test.game"[^}]*"profile": 3' "$T/data/config/gamelist.json" && { echo "PASS per-game stored"; pass=$((pass+1)); } || { echo "FAIL per-game stored"; fail=$((fail+1)); }
out=$($CLI set profile 0 com.test.game); ck "reset per-game default" '"ok":true' "$out"
out=$($CLI set profile 9 com.test.game); ck "reject bad per-game" 'invalid profile' "$out"
out=$($CLI list games);        ck "list games has pkg" 'com.test.game' "$out"
out=$($CLI list);               ck "bare list defaults games" 'com.test.game' "$out"
mkdir -p "$T/empty/config" "$T/empty/state" "$T/empty/logs"
out=$(FGC_DATA="$T/empty" $CLI list games)
[[ "$out" == *'"games":[]'* ]] && [ -f "$T/empty/config/gamelist.json" ] && { echo "PASS missing gamelist self-heals"; pass=$((pass+1)); } || { echo "FAIL gamelist heal -- got: $out"; fail=$((fail+1)); }
out=$($CLI add blacklist com.evil.app);  ck "blacklist add" '"ok":true' "$out"
out=$($CLI add blacklist com.evil.app);   ck "reject duplicate blacklist" 'duplicate' "$out"
out=$($CLI add whitelist com.evil.app);   ck "whitelist add" '"ok":true' "$out"
# whitelist precedence: evil.app must NOT be a target
. "$M/core/policy_engine.sh"
targets=$(fgc_policy_targets 2 com.test.game)
if [[ "$targets" == *"com.evil.app"* ]]; then echo "FAIL whitelist precedence -- got: $targets"; fail=$((fail+1)); else echo "PASS whitelist precedence"; pass=$((pass+1)); fi
# system protection
$CLI add blacklist android >/dev/null
targets=$(fgc_policy_targets 2 com.test.game)
if [[ "$targets" == *"android"* ]]; then echo "FAIL system protection"; fail=$((fail+1)); else echo "PASS system protection"; pass=$((pass+1)); fi
$CLI remove blacklist android >/dev/null
# foreground game never a target
$CLI add blacklist com.test.game >/dev/null
targets=$(fgc_policy_targets 2 com.test.game)
if [[ "$targets" == *"com.test.game"* ]]; then echo "FAIL fg-game protection"; fail=$((fail+1)); else echo "PASS fg-game protection"; pass=$((pass+1)); fi
$CLI remove blacklist com.test.game >/dev/null
# toggle off -> disabled line
out=$($CLI toggle blacklist com.evil.app off); ck "toggle off" '"ok":true' "$out"
out=$($CLI list blacklist)
if [[ "$out" == *'!com.evil.app'* ]] && ! printf '%s\n' "$out" | grep -x 'com.evil.app' >/dev/null; then echo "PASS toggle off removes from active"; pass=$((pass+1)); else echo "FAIL toggle off still active -- got: $out"; fail=$((fail+1)); fi
if grep -q '^!com.evil.app$' "$T/data/config/blacklist.txt"; then echo "PASS disabled marker kept"; pass=$((pass+1)); else echo "FAIL disabled marker"; fail=$((fail+1)); fi
$CLI toggle blacklist com.evil.app on >/dev/null
# config validation
out=$($CLI set poll_interval_sec 5);      ck "set poll 5" '"ok":true' "$out"
out=$($CLI set poll_interval_sec 1);      ck "reject poll 1" 'error' "$out"
out=$($CLI set detection_mode foo);       ck "reject bad mode" 'error' "$out"
out=$($CLI set detection_mode foreground); ck "set mode foreground" '"ok":true' "$out"
out=$($CLI set default_profile 2);        ck "set profile 2" '"ok":true' "$out"
out=$($CLI set default_profile 9);        ck "reject profile 9" 'error' "$out"
out=$($CLI set enabled false);            ck "disable core" '"ok":true' "$out"
out=$($CLI status);                       ck "status DISABLED" '"core":"DISABLED"' "$out"
out=$($CLI set enabled true);             ck "re-enable" '"ok":true' "$out"
# dry-run: process marked running but am must NOT be called
printf 'u0_a1 123 456 com.evil.app\n' > "$T/ps.txt"
. "$M/core/process_manager.sh"
export FGC_GAME=com.test.game
$CLI set dry_run true >/dev/null
fgc_cleanup com.evil.app
if grep -q com.evil.app "$T/am.log"; then echo "FAIL dry-run called am"; fail=$((fail+1)); else echo "PASS dry-run no force-stop"; pass=$((pass+1)); fi
$CLI set dry_run false >/dev/null
rm -f "$T/data/config/whitelist.txt.bak"; grep -v '^com.evil.app$' "$T/data/config/whitelist.txt" > "$T/wl" && mv "$T/wl" "$T/data/config/whitelist.txt"
fgc_cleanup com.evil.app
if grep -q 'force-stop com.evil.app' "$T/am.log"; then echo "PASS real cleanup force-stop"; pass=$((pass+1)); else echo "FAIL real cleanup"; fail=$((fail+1)); fi
# session start = single cleanup (second start is no-op)
: > "$T/am.log"
. "$M/core/session_controller.sh"
FGC_GAME=com.test.game fgc_session_start com.test.game
FGC_GAME=com.test.game fgc_session_start com.test.game
n=$(grep -c force-stop "$T/am.log")
if [ "$n" -eq 1 ]; then echo "PASS single cleanup per session"; pass=$((pass+1)); else echo "FAIL single cleanup (n=$n)"; fail=$((fail+1)); fi
fgc_session_end
[ -f "$T/data/state/session.lock" ] && { echo "FAIL lock cleared"; fail=$((fail+1)); } || { echo "PASS lock cleared"; pass=$((pass+1)); }
# detector + packages + diag + logs
out=$(bash "$M/core/event_detector.sh"); ck "detector finds game (miui fmt)" 'GAME|com.test.game' "$out"
out=$(STUB_DUMPSYS=old bash "$M/core/event_detector.sh"); ck "detector finds game (old fmt)" 'GAME|com.test.game' "$out"
out=$(STUB_DUMPSYS=weird bash "$M/core/event_detector.sh"); ck "unknown rom degrades IDLE" 'IDLE' "$out"
out=$($CLI icon com.no.helper.here 2>/dev/null); ck "icon unavailable w/o helper" 'icon-unavailable' "$out"
out=$($CLI list packages); ck "pm stub packages" 'com.whatsapp' "$out"
printf '%s\n' "$out" | grep -x 'android	StubApp	system' >/dev/null && { echo "PASS pkg type system"; pass=$((pass+1)); } || { echo "FAIL pkg type system -- got: $out"; fail=$((fail+1)); }
printf '%s\n' "$out" | grep -x 'com.test.game	StubApp	user' >/dev/null && { echo "PASS pkg type user"; pass=$((pass+1)); } || { echo "FAIL pkg type user -- got: $out"; fail=$((fail+1)); }
printf '%s\n' "$out" | grep -x 'com.evil.app	Evil App	user' >/dev/null && { echo "PASS quoted label w/ space"; pass=$((pass+1)); } || { echo "FAIL quoted label -- got: $out"; fail=$((fail+1)); }
out=$($CLI list packages user)
if printf '%s\n' "$out" | grep -x 'android	StubApp	system' >/dev/null; then echo "FAIL user filter"; fail=$((fail+1)); else echo "PASS user filter"; pass=$((pass+1)); fi
out=$($CLI list packages system)
if printf '%s\n' "$out" | grep -x 'android	StubApp	system' >/dev/null && ! printf '%s\n' "$out" | grep -x 'com.test.game	StubApp	user' >/dev/null; then echo "PASS system filter"; pass=$((pass+1)); else echo "FAIL system filter -- got: $out"; fail=$((fail+1)); fi
# java helper path (FgcPm via app_process stub): real labels, icon cache, caps
mkdir -p "$M/bin"; cp bin/fgc-pm.dex "$M/bin/" 2>/dev/null || echo "fake-dex" > "$M/bin/fgc-pm.dex"
out=$($CLI list packages)
printf '%s\n' "$out" | grep -x 'com.stub.game	Stub Game	user' >/dev/null && { echo "PASS java list labels"; pass=$((pass+1)); } || { echo "FAIL java list -- got: $out"; fail=$((fail+1)); }
out=$($CLI list packages user)
if printf '%s\n' "$out" | grep -x 'com.stub.game	Stub Game	user' >/dev/null && ! printf '%s\n' "$out" | grep -q 'com.stub.sys'; then echo "PASS java user filter"; pass=$((pass+1)); else echo "FAIL java user filter -- got: $out"; fail=$((fail+1)); fi
out=$($CLI icon com.test.game)
[ "$out" = "aVBORw0KGgo=" ] && [ -f "$T/data/state/icons/com.test.game.b64" ] && { echo "PASS icon cache"; pass=$((pass+1)); } || { echo "FAIL icon -- got: $out"; fail=$((fail+1)); }
out=$($CLI icons com.test.game com.missing.pkg)
printf '%s\n' "$out" | grep -qx 'com.test.game	aVBORw0KGgo=' && ! printf '%s\n' "$out" | grep -q 'com.missing' && { echo "PASS icons batch"; pass=$((pass+1)); } || { echo "FAIL icons batch -- got: $out"; fail=$((fail+1)); }
out=$($CLI icon com.test.game 9.9); ck "icon regen on ver change" 'aVBORw0KGgo=' "$out"
[ "$(cat "$T/data/state/icons/com.test.game.ver" 2>/dev/null)" = "9.9|g3" ] && { echo "PASS icon ver stored"; pass=$((pass+1)); } || { echo "FAIL icon ver stored"; fail=$((fail+1)); }
out=$($CLI icon com.test.game 9.9); ck "icon ver cache hit" 'aVBORw0KGgo=' "$out"
# legacy/pre-gen cache (no .ver) must retire even when NO version is passed
rm -f "$T/data/state/icons/com.test.game.ver"
out=$($CLI icon com.test.game)
if [ "$(cat "$T/data/state/icons/com.test.game.ver" 2>/dev/null)" = "|g3" ]; then echo "PASS icon legacy retired no-ver"; pass=$((pass+1)); else echo "FAIL icon legacy retired no-ver"; fail=$((fail+1)); fi
out=$($CLI diag)
[[ "$out" == *'"javahlp":"yes"'* ]] && { echo "PASS caps javahlp"; pass=$((pass+1)); } || { echo "FAIL caps javahlp"; fail=$((fail+1)); }
out=$($CLI diag); ck "diag runs" 'session_lock' "$out"
out=$($CLI list logs); ck "logs written" 'SESSION_STARTED' "$out"
# clearlog: honest, verified truncation — pure JSON, empty afterwards, idempotent
out=$($CLI clearlog); ck "clearlog ok" '{"ok":true}' "$out"
[ ! -s "$T/data/logs/session.log" ] && { echo "PASS clearlog emptied"; pass=$((pass+1)); } || { echo "FAIL clearlog emptied -- size $(wc -c < "$T/data/logs/session.log")"; fail=$((fail+1)); }
out=$($CLI list logs); [ -z "$out" ] && { echo "PASS clearlog leaves no residue"; pass=$((pass+1)); } || { echo "FAIL clearlog leaves no residue -- got: $out"; fail=$((fail+1)); }
out=$($CLI clearlog); ck "clearlog idempotent" '{"ok":true}' "$out"
# universal: device info detected (never hardcoded)
out=$($CLI status)
ck "device model detected" '"model":"TestModel"' "$out"
ck "device android detected" '"android":"15"' "$out"
ck "root manager detected" '"root":"Magisk 27.0:MAGISK"' "$out"
# universal: caps + dynamic launcher protection
out=$($CLI diag)
ck "caps foreground detected" '"foreground":"activity"' "$out"
ck "caps launcher detected" '"launcher":"com.test.launcher"' "$out"
$CLI add blacklist com.test.launcher >/dev/null
targets=$(fgc_policy_targets 2 com.test.game)
if [[ "$targets" == *"com.test.launcher"* ]]; then echo "FAIL dynamic launcher protection"; fail=$((fail+1)); else echo "PASS dynamic launcher protection"; pass=$((pass+1)); fi
$CLI remove blacklist com.test.launcher >/dev/null
# universal: graceful when dumpsys missing (no crash, empty output)
out=$(PATH=/usr/bin:/bin bash "$M/core/foreground_monitor.sh"); rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ]; then echo "PASS no-dumpsys graceful"; pass=$((pass+1)); else echo "FAIL no-dumpsys graceful (rc=$rc out=$out)"; fail=$((fail+1)); fi
# companion-trigger interface (Zygisk/LSPosed/Tasker contract)
out=$($CLI session-start com.unknown.app); ck "session-start rejects unlisted" 'not-a-game' "$out"
printf 'u0_a1 123 456 com.evil.app\n' > "$T/ps.txt"
out=$($CLI session-start com.test.game); ck "session-start listed game" '"ok":true' "$out"
[ -f "$T/data/state/session.lock" ] && { echo "PASS companion lock held"; pass=$((pass+1)); } || { echo "FAIL companion lock"; fail=$((fail+1)); }
out=$($CLI session-end); ck "session-end" '"ok":true' "$out"
# profile differentiation: force-stop honors explicit selection on every
# profile; freeze stays user-only; Awaken adds one bounded second sweep
. "$M/core/caps.sh"
fgc_detect_caps >/dev/null 2>&1
grep -qx 'com.android.settings' "$T/data/state/.syspkgs" && { echo "PASS sys snapshot"; pass=$((pass+1)); } || { echo "FAIL sys snapshot"; fail=$((fail+1)); }
out=$($CLI add blacklist com.android.settings); ck "blacklist system pkg" '"ok":true' "$out"
printf 'u0_a1 123 456 com.evil.app\nu0_a1 124 457 com.android.settings\n' > "$T/ps.txt"
: > "$T/am.log"; : > "$T/pm.log"
out=$($CLI set default_profile 1); ck "profile balance" '"ok":true' "$out"
: > "$T/am.log"
out=$($CLI session-start com.test.game)
if [ -s "$T/am.log" ]; then echo "FAIL balance no-action"; fail=$((fail+1)); else echo "PASS balance no-action"; pass=$((pass+1)); fi
if ! grep -q 'disable-user' "$T/pm.log"; then echo "PASS balance never freezes"; pass=$((pass+1)); else echo "FAIL balance never freezes"; fail=$((fail+1)); fi
if $CLI list logs | grep -q 'no action (balance normal)'; then echo "PASS balance logged"; pass=$((pass+1)); else echo "FAIL balance logged"; fail=$((fail+1)); fi
out=$($CLI session-end) >/dev/null
out=$($CLI set default_profile 2) >/dev/null; : > "$T/am.log"; : > "$T/pm.log"
out=$($CLI session-start com.test.game)
if grep -q 'force-stop com.evil.app' "$T/am.log" && grep -q 'force-stop com.android.settings' "$T/am.log"; then echo "PASS performance all"; pass=$((pass+1)); else echo "FAIL performance all"; fail=$((fail+1)); fi
if ! grep -q 'disable-user' "$T/pm.log"; then echo "PASS performance no-freeze"; pass=$((pass+1)); else echo "FAIL performance no-freeze"; fail=$((fail+1)); fi
out=$($CLI session-end) >/dev/null
out=$($CLI set default_profile 3) >/dev/null; : > "$T/am.log"
out=$($CLI session-start com.test.game)
n=$(grep -c 'force-stop com.evil.app' "$T/am.log")
if [ "$n" -eq 2 ]; then echo "PASS awaken second sweep"; pass=$((pass+1)); else echo "FAIL awaken second sweep (n=$n)"; fail=$((fail+1)); fi
out=$($CLI session-end) >/dev/null
out=$($CLI set default_profile 2) >/dev/null
out=$($CLI remove blacklist com.android.settings) >/dev/null
# auto by battery: 1-20 Balance, 21-50 Performance, 51-100 Awaken, unknown Balance
out=$($CLI set default_profile 4) >/dev/null
export FGC_BATT="$T/capacity"
for _case in "10:1" "20:1" "21:2" "50:2" "51:3" "80:3"; do
  _v="${_case%%:*}"; _want="${_case##*:}"
  printf '%s' "$_v" > "$T/capacity"
  out=$($CLI session-start com.test.game)
  if grep -q "\"profile\":$_want" "$T/data/state/session.json"; then echo "PASS auto batt $_v -> $_want"; pass=$((pass+1)); else echo "FAIL auto batt $_v (want $_want)"; fail=$((fail+1)); fi
  out=$($CLI session-end) >/dev/null
done
export FGC_BATT="$T/missing-capacity"
out=$($CLI session-start com.test.game)
if grep -q '"profile":1' "$T/data/state/session.json"; then echo "PASS auto unknown-batt"; pass=$((pass+1)); else echo "FAIL auto unknown-batt"; fail=$((fail+1)); fi
out=$($CLI session-end) >/dev/null
unset FGC_BATT
out=$($CLI set default_profile 2) >/dev/null
# freeze/unfreeze: P3 freezes user targets, skips system; end restores; boot heals
out=$($CLI set default_profile 3) >/dev/null
out=$($CLI add blacklist com.android.settings) >/dev/null
printf 'u0_a1 123 456 com.evil.app\nu0_a1 124 457 com.android.settings\n' > "$T/ps.txt"
: > "$T/pm.log"; : > "$T/data/state/frozen.txt"
out=$($CLI set default_profile 3) >/dev/null
out=$($CLI session-start com.test.game)
if grep -q 'disable-user.*com.evil.app' "$T/pm.log" && ! grep -q 'disable-user.*com.android.settings' "$T/pm.log"; then echo "PASS freeze user-only"; pass=$((pass+1)); else echo "FAIL freeze user-only"; fail=$((fail+1)); fi
if grep -qx 'com.evil.app' "$T/data/state/frozen.txt"; then echo "PASS frozen tracked"; pass=$((pass+1)); else echo "FAIL frozen tracked"; fail=$((fail+1)); fi
out=$($CLI session-end)
if grep -q 'enable.*com.evil.app' "$T/pm.log" && [ ! -s "$T/data/state/frozen.txt" ]; then echo "PASS unfreeze on end"; pass=$((pass+1)); else echo "FAIL unfreeze on end"; fail=$((fail+1)); fi
out=$($CLI set default_profile 2) >/dev/null
# user-pre-disabled apps are never touched (no disable, no track, no enable)
printf 'package:com.pre.disabled\n' > "$T/disabled.txt"
out=$($CLI add blacklist com.pre.disabled) >/dev/null
: > "$T/pm.log"
out=$($CLI session-start com.test.game); out=$($CLI session-end) >/dev/null
if ! grep -q 'disable-user.*com.pre.disabled' "$T/pm.log" && ! grep -qx 'com.pre.disabled' "$T/data/state/frozen.txt" 2>/dev/null; then echo "PASS predisable respected"; pass=$((pass+1)); else echo "FAIL predisable respected"; fail=$((fail+1)); fi
if ! grep -q 'enable.*com.pre.disabled' "$T/pm.log"; then echo "PASS predisable not enabled"; pass=$((pass+1)); else echo "FAIL predisable not enabled"; fail=$((fail+1)); fi
out=$($CLI remove blacklist com.pre.disabled) >/dev/null; : > "$T/disabled.txt"
: > "$T/pm.log"
out=$($CLI set default_profile 1) >/dev/null
out=$($CLI session-start com.test.game); out=$($CLI session-end) >/dev/null
if grep -q 'disable-user' "$T/pm.log"; then echo "FAIL p1 no-freeze"; fail=$((fail+1)); else echo "PASS p1 no-freeze"; pass=$((pass+1)); fi
out=$($CLI set default_profile 2) >/dev/null
printf 'com.stale.app\ncom.gone.app\n' > "$T/data/state/frozen.txt"
bash "$M/core/recovery.sh" >/dev/null 2>&1
if grep -q 'enable.*com.stale.app' "$T/pm.log" && ! grep -qx 'com.stale.app' "$T/data/state/frozen.txt" 2>/dev/null; then echo "PASS recovery unfreeze"; pass=$((pass+1)); else echo "FAIL recovery unfreeze"; fail=$((fail+1)); fi
if ! grep -qx 'com.gone.app' "$T/data/state/frozen.txt" 2>/dev/null && $CLI list logs | grep -q 'package-gone'; then echo "PASS gone-app dropped"; pass=$((pass+1)); else echo "FAIL gone-app dropped"; fail=$((fail+1)); fi
# freeze_system toggle (Awaken-only, system-type): ON freezes, OFF skips.
# Blacklist <-> Awaken <-> toggle form one connected system.
out=$($CLI set freeze_system true); ck "freeze_system on" '"ok":true' "$out"
$CLI add blacklist com.android.settings >/dev/null 2>&1 || true
printf 'u0_a1 124 457 com.android.settings\n' > "$T/ps.txt"
: > "$T/pm.log"; : > "$T/data/state/frozen.txt"
out=$($CLI set default_profile 3) >/dev/null
out=$($CLI session-start com.test.game)
if grep -q 'disable-user.*com.android.settings' "$T/pm.log"; then echo "PASS freeze-system on"; pass=$((pass+1)); else echo "FAIL freeze-system on"; fail=$((fail+1)); fi
out=$($CLI session-end) >/dev/null
out=$($CLI set default_profile 2) >/dev/null; out=$($CLI set freeze_system false) >/dev/null
out=$($CLI remove blacklist com.android.settings) >/dev/null
# unfreeze resilience: a transient pm-enable failure must KEEP the entry (app
# still exists) for the next retry, never silently drop it (=> app stuck off).
printf 'com.flaky.app\n' > "$T/data/state/frozen.txt"
bash "$M/core/recovery.sh" >/dev/null 2>&1
if grep -qx 'com.flaky.app' "$T/data/state/frozen.txt" 2>/dev/null && $CLI list logs | grep -q 'kept-for-retry'; then echo "PASS unfreeze fail kept for retry"; pass=$((pass+1)); else echo "FAIL unfreeze fail kept for retry"; fail=$((fail+1)); fi
: > "$T/data/state/frozen.txt"
# leftover frozen entries are drained even with NO session lock (belt+braces on
# top of boot recovery, so an app is never stuck disabled for a whole session)
printf 'com.evil.app\n' > "$T/data/state/frozen.txt"
: > "$T/pm.log"
out=$($CLI session-end) >/dev/null
if grep -q 'enable.*com.evil.app' "$T/pm.log" && [ ! -s "$T/data/state/frozen.txt" ]; then echo "PASS leftover unfreeze no-lock"; pass=$((pass+1)); else echo "FAIL leftover unfreeze no-lock"; fail=$((fail+1)); fi
# CLI stdout must stay VALID JSON: pm chatter is silenced, so the WebUI's
# JSON.parse never sees "Package X new state: ..." before the reply.
printf 'u0_a1 123 456 com.evil.app\n' > "$T/ps.txt"
$CLI set default_profile 3 >/dev/null; $CLI set freeze_system false >/dev/null
out=$($CLI session-start com.test.game)
if [ "$out" = '{"ok":true}' ]; then echo "PASS session-start stdout pure JSON"; pass=$((pass+1)); else echo "FAIL session-start stdout -- got: [$out]"; fail=$((fail+1)); fi
out=$($CLI session-end)
if [ "$out" = '{"ok":true}' ]; then echo "PASS session-end stdout pure JSON"; pass=$((pass+1)); else echo "FAIL session-end stdout -- got: [$out]"; fail=$((fail+1)); fi
$CLI set default_profile 2 >/dev/null
# honesty: an enable that reports success but leaves the app disabled must NOT
# be reported as success — demoted + kept for retry via a live-state check.
printf 'package:com.lie.app\n' > "$T/disabled.txt"
printf 'com.lie.app\n' > "$T/data/state/frozen.txt"
STUB_ENABLE_LIE=1 bash "$M/core/recovery.sh" >/dev/null 2>&1
if grep -qx 'com.lie.app' "$T/data/state/frozen.txt" 2>/dev/null && $CLI list logs | grep -q 'still-disabled-after-cmd'; then echo "PASS enable-lie demoted+kept"; pass=$((pass+1)); else echo "FAIL enable-lie demoted+kept"; fail=$((fail+1)); fi
# honesty: a disable-user reporting success without disabling must NOT be
# tracked (otherwise we would later "unfreeze" an app we never froze).
printf 'u0_a1 123 456 com.lie.app\n' > "$T/ps.txt"
$CLI add blacklist com.lie.app >/dev/null 2>&1 || true
: > "$T/disabled.txt"; : > "$T/data/state/frozen.txt"
printf 'android\ncom.android.systemui\ncom.android.settings\n' > "$T/data/state/.syspkgs"
$CLI set default_profile 3 >/dev/null
STUB_DISABLE_LIE=1 $CLI session-start com.test.game >/dev/null 2>&1
if ! grep -qx 'com.lie.app' "$T/data/state/frozen.txt" 2>/dev/null && $CLI list logs | grep -q 'not-disabled-after-cmd'; then echo "PASS disable-lie not tracked"; pass=$((pass+1)); else echo "FAIL disable-lie not tracked"; fail=$((fail+1)); fi
$CLI session-end >/dev/null 2>&1
$CLI remove blacklist com.lie.app >/dev/null 2>&1
$CLI set default_profile 2 >/dev/null
: > "$T/disabled.txt"; : > "$T/data/state/frozen.txt"
# fail-closed typing: with no system snapshot, user-type cannot be PROVED, so
# freeze must skip instead of disabling (previously fail-open disabled them).
mv "$T/data/state/.syspkgs" "$T/data/state/.syspkgs.keep" 2>/dev/null
$CLI add blacklist com.evil.app >/dev/null 2>&1 || true
printf 'u0_a1 123 456 com.evil.app\n' > "$T/ps.txt"
: > "$T/pm.log"; : > "$T/data/state/frozen.txt"
out=$($CLI set default_profile 3) >/dev/null; out=$($CLI set freeze_system false) >/dev/null
out=$($CLI session-start com.test.game); out=$($CLI session-end) >/dev/null
if ! grep -q 'disable-user' "$T/pm.log"; then echo "PASS type unknown skips freeze"; pass=$((pass+1)); else echo "FAIL type unknown skips freeze"; fail=$((fail+1)); fi
printf 'android\ncom.android.systemui\ncom.android.settings\n' > "$T/data/state/.syspkgs"
# NOTE: com.evil.app STAYS in the blacklist on purpose — the persistence tests
# below (update keeps data / delink / canonical paths) assert it survives.
out=$($CLI set default_profile 2) >/dev/null
: > "$T/data/state/frozen.txt"
# fgc PATH wrappers (FGC_MODULES override keeps this hermetic)
mkdir -p "$T/adb"; cp -r "$M" "$T/adb/faagamecore"
out=$(FGC_MODULES="$T/adb" bash "$M/system/bin/fgc" status)
[[ "$out" == *'"core"'* ]] && { echo "PASS fgc wrapper"; pass=$((pass+1)); } || { echo "FAIL fgc wrapper -- got: $out"; fail=$((fail+1)); }
out=$(FGC_MODULES="$T/adb" bash "$M/system/bin/fgc-cli" status)
[[ "$out" == *'"core"'* ]] && { echo "PASS fgc-cli wrapper"; pass=$((pass+1)); } || { echo "FAIL fgc-cli wrapper"; fail=$((fail+1)); }
if FGC_MODULES="$T/empty" bash "$M/system/bin/fgc" status >/dev/null 2>&1; then echo "FAIL wrapper missing-module"; fail=$((fail+1)); else echo "PASS wrapper missing-module"; pass=$((pass+1)); fi
# persistence: seeded data; module dirs stay PLAIN (never symlinked)
[ -f "$T/data/config/config.json" ] && [ -f "$T/data/config/gamelist.json" ] && { echo "PASS data seeded"; pass=$((pass+1)); } || { echo "FAIL data seeded"; fail=$((fail+1)); }
for _d in config state logs; do
  if [ ! -L "$M/$_d" ] && [ -d "$M/$_d" ]; then echo "PASS plain dir $_d"; pass=$((pass+1)); else echo "FAIL plain dir $_d"; fail=$((fail+1)); fi
done
# simulate module UPDATE: fresh copy + init(old=$M) must keep user data
mkdir -p "$T/mod2"; cp module.prop "$T/mod2/"; cp -r core config "$T/mod2/"
FGC_MODDIR="$T/mod2" bash "$T/mod2/core/data_init.sh" "$M"
[ ! -L "$T/mod2/config" ] && { echo "PASS update keeps plain dirs"; pass=$((pass+1)); } || { echo "FAIL update keeps plain dirs"; fail=$((fail+1)); }
out=$(FGC_MODDIR="$T/mod2" bash "$T/mod2/core/fgc-cli.sh" list blacklist)
printf '%s\n' "$out" | grep -qx 'com.evil.app' && { echo "PASS blacklist survives update"; pass=$((pass+1)); } || { echo "FAIL blacklist survives -- got: $out"; fail=$((fail+1)); }
# legacy symlink cleanup: pre-refactor installs may carry links shadowing data
mkdir -p "$T/mod3"; cp module.prop "$T/mod3/"; cp -r core config "$T/mod3/"
rm -rf "$T/mod3/config" "$T/mod3/state" "$T/mod3/logs"
ln -s "$T/data/config" "$T/mod3/config"; ln -s "$T/data/state" "$T/mod3/state"; ln -s "$T/data/logs" "$T/mod3/logs"
FGC_MODDIR="$T/mod3" bash "$T/mod3/core/data_init.sh" "$M"
if [ ! -L "$T/mod3/config" ] && [ -d "$T/mod3/config" ]; then echo "PASS stray links removed"; pass=$((pass+1)); else echo "FAIL stray links removed"; fail=$((fail+1)); fi
out=$(FGC_MODDIR="$T/mod3" bash "$T/mod3/core/fgc-cli.sh" list blacklist)
printf '%s\n' "$out" | grep -qx 'com.evil.app' && { echo "PASS serves data after delink"; pass=$((pass+1)); } || { echo "FAIL serves data after delink -- got: $out"; fail=$((fail+1)); }
# mirror identity: real default dirs must STILL serve data (canonical paths)
rm -f "$T/mod2/config" "$T/mod2/state" "$T/mod2/logs"
mkdir -p "$T/mod2/config" "$T/mod2/state" "$T/mod2/logs"
cp config/config.json config/gamelist.json config/blacklist.txt config/whitelist.txt "$T/mod2/config/"
out=$(FGC_MODDIR="$T/mod2" bash "$T/mod2/core/fgc-cli.sh" list blacklist)
printf '%s\n' "$out" | grep -qx 'com.evil.app' && { echo "PASS canonical paths (no symlinks)"; pass=$((pass+1)); } || { echo "FAIL canonical paths -- got: $out"; fail=$((fail+1)); }
out=$(FGC_MODDIR="$T/mod2" bash "$T/mod2/core/fgc-cli.sh" status)
[[ "$out" == *'"profile":2'* ]] && { echo "PASS config survives update"; pass=$((pass+1)); } || { echo "FAIL config survives -- got: $out"; fail=$((fail+1)); }
# backfill: drop a key segment -> re-init restores default, keeps customs
sed -i 's/"dry_run": [a-z]*,//' "$T/data/config/config.json"
FGC_MODDIR="$T/mod2" bash "$T/mod2/core/data_init.sh" "$M" >/dev/null
if grep -q '"dry_run"' "$T/data/config/config.json" && grep -q '"poll_interval_sec": 5' "$T/data/config/config.json"; then echo "PASS key backfill"; pass=$((pass+1)); else echo "FAIL key backfill"; fail=$((fail+1)); fi
# corrupt rescue: garbage -> valid defaults + .bak
echo 'CORRUPT{{{' > "$T/data/config/config.json"
FGC_MODDIR="$T/mod2" bash "$T/mod2/core/data_init.sh" "$M" >/dev/null
FGC_MODDIR="$T/mod2" bash "$T/mod2/core/fgc-cli.sh" status >/dev/null
if grep -q '"poll_interval_sec":3' "$T/data/config/config.json" && [ -f "$T/data/config/config.json.bak" ]; then echo "PASS corrupt rescue"; pass=$((pass+1)); else echo "FAIL corrupt rescue"; fail=$((fail+1)); fi
out=$($CLI remove games com.test.game); ck "remove game" '"ok":true' "$out"
# fail-closed: unreadable whitelist aborts cleanup AND freeze (never fail-open)
mv "$T/data/config/whitelist.txt" "$T/whitelist.hide"
. "$M/core/process_manager.sh"
export FGC_GAME=com.test.game
printf 'u0_a1 123 456 com.evil.app\n' > "$T/ps.txt"
: > "$T/am.log"; : > "$T/pm.log"
fgc_cleanup com.evil.app >/dev/null
if grep -q 'force-stop com.evil.app' "$T/am.log"; then echo "FAIL fail-closed cleanup"; fail=$((fail+1)); else echo "PASS fail-closed cleanup"; pass=$((pass+1)); fi
fgc_freeze com.evil.app >/dev/null
if grep -q 'disable-user.*com.evil.app' "$T/pm.log"; then echo "FAIL fail-closed freeze"; fail=$((fail+1)); else echo "PASS fail-closed freeze"; pass=$((pass+1)); fi
mv "$T/whitelist.hide" "$T/data/config/whitelist.txt"
# config list parser: comments, blank lines, '!disabled' markers, duplicates and
# a MISSING file must all be handled deterministically (no crash, no wrong list).
cp "$T/data/config/blacklist.txt" "$T/bl.save"
printf '# comment line\n\ncom.a.app\n!com.b.app\ncom.a.app\n' > "$T/data/config/blacklist.txt"
out=$($CLI list blacklist)
if printf '%s\n' "$out" | grep -qx 'com.a.app' && printf '%s\n' "$out" | grep -qx '!com.b.app' && ! printf '%s\n' "$out" | grep -q 'comment'; then echo "PASS list parser comment/blank/disabled"; pass=$((pass+1)); else echo "FAIL list parser -- got: [$out]"; fail=$((fail+1)); fi
if [ "$(printf '%s\n' "$out" | grep -c '^com\.a\.app$')" = "1" ]; then echo "PASS list parser dedupes"; pass=$((pass+1)); else echo "FAIL list parser dedupe -- got: [$out]"; fail=$((fail+1)); fi
cp "$T/bl.save" "$T/data/config/blacklist.txt"
mv "$T/data/config/whitelist.txt" "$T/wl.hide2"
out=$($CLI list whitelist)
if [ -z "$out" ]; then echo "PASS missing list -> empty"; pass=$((pass+1)); else echo "FAIL missing list -- got: [$out]"; fail=$((fail+1)); fi
mv "$T/wl.hide2" "$T/data/config/whitelist.txt"

echo "--- $pass pass, $fail fail ---"
exit $fail
