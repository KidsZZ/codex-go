// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:codex_go/infrastructure/platform/diagnostics.dart';

/// Ignore transient inactive states (dialogs, notification shade, focus changes).
class ConnectionLifecycle extends WidgetsBindingObserver {
  ConnectionLifecycle({required this.onBackground, required this.onForeground});

  final VoidCallback onBackground;
  final Future<void> Function() onForeground;
  bool _background = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    Diagnostics.record('lifecycle', {'state': state.name});
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      if (_background) return;
      _background = true;
      onBackground();
    } else if (state == AppLifecycleState.resumed && _background) {
      _background = false;
      unawaited(onForeground());
    }
  }
}
