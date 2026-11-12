#!/usr/bin/env bash
# 预览、调试与正式发布使用明确的产物名；正式签名必须主动选择。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=release
kind=preview
signed=false
pub=true
for arg in "$@"; do
  case "$arg" in
    --debug) mode=debug ;;
    --signed) signed=true ;;
    --no-pub) pub=false ;;
    *) echo '用法：tool/build_android.sh [--debug] [--signed] [--no-pub]' >&2; exit 64 ;;
  esac
done
command -v flutter >/dev/null || { echo '缺少 Flutter，请先配置 PATH。' >&2; exit 69; }
if "$signed" && [[ $mode != release ]]; then
  echo '--signed 仅用于正式 release 构建。' >&2
  exit 64
fi
if "$signed"; then
  [[ -f android/key.properties ]] || { echo '正式签名构建需要 android/key.properties 和自己的发布密钥。' >&2; exit 66; }
  kind=release
elif [[ $mode == debug ]]; then
  kind=debug
fi
# 不继承外部残留的签名开关，预览构建始终使用调试签名。
export CODEX_GO_RELEASE_SIGNING="$signed"
if "$pub"; then flutter pub get --enforce-lockfile; fi
flutter build apk "--$mode" --target-platform android-arm64 --split-per-abi --no-pub
version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
[[ -n "$version" ]] || { echo 'pubspec.yaml 缺少有效版本号。' >&2; exit 65; }
source_apk="build/app/outputs/flutter-apk/app-arm64-v8a-$mode.apk"
sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk_root" && -f android/local.properties ]]; then
  sdk_root=$(sed -n 's/^sdk.dir=//p' android/local.properties)
fi
signer=''
if [[ -n "$sdk_root" ]]; then
  while IFS= read -r candidate; do
    [[ -x "$candidate" ]] && signer="$candidate"
  done < <(printf '%s\n' "$sdk_root"/build-tools/*/apksigner | sort -V)
fi
[[ -n "$signer" ]] || { echo '缺少 Android SDK apksigner，请配置 ANDROID_HOME 与 build-tools。' >&2; exit 69; }
certificate=$("$signer" verify --print-certs "$source_apk")
if "$signed" && [[ "$certificate" == *"CN=Android Debug"* ]]; then
  echo '正式发布不能使用 Android 调试密钥，请配置自己的发布密钥。' >&2
  exit 65
fi
mkdir -p build/artifacts
filename="codex-go-$version-arm64-v8a-$kind.apk"
cp "$source_apk" "build/artifacts/$filename"
# 校验文件只包含文件名，下载到任意目录后都能用 sha256sum -c 验证。
(cd build/artifacts && sha256sum "$filename" > "$filename.sha256")
cat "build/artifacts/$filename.sha256"
echo "构建完成：build/artifacts/$filename"
