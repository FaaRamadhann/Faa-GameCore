#!/system/bin/sh
# customize.sh — install-time setup for Faa GameCore
MODDIR=${0%/*}

ui_print "- Faa GameCore installing..."
mkdir -p "$MODDIR/config" "$MODDIR/state" "$MODDIR/logs" "$MODDIR/core" "$MODDIR/webroot" "$MODDIR/bin"

# Seed default configs only if missing (never overwrite user config on update)
for f in config.json gamelist.json blacklist.txt whitelist.txt; do
  if [ ! -f "$MODDIR/config/$f" ] && [ -f "$MODDIR/config/$f.example" ]; then
    cp "$MODDIR/config/$f.example" "$MODDIR/config/$f"
  fi
done
# Persistent user data: /data/adb/fgc (survives module updates).
# Seeds/imports/links via core/data_init.sh — never overwrites existing files.
# Module-file guard uses readdir (ls+grep), not test -f: stat() on module
# paths can flake during Magisk mount churn while readdir+open keep working.
if ls "$MODDIR/core" 2>/dev/null | grep -qx 'data_init.sh'; then
  . "$MODDIR/core/data_init.sh"
  if fgc_data_init "$MODDIR" "/data/adb/modules/faagamecore"; then
    ui_print "- Data persisten: /data/adb/fgc (aman dari update)"
  else
    ui_print "! Peringatan: inisialisasi data gagal, memakai default modul"
  fi
fi
# Install-time launcher probe = REPORTING ONLY. The detected launcher is
# protected dynamically at boot through state/protected_extra.txt
# (core/caps.sh -> core/policy_engine.sh), so install never writes to the
# user's whitelist: a module update must not modify /data/adb/fgc config at all.
_LAUNCHER=""
if command -v cmd >/dev/null 2>&1; then
  _LAUNCHER="$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | grep -m1 '/' | cut -d/ -f1)"
fi
case "$_LAUNCHER" in ''|*[!a-zA-Z0-9._]*) _LAUNCHER="" ;; esac
if [ -n "$_LAUNCHER" ]; then
  ui_print "- Launcher: $_LAUNCHER (dilindungi otomatis saat boot; whitelist tidak diubah)"
else
  ui_print "- Launcher belum terdeteksi; FGC mendeteksinya saat boot (recovery)"
fi

set_perm_recursive "$MODDIR/core" 0 0 0755 0755
set_perm "$MODDIR/service.sh" 0 0 0755
set_perm "$MODDIR/action.sh" 0 0 0755
set_perm "$MODDIR/uninstall.sh" 0 0 0755

ui_print "- Done. Open WebUI from the Magisk app to configure."
