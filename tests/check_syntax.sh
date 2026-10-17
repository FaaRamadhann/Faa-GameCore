#!/system/bin/sh
# check_syntax.sh — POSIX syntax check for all shell files (runs on-device sh too)
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
for f in customize.sh service.sh action.sh uninstall.sh tools/version.sh core/*.sh system/bin/* tests/check_syntax.sh tests/test_core.sh; do
  if sh -n "$f"; then echo "PASS syntax $f"; pass=$((pass+1)); else echo "FAIL syntax $f"; fail=$((fail+1)); fi
done
# mksh portability lint: inside a ${...} expansion a bare '|' means PATTERN
# ALTERNATION on Android's /system/bin/sh — a #/% strip then silently returns
# the string unchanged (or empties it). bash tolerates it, which is exactly how
# this class of bug slips past local (bash) test runs. Full-line comments are
# skipped so the hazard can still be documented.
_unsafe=""
for f in customize.sh service.sh action.sh uninstall.sh tools/version.sh core/*.sh system/bin/*; do
  # pattern uses a bracket class for '$' and a bare '{': GNU grep rejects
  # '\{' without a matching '\}' ("Unmatched \{"), toybox grep is fine with
  # either — '[$]{' is portable across both.
  if grep -v '^[[:space:]]*#' "$f" 2>/dev/null | grep -q '[$]{[^}]*|'; then _unsafe="$_unsafe $f"; fi
done
if [ -z "$_unsafe" ]; then
  echo "PASS mksh-safe \${...} expansions"; pass=$((pass+1))
else
  echo "FAIL mksh-unsafe '\${...|...}' in:$_unsafe"; fail=$((fail+1))
fi
echo "--- $pass pass, $fail fail ---"
exit $fail
