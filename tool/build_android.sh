#!/usr/bin/env bash
# 渠道决定应用身份；签名决定是否允许更新。展示版本和构建号由发布入口统一分配。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=release
kind=preview
signed=false
pub=true
channel=release
version=''
build_number=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) mode=debug; shift ;;
    --signed) signed=true; shift ;;
    --no-pub) pub=false; shift ;;
    --channel) channel="${2:?缺少渠道}"; shift 2 ;;
    --version) version="${2:?缺少版本}"; shift 2 ;;
    --build-number) build_number="${2:?缺少构建号}"; shift 2 ;;
    *) echo '用法：tool/build_android.sh [--debug|--signed] [--no-pub] [--channel beta|release] [--version 版本 --build-number 构建号]' >&2; exit 64 ;;
  esac
done
[[ "$channel" == beta || "$channel" == release ]] || { echo '无效渠道' >&2; exit 64; }
command -v flutter >/dev/null || { echo '缺少 Flutter，请配置 PATH。' >&2; exit 69; }
if "$signed"; then
  [[ "$mode" == release && -f android/key.properties ]] || { echo '正式签名需要 release 构建与 android/key.properties。' >&2; exit 66; }
  kind="$channel"
elif [[ "$mode" == debug ]]; then kind=debug; fi
version="${version:-$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)}"
if [[ "$channel" == beta ]]; then
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]*$ ]] || { echo 'Beta 必须有 beta.N 版本后缀。' >&2; exit 65; }
else
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '正式版必须是三段数字版本。' >&2; exit 65; }
fi
options=(--build-name "$version")
if [[ -n "$build_number" ]]; then
  [[ "$build_number" =~ ^[1-9][0-9]*$ ]] || { echo '构建号必须为正整数。' >&2; exit 65; }
  options+=(--build-number "$build_number")
fi
export CODEX_GO_RELEASE_SIGNING="$signed"
export CODEX_GO_CHANNEL="$channel"
if "$pub"; then flutter pub get --enforce-lockfile; fi
flutter build apk "--$mode" --target-platform android-arm64 --split-per-abi --no-pub "${options[@]}"
source_apk="build/app/outputs/flutter-apk/app-arm64-v8a-$mode.apk"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk_root" && -f android/local.properties ]]; then sdk_root=$(sed -n 's/^sdk.dir=//p' android/local.properties); fi
signer=''
if [[ -n "$sdk_root" ]]; then
  while IFS= read -r candidate; do [[ ! -x "$candidate" ]] || signer="$candidate"; done < <(printf '%s\n' "$sdk_root"/build-tools/*/apksigner | sort -V)
fi
[[ -n "$signer" ]] || { echo '缺少 Android apksigner。' >&2; exit 69; }
certificate=$("$signer" verify --print-certs "$source_apk")
if "$signed" && [[ "$certificate" == *"CN=Android Debug"* ]]; then echo '发布不能使用调试密钥。' >&2; exit 65; fi
mkdir -p build/artifacts
filename="codex-go-$version-arm64-v8a-$kind.apk"
cp "$source_apk" "build/artifacts/$filename"
(cd build/artifacts && sha256sum "$filename" > "$filename.sha256")
if "$signed"; then
  "${signer%/apksigner}/aapt" dump badging "build/artifacts/$filename" > build/artifacts/apk-badging.txt
  dart tool/generate_update_manifest.dart "build/artifacts/$filename" build/artifacts/apk-badging.txt
fi
echo "构建完成：build/artifacts/$filename"
