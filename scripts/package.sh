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

# -jobs 1 + singlefile（逐文件编译，禁用整包 WMO）：TDLibKit/AetherEngine 整包优化在 7GB 内存
# 的免费编译机上会 OOM 被静默杀掉；逐文件编译内存峰值大幅下降。
# 失败自动重试一次（增量编译，第二次直接复用已编译产物，成功率更高）。
try_build() {
  local log="$1"; shift
  local attempt=1
  until xcodebuild "$@" 2>&1 | tee "$log"; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 3 ]; then echo "build failed after 3 attempts"; return 1; fi
    echo "=== build attempt $attempt (incremental) ==="
    sleep 5
  done
}
try_build /tmp/stv-package-ios.log "${common[@]}" -jobs 1 -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath DerivedDataRelease SWIFT_COMPILATION_MODE=singlefile build
# 模拟器构建仅用于 simulator.app.zip（TrollStore 用不到），跳过以省一半编译时间与内存。
if [ "${STV_SKIP_SIM:-1}" = "0" ]; then
  try_build /tmp/stv-package-sim.log "${common[@]}" -jobs 1 -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedDataRelease SWIFT_COMPILATION_MODE=singlefile build
fi

STAGE=$(mktemp -d)
mkdir -p "$STAGE/Payload"
cp -R DerivedDataRelease/Build/Products/Release-iphoneos/STV.app "$STAGE/Payload/"
NAME="${STV_PKG_NAME:-$VER}"
IPA="$OUT/STV-$NAME-unsigned.ipa"
rm -f "$IPA"; (cd "$STAGE" && zip -qry "$IPA" Payload)
if [ "${STV_SKIP_SIM:-1}" = "0" ]; then
  SIMZIP="$OUT/STV-$NAME-simulator.app.zip"
  rm -f "$SIMZIP"; (cd DerivedDataRelease/Build/Products/Release-iphonesimulator && zip -qry "$SIMZIP" STV.app)
fi
rm -rf "$STAGE"
echo "version $VER ($BUILD)"
ls -l "$IPA" "$SIMZIP"
shasum -a 256 "$IPA" "$SIMZIP"
