// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/widgets.dart';
import 'package:codex_go/l10n/generated/app_localizations.dart';

export 'package:codex_go/l10n/generated/app_localizations.dart';

/// 文案由 ARB 统一维护；独立组件使用所在上下文的语言，不读取全局可变状态。
extension AppStringsContext on BuildContext {
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ??
      lookupAppLocalizations(
        Localizations.maybeLocaleOf(this) ?? const Locale('en'),
      );
}

/// 协议枚举仅在展示时翻译，写回服务端的标识始终保持原值。
extension AppSemanticStrings on AppLocalizations {
  String effort(String? value) => switch (value) {
    null => effortUnavailable,
    'none' => effortNone,
    'minimal' => effortMinimal,
    'low' => effortLow,
    'medium' => effortMedium,
    'high' => effortHigh,
    'xhigh' => effortXhigh,
    _ => value,
  };

  String activityStatus(String value) => switch (value) {
    'inProgress' || 'running' => running,
    'active' => statusActive,
    'completed' => completed,
    'failed' || 'errored' => failed,
    'interrupted' => interrupted,
    'paused' => statusPaused,
    'pending' || 'queued' => statusPending,
    _ => value,
  };
}
