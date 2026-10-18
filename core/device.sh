#!/system/bin/sh
# device.sh — device info, detected only. Missing values => "Unknown"/"Not detected".
# Never hardcoded, never required for core/UI to function. Sourced, not executed.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"

fgc_prop() { getprop "$1" 2>/dev/null | head -n1; }

fgc_battery_pct() {
  # Prints 0-100 or nothing. sysfs first (fast, universal), dumpsys fallback.
  # FGC_BATT overrides the sysfs path (used by automated tests).
  _bf="${FGC_BATT:-/sys/class/power_supply/battery/capacity}"
  _c="$(cat "$_bf" 2>/dev/null)"
  case "$_c" in
    ''|*[!0-9]*) ;;
    *) [ "$_c" -ge 0 ] 2>/dev/null && [ "$_c" -le 100 ] 2>/dev/null && { printf '%s' "$_c"; return 0; } ;;
  esac
  # stdin from /dev/null: dumpsys (app_process) fails when stdin is a file.
  _l="$(dumpsys battery < /dev/null 2>/dev/null | grep -m1 'level:' | grep -o '[0-9][0-9]*' | head -n1)"
  case "$_l" in
    ''|*[!0-9]*) return 1 ;;
    *) [ "$_l" -le 100 ] 2>/dev/null && { printf '%s' "$_l"; return 0; } || return 1 ;;
  esac
}

fgc_root_manager() {  # Detect Magisk / KernelSU / APatch by presence + version query. Best effort.
  if command -v magisk >/dev/null 2>&1; then
    _v="$(magisk -v 2>/dev/null | head -n1)"
    [ -n "$_v" ] && { printf 'Magisk %s' "$_v"; return 0; }
    printf 'Magisk'; return 0
  fi
  if [ -f /data/adb/magisk/util_functions.sh ] || [ -d /data/adb/magisk ]; then
    printf 'Magisk'; return 0
  fi
  if command -v ksud >/dev/null 2>&1; then
    printf 'KernelSU'; return 0
  fi
  if command -v apd >/dev/null 2>&1; then
    printf 'APatch'; return 0
  fi
  printf 'Not detected'
}

fgc_device_json() {
  _man="Unknown"; _mod="Unknown"; _and="Unknown"; _sdk="Unknown"
  if command -v getprop >/dev/null 2>&1; then
    _p="$(fgc_prop ro.product.manufacturer)"; [ -n "$_p" ] && _man="$_p"
    _p="$(fgc_prop ro.product.model)";        [ -n "$_p" ] && _mod="$_p"
    _p="$(fgc_prop ro.build.version.release)"; [ -n "$_p" ] && _and="$_p"
    _p="$(fgc_prop ro.build.version.sdk)";     [ -n "$_p" ] && _sdk="$_p"
  fi
  _root="$(fgc_root_manager)"
  # sanitize quotes/newlines/commas: these are display values, and a comma would
  # split the field when the pretty printer lays the object out one key per line.
  _man="$(printf '%s' "$_man" | tr -d '\n\r",')"; _mod="$(printf '%s' "$_mod" | tr -d '\n\r",')"
  _and="$(printf '%s' "$_and" | tr -d '\n\r",')"; _sdk="$(printf '%s' "$_sdk" | tr -d '\n\r",')"
  _root="$(printf '%s' "$_root" | tr -d '\n\r",')"
  printf '{"manufacturer":"%s","model":"%s","android":"%s","sdk":"%s","root":"%s"}' \
    "$_man" "$_mod" "$_and" "$_sdk" "$_root"
}
case "$0" in *device.sh) fgc_device_json; echo ;; esac
