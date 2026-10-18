#!/system/bin/sh
# version.sh — bump version. Usage: version.sh [major|minor|patch] (default patch)
# Project rule (do NOT forget): single-digit patch rollover.
#   1.1.9 -> next patch is 1.2.0 (NOT 1.1.10); ... 1.2.9 -> 1.3.0, etc.
cd "${0%/*}/.." || exit 1
PROP=module.prop
VER=$(grep -m1 '^version=' $PROP | cut -d= -f2)
CODE=$(grep -m1 '^versionCode=' $PROP | cut -d= -f2)
MAJ=$(echo "$VER" | cut -d. -f1); MIN=$(echo "$VER" | cut -d. -f2); PAT=$(echo "$VER" | cut -d. -f3)
case "${1:-patch}" in
  major) MAJ=$((MAJ+1)); MIN=0; PAT=0 ;;
  minor) MIN=$((MIN+1)); PAT=0 ;;
  *) PAT=$((PAT+1)); if [ "$PAT" -gt 9 ]; then PAT=0; MIN=$((MIN+1)); fi ;;
esac
NEW="$MAJ.$MIN.$PAT"; NEWCODE=$((CODE+1))
sed -i "s/^version=.*/version=$NEW/" $PROP
sed -i "s/^versionCode=.*/versionCode=$NEWCODE/" $PROP
# WebUI assets are cache-busted by versionCode: bump them together, otherwise a
# release ships ?v=<old> and the host WebView keeps running stale JS.
[ -f webroot/index.html ] && sed -i "s/?v=[0-9][0-9]*/?v=$NEWCODE/g" webroot/index.html
# app.js compares its own UI_VERSION with the version the backend reports and
# warns when they differ (a stale cached WebUI). Leaving it behind makes the
# warning fire for EVERY user on a fresh install, and reopening cannot clear it.
[ -f webroot/app.js ] && sed -i "s/var UI_VERSION = \"[0-9.]*\"/var UI_VERSION = \"$NEW\"/" webroot/app.js
echo "Bumped to $NEW ($NEWCODE)"
