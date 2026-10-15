#!/system/bin/sh
# device.sh — device info, detected only. Missing values => "Unknown"/"Not detected".
# Never hardcoded, never required for core/UI to function. Sourced, not executed.

FGC_MODDIR="${FGC_MODDIR:-${0%/*}/..}"

fgc_prop() { getprop "$1" 2>/dev/null | head -n1; }

fgc_root_manager() {
  # Detect Magisk / KernelSU / APatch by presence + version query. Best effort.
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
  # sanitize quotes/newlines
  _man="$(printf '%s' "$_man" | tr -d '\n\r"')"; _mod="$(printf '%s' "$_mod" | tr -d '\n\r"')"
  _and="$(printf '%s' "$_and" | tr -d '\n\r"')"; _sdk="$(printf '%s' "$_sdk" | tr -d '\n\r"')"
  _root="$(printf '%s' "$_root" | tr -d '\n\r"')"
  printf '{"manufacturer":"%s","model":"%s","android":"%s","sdk":"%s","root":"%s"}' \
    "$_man" "$_mod" "$_and" "$_sdk" "$_root"
}
case "$0" in *device.sh) fgc_device_json; echo ;; esac
