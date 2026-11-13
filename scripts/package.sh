#!/bin/bash
# Unsigned Release packages for sideloading (AltStore / Sideloadly re-sign on install).
#   scripts/package.sh [outdir]   → STV-<ver>-unsigned.ipa  +  STV-<ver>-simulator.app.zip
# Version comes from project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-$PWD/dist}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
VER=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
BUILD=$(awk -F'"' '/CURRENT_PROJECT_VERSION/{print $2; exit}' project.yml)
xcodegen generate >/dev/null
common=(-project STV.xcodeproj -scheme STV -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")

xcodebuild "${common[@]}" -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath DerivedDataRelease build 2>&1 | tee /tmp/stv-package-ios.log
xcodebuild "${common[@]}" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedDataRelease build 2>&1 | tee /tmp/stv-package-sim.log

STAGE=$(mktemp -d)
mkdir -p "$STAGE/Payload"
cp -R DerivedDataRelease/Build/Products/Release-iphoneos/STV.app "$STAGE/Payload/"
NAME="${STV_PKG_NAME:-$VER}"
IPA="$OUT/STV-$NAME-unsigned.ipa"
rm -f "$IPA"; (cd "$STAGE" && zip -qry "$IPA" Payload)
SIMZIP="$OUT/STV-$NAME-simulator.app.zip"
rm -f "$SIMZIP"; (cd DerivedDataRelease/Build/Products/Release-iphonesimulator && zip -qry "$SIMZIP" STV.app)
rm -rf "$STAGE"
echo "version $VER ($BUILD)"
ls -l "$IPA" "$SIMZIP"
shasum -a 256 "$IPA" "$SIMZIP"
