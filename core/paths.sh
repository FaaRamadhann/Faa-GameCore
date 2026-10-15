#!/system/bin/sh
# paths.sh — canonical data locations for user DATA.
# $FGC_MODDIR may differ per caller identity (Magisk mirror paths, update
# dirs, manual copies), which once caused split state + duplicate daemons.
# Code lives under $FGC_MODDIR; user DATA always lives here (absolute).
# Source AFTER setting FGC_MODDIR. Sourced, not executed. No pipes, no forks.
FGC_DATA="${FGC_DATA:-/data/adb/fgc}"
FGC_CONFIG="$FGC_DATA/config"
FGC_STATE="$FGC_DATA/state"
FGC_LOGS="$FGC_DATA/logs"
