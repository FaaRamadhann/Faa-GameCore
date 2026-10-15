#!/system/bin/sh
# action.sh — Magisk "Action" button: prints brief status (shown in Magisk app log view)
MODDIR=${0%/*}
sh "$MODDIR/core/fgc-cli.sh" status 2>&1
