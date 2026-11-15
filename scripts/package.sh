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

# 通过 XCODE_XCCONFIG_FILE 环境变量给「所有 target（含 SwiftPM 依赖包）」注入设置：
# 命令行 -setting 对 package target 不生效，只有这个机制能关掉 TDLibKit 的整包优化（WMO），
# 否则单个 WMO 编译单元会吃掉 10GB+ 内存被系统杀掉。
cat > /tmp/ci-overrides.xcconfig <<'XCCONFIG'
SWIFT_COMPILATION_MODE = singlefile
SWIFT_OPTIMIZATION_LEVEL = -O
XCCONFIG
export XCODE_XCCONFIG_FILE=/tmp/ci-overrides.xcconfig
# -jobs 1 限制并行编译目标数，降低内存峰值。
# 失败自动重试（增量编译，第二次直接复用已编译产物，成功率更高）。
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
ls -l "$IPA"
shasum -a 256 "$IPA"
if [ -n "${SIMZIP:-}" ]; then ls -l "$SIMZIP"; shasum -a 256 "$SIMZIP"; fi
