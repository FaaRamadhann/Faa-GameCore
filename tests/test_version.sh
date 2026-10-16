#!/system/bin/sh
# tests/test_version.sh — version.sh obeys the single-digit rollover rule:
# 1.1.9 -> 1.2.0 (never 1.1.10); 1.2.9 -> 1.3.0. versionCode always +1.
cd "${0%/*}/.." || exit 1
T=$(mktemp -d 2>/dev/null) || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/proj/sub"
cp tools/version.sh "$T/proj/sub/v.sh"
fail=0
t() {
  printf 'version=%s\nversionCode=%s\n' "$1" "$2" > "$T/proj/module.prop"
  (cd "$T/proj/sub" && sh ./v.sh "$3" >/dev/null 2>&1)
  got_v=$(grep -m1 '^version=' "$T/proj/module.prop" | cut -d= -f2)
  got_c=$(grep -m1 '^versionCode=' "$T/proj/module.prop" | cut -d= -f2)
  if [ "$got_v" = "$4" ] && [ "$got_c" = "$(($2+1))" ]; then echo "PASS version $1 +$3 -> $got_v ($got_c)"; else echo "FAIL version $1 +$3 -> $got_v ($got_c), want $4"; fail=1; fi
}
t 1.1.9 120 patch 1.2.0
t 1.2.0 121 patch 1.2.1
t 1.2.9 129 patch 1.3.0
t 1.2.3 125 minor 1.3.0
t 1.2.3 125 major 2.0.0
exit $fail
