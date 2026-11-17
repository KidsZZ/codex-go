import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 从最终签名 APK 的 aapt 输出生成元数据，避免手填版本与产物发生偏差。
Future<void> main(List<String> args) async {
  if (args.length != 2) throw ArgumentError('需要 APK 路径和 aapt badging 文件');
  final apk = File(args[0]);
  final badging = File(args[1]).readAsStringSync();
  String field(String pattern) =>
      RegExp(pattern, multiLine: true).firstMatch(badging)?.group(1) ??
      (throw StateError('APK 缺少字段：$pattern'));
  final package = field(r"^package: name='([^']+)'");
  final versionCode = int.parse(field(r"^package: .*versionCode='([0-9]+)'"));
  final version = field(r"^package: .*versionName='([^']+)'");
  final minSdk = int.parse(field(r"^sdkVersion:'([0-9]+)'"));
  final abi = field(r"^native-code: '([^']+)'$");
  final channel = Platform.environment['CODEX_GO_CHANNEL'] ?? 'release';
  if (!{'beta', 'release'}.contains(channel) ||
      package !=
          (channel == 'beta' ? 'dev.codexgo.app.beta' : 'dev.codexgo.app') ||
      abi != 'arm64-v8a' ||
      versionCode <= 0 ||
      !RegExp(r'^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$').hasMatch(version)) {
    throw StateError('正式 APK 的应用身份、架构或版本无效');
  }
  final name = apk.uri.pathSegments.last;
  if (name != 'codex-go-$version-arm64-v8a-$channel.apk') {
    throw StateError('APK 文件名与版本不匹配');
  }
  final metadata = {
    'schemaVersion': 1,
    'channel': channel,
    'sourceCommit': Platform.environment['CODEX_GO_SOURCE_COMMIT'] ?? '',
    'sourceBeta': Platform.environment['CODEX_GO_SOURCE_BETA'] ?? '',
    'packageName': package,
    'versionName': version,
    'versionCode': versionCode,
    'minSdk': minSdk,
    'abi': abi,
    'file': name,
    'size': await apk.length(),
    'sha256': (await sha256.bind(apk.openRead()).first).toString(),
  };
  await File(
    '${apk.parent.path}/update.json',
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(metadata)}\n');
  stdout.writeln('已生成更新元数据：${apk.parent.path}/update.json');
}
