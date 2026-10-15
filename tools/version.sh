#!/system/bin/sh
# version.sh — bump PATCH version. Usage: version.sh [major|minor|patch] (default patch)
cd "${0%/*}/.." || exit 1
PROP=module.prop
VER=$(grep -m1 '^version=' $PROP | cut -d= -f2)
CODE=$(grep -m1 '^versionCode=' $PROP | cut -d= -f2)
MAJ=$(echo "$VER" | cut -d. -f1); MIN=$(echo "$VER" | cut -d. -f2); PAT=$(echo "$VER" | cut -d. -f3)
case "${1:-patch}" in
  major) MAJ=$((MAJ+1)); MIN=0; PAT=0 ;;
  minor) MIN=$((MIN+1)); PAT=0 ;;
  *) PAT=$((PAT+1)) ;;
esac
NEW="$MAJ.$MIN.$PAT"; NEWCODE=$((CODE+1))
sed -i "s/^version=.*/version=$NEW/" $PROP
sed -i "s/^versionCode=.*/versionCode=$NEWCODE/" $PROP
echo "Bumped to $NEW ($NEWCODE)"
