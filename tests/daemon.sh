#!/usr/bin/env bash
# tests/daemon.sh — real daemon lifecycle: start, single-instance, clean stop.
# Uses FGC_MAX_ITER for bounded runs (production default = infinite).
cd "$(dirname "$0")/.." || exit 1
export MSYS=winsymlinks:native
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/mod" "$T/bin"
cp module.prop "$T/mod/"; cp -r core config system "$T/mod/"
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
# 1. daemon starts, holds lock, logs core-started, exits cleanly after N iters
bash "$M/core/main.sh" "$M" > "$T/d1.log" 2>&1 &
DPID=$!
sleep 4
if [ -d "$T/data/state/daemon.lock" ]; then echo "PASS daemon holds lock"; pass=$((pass+1)); else echo "FAIL daemon holds lock"; fail=$((fail+1)); fi
wait $DPID
if [ ! -d "$T/data/state/daemon.lock" ]; then echo "PASS lock released on exit"; pass=$((pass+1)); else echo "FAIL lock released"; rm -rf "$T/data/state/daemon.lock" 2>/dev/null; fail=$((fail+1)); fi
if grep -q 'core-started' "$T/data/logs/session.log" 2>/dev/null || grep -q 'core-started' "$M/logs/session.log" 2>/dev/null; then echo "PASS core-started logged"; pass=$((pass+1)); else echo "FAIL core-started logged"; fail=$((fail+1)); fi
# 2. duplicate start refused while running
export FGC_MAX_ITER=4
bash "$M/core/main.sh" "$M" > "$T/d2.log" 2>&1 &
DPID=$!
sleep 4
OUT2=$(FGC_MAX_ITER=1 bash "$M/core/main.sh" "$M" 2>&1)
wait $DPID
if [[ "$OUT2" == *"already running"* ]]; then echo "PASS duplicate refused"; pass=$((pass+1)); else echo "FAIL duplicate refused -- got: $OUT2"; fail=$((fail+1)); fi
n=$(grep -c 'core-started' "$T/data/logs/session.log" 2>/dev/null || true); [ -z "$n" ] && n=0
if [ "$n" -eq 2 ]; then echo "PASS dup adds no daemon log"; pass=$((pass+1)); else echo "FAIL dup log (n=$n)"; fail=$((fail+1)); fi
# 3. service.sh must RETURN immediately (the WebUI "Restart core" bridge reads
# until EOF: a long-lived child holding the pipe would hang the button forever).
_s0=$(date +%s)
bash "$M/service.sh" >/dev/null 2>&1
_s1=$(date +%s)
if [ $((_s1-_s0)) -le 5 ]; then echo "PASS service returns immediately"; pass=$((pass+1)); else echo "FAIL service blocked for $((_s1-_s0))s"; fail=$((fail+1)); fi
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
echo "--- $pass pass, $fail fail ---"
exit $fail
