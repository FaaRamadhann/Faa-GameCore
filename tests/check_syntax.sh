#!/system/bin/sh
# check_syntax.sh — POSIX syntax check for all shell files (runs on-device sh too)
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
for f in customize.sh service.sh action.sh uninstall.sh tools/version.sh core/*.sh system/bin/* tests/check_syntax.sh tests/test_core.sh; do
  if sh -n "$f"; then echo "PASS syntax $f"; pass=$((pass+1)); else echo "FAIL syntax $f"; fail=$((fail+1)); fi
done
echo "--- $pass pass, $fail fail ---"
exit $fail
