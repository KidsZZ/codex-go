import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:codex_go/app/codex_go_app.dart';
import 'package:codex_go/infrastructure/storage/profile_store.dart';
import 'package:codex_go/runtime/codex_runtime.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Android-SSH-Codex',
    ], await rootBundle.loadString('assets/licenses/android-ssh-codex.txt'));
    yield LicenseEntryWithLineBreaks([
      'JetBrains Mono',
    ], await rootBundle.loadString('assets/licenses/jetbrains-mono.txt'));
  });
  final runtime = CodexRuntime(store: SecureProfileStore());
  runApp(CodexGoApp(runtime: runtime));
  // 安全存储和自动重连不阻塞第一帧，错误由全局连接提示承接。
  unawaited(runtime.initialize());
}
