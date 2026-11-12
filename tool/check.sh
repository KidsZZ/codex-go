#!/usr/bin/env bash
# 本地与 CI 共用检查入口；本地化生成文件不参与手工格式检查。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v flutter >/dev/null || { echo '缺少 Flutter，请先配置 PATH。' >&2; exit 69; }
flutter gen-l10n
dart format --output=none --set-exit-if-changed \
  lib/app lib/domain lib/features lib/infrastructure lib/runtime lib/shared \
  lib/l10n/strings.dart lib/main.dart tool/configure_signing.dart
flutter analyze --no-pub
