#!/usr/bin/env bash
# 统一开发预览和正式签名构建入口；工具链从环境读取，不绑定开发者目录。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mode=release
signed=false
pub=true
for arg in "$@"; do
  case "$arg" in
    --debug) mode=debug ;;
    --signed) signed=true ;;
    --no-pub) pub=false ;;
    *) echo "用法：tool/build_android.sh [--debug] [--signed] [--no-pub]" >&2; exit 64 ;;
  esac
done
command -v flutter >/dev/null || { echo '缺少 Flutter，请先配置 PATH。' >&2; exit 69; }
if "$signed" && [[ $mode != release ]]; then
  echo '--signed 仅用于正式 release 构建。' >&2
  exit 64
fi
if "$signed" && [[ ! -f android/key.properties ]]; then
  echo '正式签名构建需要 android/key.properties 以及对应的签名文件。' >&2
  exit 66
fi
if "$pub"; then flutter pub get; fi
flutter build apk "--$mode" --target-platform android-arm64 --split-per-abi --no-pub
version=$(sed -n 's/^version: *\([^+ ]*\).*/\1/p' pubspec.yaml)
mkdir -p build/artifacts
artifact="build/artifacts/codex-go-$version-arm64-v8a.apk"
cp "build/app/outputs/flutter-apk/app-arm64-v8a-$mode.apk" "$artifact"
sha256sum "$artifact"
