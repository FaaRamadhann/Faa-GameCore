#!/usr/bin/env bash
# tests/daemon.sh — real daemon lifecycle: start, single-instance, clean stop.
# Uses FGC_MAX_ITER for bounded runs (production default = infinite).
cd "$(dirname "$0")/.." || exit 1
export MSYS=winsymlinks:native
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod" "$T/bin"
cp module.prop service.sh action.sh "$T/mod/"; cp -r core config system "$T/mod/"
M="$T/mod"
export FGC_MODDIR="$M" FGC_DATA="$T/data" FGC_MAX_ITER=4
cat > "$T/bin/getprop" <<'EOF'
#!/usr/bin/env bash
case "$1" in sys.boot_completed) echo "${STUB_BOOT:-1}" ;; esac
EOF
cat > "$T/bin/pm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/dumpsys" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$T/bin/am" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
bash "$M/core/data_init.sh"

pass=0; fail=0
# wait_for <file/dir> <seconds> — Git-Bash forks are slow (~2.5s just to source
# the core on Windows), so fixed sleeps made these tests flaky under load.
wait_for() {
  _i=0
  while [ "$_i" -lt $(( $2 * 4 )) ]; do
    [ -e "$1" ] && return 0
    _i=$((_i+1)); sleep 0.25
  done
  return 1
}
# 1. daemon starts, holds lock, logs core-started, exits cleanly after N iters
bash "$M/core/main.sh" "$M" > "$T/d1.log" 2>&1 &
DPID=$!
wait_for "$T/data/state/daemon.lock" 20
if [ -d "$T/data/state/daemon.lock" ]; then echo "PASS daemon holds lock"; pass=$((pass+1)); else echo "FAIL daemon holds lock"; fail=$((fail+1)); fi
wait $DPID
if [ ! -d "$T/data/state/daemon.lock" ]; then echo "PASS lock released on exit"; pass=$((pass+1)); else echo "FAIL lock released"; rm -rf "$T/data/state/daemon.lock" 2>/dev/null; fail=$((fail+1)); fi
if grep -q 'core-started' "$T/data/logs/session.log" 2>/dev/null || grep -q 'core-started' "$M/logs/session.log" 2>/dev/null; then echo "PASS core-started logged"; pass=$((pass+1)); else echo "FAIL core-started logged"; fail=$((fail+1)); fi
# 2. duplicate start refused while running
export FGC_MAX_ITER=4
bash "$M/core/main.sh" "$M" > "$T/d2.log" 2>&1 &
DPID=$!
wait_for "$T/data/state/daemon.lock" 20
sleep 2
OUT2=$(FGC_MAX_ITER=1 bash "$M/core/main.sh" "$M" 2>&1)
wait $DPID
if [[ "$OUT2" == *"already running"* ]]; then echo "PASS duplicate refused"; pass=$((pass+1)); else echo "FAIL duplicate refused -- got: $OUT2"; fail=$((fail+1)); fi
n=$(grep -c 'core-started' "$T/data/logs/session.log" 2>/dev/null || true); [ -z "$n" ] && n=0
if [ "$n" -eq 2 ]; then echo "PASS dup adds no daemon log"; pass=$((pass+1)); else echo "FAIL dup log (n=$n)"; fail=$((fail+1)); fi
# 3. service.sh must RETURN immediately (the WebUI "Restart core" bridge reads
# until EOF: a long-lived child holding the pipe would hang the button forever).
# The bound is generous because service.sh scans /proc and each fork costs ~30ms
# on Windows; on-device the same scan is milliseconds.
_s0=$(date +%s)
bash "$M/service.sh" >/dev/null 2>&1
_s1=$(date +%s)
if [ $((_s1-_s0)) -le 30 ]; then echo "PASS service returns immediately"; pass=$((pass+1)); else echo "FAIL service blocked for $((_s1-_s0))s"; fail=$((fail+1)); fi
# service.sh started a real (unbounded) supervisor: kill it, or it keeps the
# lock and every later supervisor test is silently a no-op.
for _p in $(ps -ef 2>/dev/null | grep -E "$M/core/(main|supervise).sh" | grep -v grep | awk '{print $2}'); do kill -9 "$_p" 2>/dev/null; done
sleep 2
rm -rf "$T/data/state/daemon.lock" "$T/data/state/supervise.lock"
# 3b. the supervisor really restarts a crashed core. Run it in the FOREGROUND
# (bounded by FGC_SUPERVISE_MAX): this host kills a background child as soon as
# the parent shell exits, unlike Android/Magisk — so backgrounding here would
# only test the harness. FGC_MAX_ITER must be UNSET (it means "bounded run, no
# supervision"). kill -9 leaves a stale lock behind on purpose.
unset FGC_MAX_ITER
export FGC_SUPERVISE_MAX=2
rm -rf "$T/data/state/daemon.lock" 2>/dev/null
sh "$M/core/supervise.sh" > "$T/sup.log" 2>&1 &
SUP=$!
sleep 8
_p1=$(cat "$T/data/state/daemon.lock/pid" 2>/dev/null)
kill -9 "$_p1" 2>/dev/null
sleep 20
_p2=$(cat "$T/data/state/daemon.lock/pid" 2>/dev/null)
if [ -n "$_p1" ] && [ -n "$_p2" ] && [ "$_p1" != "$_p2" ]; then echo "PASS core restarted after crash"; pass=$((pass+1)); else echo "FAIL core restarted after crash (p1=$_p1 p2=$_p2)"; fail=$((fail+1)); fi
# the stale lock left by kill -9 must be reclaimed, not treated as a live daemon
kill -9 "$_p2" 2>/dev/null
wait $SUP 2>/dev/null
rm -rf "$T/data/state/daemon.lock" 2>/dev/null
unset FGC_SUPERVISE_MAX
export FGC_MAX_ITER=1
# 4. stale daemon lock (dead pid) never wedges startup
mkdir -p "$T/data/state/daemon.lock"
printf '99999999' > "$T/data/state/daemon.lock/pid"
export FGC_MAX_ITER=1
OUTS=$(bash "$M/core/main.sh" "$M" 2>&1)
if [[ "$OUTS" != *"already running"* ]]; then echo "PASS stale lock cleared"; pass=$((pass+1)); else echo "FAIL stale lock -- got: $OUTS"; fail=$((fail+1)); fi
# 5. fgc_run_timed bounds hanging commands
. "$M/core/str.sh"
_s0=$(date +%s)
fgc_run_timed 1 sleep 5 >/dev/null 2>&1; _rc=$?
_s1=$(date +%s)
if [ "$_rc" -eq 124 ] && [ $((_s1-_s0)) -le 3 ]; then echo "PASS run_timed bounds"; pass=$((pass+1)); else echo "FAIL run_timed (rc=$_rc dt=$((_s1-_s0)))"; fail=$((fail+1)); fi
# 6. commands inherit stdin=/dev/null: pm/cmd are app_process wrappers that
# cannot read adb_data_file, and unfreeze loops read frozen.txt on stdin. An
# inherited file there made EVERY pm enable fail ("Failed transaction") and left
# the app disabled after the game closed.
cat > "$T/bin/stdinprobe" <<'EOF'
#!/usr/bin/env bash
if [ -f /dev/stdin ]; then echo FILE; else echo NULL; fi
EOF
chmod +x "$T/bin/stdinprobe"
: > "$T/data/state/frozen.txt"
_r1=$(printf 'x\n' | fgc_run_timed 5 stdinprobe)
_r2=$(fgc_run_timed 5 stdinprobe < "$T/data/state/frozen.txt")
if [ "$_r1" = "NULL" ] && [ "$_r2" = "NULL" ]; then echo "PASS run_timed forces /dev/null stdin"; pass=$((pass+1)); else echo "FAIL stdin leaked (pipe=$_r1 file=$_r2)"; fail=$((fail+1)); fi
# 7. supervisor is a singleton: a second one must refuse to start, or every
# "Restart core" adds a supervisor that races to restart the same daemon.
# FGC_MAX_ITER bounds the INNER daemon (otherwise main.sh runs forever and the
# supervisor never returns from its foreground start).
export FGC_MAX_ITER=6
export FGC_SUPERVISE_MAX=1
rm -rf "$T/data/state/supervise.lock" "$T/data/state/daemon.lock"
sh "$M/core/supervise.sh" > "$T/sup2.log" 2>&1 &
SUP2=$!
sleep 5
_l1=$(cat "$T/data/state/supervise.lock/pid" 2>/dev/null)
sh "$M/core/supervise.sh" > "$T/sup3.log" 2>&1; _rc2=$?
_l2=$(cat "$T/data/state/supervise.lock/pid" 2>/dev/null)
if [ "$_rc2" = "0" ] && [ -n "$_l1" ] && [ "$_l1" = "$_l2" ]; then echo "PASS supervisor singleton"; pass=$((pass+1)); else echo "FAIL supervisor singleton (rc=$_rc2 l1=$_l1 l2=$_l2)"; fail=$((fail+1)); fi
kill -9 "$SUP2" 2>/dev/null
wait $SUP2 2>/dev/null
# a SIGKILLed supervisor leaves a stale lock; the next one must reclaim it.
# Bounded mode (FGC_MAX_ITER) never touches the lock, so this has to run a real
# supervisor: keep FGC_MAX_ITER set (bounds the inner daemon) but no SUPERVISE_MAX.
export FGC_MAX_ITER=6
unset FGC_SUPERVISE_MAX
_old=$(cat "$T/data/state/supervise.lock/pid" 2>/dev/null)
rm -rf "$T/data/state/daemon.lock"
sh "$M/core/supervise.sh" > "$T/sup4.log" 2>&1 &
SUP4=$!
sleep 12
_new=$(cat "$T/data/state/supervise.lock/pid" 2>/dev/null)
if [ -n "$_new" ] && [ "$_new" != "$_old" ] && [ -r "/proc/$_new/cmdline" ]; then echo "PASS stale supervisor lock reclaimed"; pass=$((pass+1)); else echo "FAIL stale supervisor lock (old=$_old new=$_new) -- got: $(cat "$T/sup4.log")"; fail=$((fail+1)); fi
kill -9 "$SUP4" 2>/dev/null
wait $SUP4 2>/dev/null
rm -rf "$T/data/state/supervise.lock" "$T/data/state/daemon.lock"
unset FGC_SUPERVISE_MAX
# 8. concurrent starts must leave exactly ONE daemon. The old lock code treated
# "lock dir exists but pid not written yet" as stale, so every racing starter
# rm -rf'd the winner's lock and ran too (on-device: 5 concurrent main.sh, each
# unfreezing and racing the others).
export FGC_MAX_ITER=20
rm -rf "$T/data/state/daemon.lock"
# clear leftovers from the supervisor tests first, or they count as extra daemons
for _p in $(ps -ef 2>/dev/null | grep 'core/main.sh' | grep -v grep | awk '{print $2}'); do kill -9 "$_p" 2>/dev/null; done
sleep 2
rm -rf "$T/data/state/daemon.lock"
i=0
while [ "$i" -lt 5 ]; do i=$((i+1)); bash "$M/core/main.sh" "$M" >/dev/null 2>&1 & done
sleep 8
_dn=$(ps -ef 2>/dev/null | grep 'core/main.sh' | grep -v grep | wc -l | tr -d ' ')
if [ "$_dn" = "1" ]; then echo "PASS concurrent starts leave one daemon"; pass=$((pass+1)); else echo "FAIL concurrent starts (daemons=$_dn)"; fail=$((fail+1)); fi
for _p in $(ps -ef 2>/dev/null | grep 'core/main.sh' | grep -v grep | awk '{print $2}'); do kill -9 "$_p" 2>/dev/null; done
rm -rf "$T/data/state/daemon.lock"
# 9. "Restart core" must converge to exactly one supervisor + one daemon, every
# time. Replacing the supervisor on each restart is what used to leave two of
# them: a supervisor can fork its daemon right after the scan that decided it
# was gone. service.sh therefore only replaces the DAEMON when a live supervisor
# exists, and the supervisor re-execs itself when its own file changes.
unset FGC_MAX_ITER
# The invariant is "one live supervisor owning one live daemon", so assert it from
# the locks + /proc rather than counting `ps` lines: a $(...) fork keeps main.sh's
# argv until it execs and would look like an extra daemon.
settle() {
  _i=0
  while [ "$_i" -lt 60 ]; do
    _sp=$(cat "$T/data/state/supervise.lock/pid" 2>/dev/null)
    _d=$(cat "$T/data/state/daemon.lock/pid" 2>/dev/null)
    if [ -n "$_sp" ] && [ -n "$_d" ] \
       && tr '\0' ' ' < "/proc/$_sp/cmdline" 2>/dev/null | grep -q 'core/supervise.sh' \
       && tr '\0' ' ' < "/proc/$_d/cmdline" 2>/dev/null | grep -q 'core/main.sh'; then
      [ "$(ps -ef | awk -v p="$_sp" '$3==p' | grep -c 'core/main.sh')" = "1" ] && return 0
    fi
    _i=$((_i+1)); sleep 0.5
  done
  return 1
}
bash "$M/service.sh" >/dev/null 2>&1
settle && { echo "PASS cold start 1/1"; pass=$((pass+1)); } || { echo "FAIL cold start"; fail=$((fail+1)); }
_r=0
while [ "$_r" -lt 4 ]; do
  _r=$((_r+1))
  bash "$M/service.sh" >/dev/null 2>&1
  settle && { echo "PASS restart$_r converges 1/1"; pass=$((pass+1)); } || { echo "FAIL restart$_r"; fail=$((fail+1)); }
done
# a daemon stuck in a long call ignores TERM; the epoch must retire it and the
# supervisor must bring a fresh one back — never two at once
_dpid=$(cat "$T/data/state/daemon.lock/pid" 2>/dev/null)
kill -STOP "$_dpid" 2>/dev/null
bash "$M/service.sh" >/dev/null 2>&1
sleep 1
kill -CONT "$_dpid" 2>/dev/null
sleep 15
if settle && [ "$(cat "$T/data/state/daemon.lock/pid" 2>/dev/null)" != "$_dpid" ]; then echo "PASS stopped daemon retired"; pass=$((pass+1)); else echo "FAIL stopped daemon (pid $_dpid -> $(cat "$T/data/state/daemon.lock/pid" 2>/dev/null))"; fail=$((fail+1)); fi
for _p in $(ps -ef 2>/dev/null | grep -E "$M/core/(main|supervise).sh" | grep -v grep | awk '{print $2}'); do kill -9 "$_p" 2>/dev/null; done
rm -rf "$T/data/state/daemon.lock" "$T/data/state/supervise.lock"
echo "--- $pass pass, $fail fail ---"
exit $fail
