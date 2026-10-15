#!/usr/bin/env sh
# tests/test_core.sh — shell-level checks. python3/node steps SKIP gracefully
# when the interpreter is missing (e.g. on-device shells).
cd "${0%/*}/.." || exit 1
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
have() { command -v "$1" >/dev/null 2>&1; }
grep -q '"enabled"' config/config.json && ok "config.json keys" || bad "config.json"
if have python3; then
  python3 -c "import json;json.load(open('config/config.json'));json.load(open('config/gamelist.json'))" 2>/dev/null && ok "json valid" || bad "json valid"
else echo "SKIP json valid (no python3)"; fi
for f in core/*.sh system/bin/*; do sh -n "$f" 2>/dev/null && ok "syntax $f" || bad "syntax $f"; done
# naive-grep-proof: the substring 'eval' must not appear anywhere in core code,
# so even a crude grep-based audit cannot false-positive (dynamic exec is also
# asserted precisely by tests/test_webui.py).
if grep -r 'eval' core/ system/ 2>/dev/null; then bad "no eval substring"; else ok "no eval substring"; fi
grep -q 'PROTECTED' core/policy_engine.sh && ok "system protection" || bad "system protection"
if have node; then
  node --check webroot/app.js 2>/dev/null && ok "app.js syntax" || bad "app.js syntax"
  node --check webroot/adapters/backend.js 2>/dev/null && ok "backend.js syntax" || bad "backend.js syntax"
else echo "SKIP js syntax (no node)"; fi
if have python3; then
  python3 tests/test_webui.py || fail=1
  python3 build.py >/dev/null && ok "build zip" || bad "build zip"
else echo "SKIP python suite (no python3)"; fi
exit $fail
