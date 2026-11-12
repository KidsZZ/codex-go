import 'dart:convert';
import 'dart:io';

/// 只供发布 CI 使用：从 Secrets 创建临时签名配置，不输出任何秘密值。
void main() {
  const names = [
    'ANDROID_KEYSTORE_BASE64',
    'ANDROID_KEYSTORE_PASSWORD',
    'ANDROID_KEY_ALIAS',
    'ANDROID_KEY_PASSWORD',
  ];
  final environment = Platform.environment;
  final missing = names.where((name) => environment[name]?.isNotEmpty != true);
  if (missing.isNotEmpty) {
    stderr.writeln('缺少发布 Secrets：${missing.join(', ')}');
    exitCode = 64;
    return;
  }
  final root = File.fromUri(Platform.script).parent.parent;
  final properties = File('${root.path}/android/key.properties');
  final keystore = File('${root.path}/build/ci-signing/release.jks');
  if (properties.existsSync() || keystore.existsSync()) {
    stderr.writeln('签名配置或密钥已存在，拒绝覆盖。');
    exitCode = 73;
    return;
  }
  try {
    final bytes = base64.decode(
      environment['ANDROID_KEYSTORE_BASE64']!.replaceAll(RegExp(r'\s+'), ''),
    );
    if (bytes.isEmpty) throw const FormatException();
    keystore.parent.createSync(recursive: true);
    keystore.writeAsBytesSync(bytes, flush: true);
    final values = {
      'storeFile': keystore.absolute.path,
      'storePassword': environment['ANDROID_KEYSTORE_PASSWORD']!,
      'keyAlias': environment['ANDROID_KEY_ALIAS']!,
      'keyPassword': environment['ANDROID_KEY_PASSWORD']!,
    };
    properties.writeAsStringSync(
      values.entries
          .map((entry) => '${entry.key}=${_property(entry.value)}\n')
          .join(),
      flush: true,
    );
    stdout.writeln('临时发布签名配置已生成。');
  } on FormatException {
    stderr.writeln('ANDROID_KEYSTORE_BASE64 不是有效的非空 Base64 密钥。');
    exitCode = 65;
  } on FileSystemException {
    stderr.writeln('无法写入临时签名文件，请检查工作目录权限。');
    exitCode = 73;
  }
}

/// Java Properties 使用独立的转义规则，密码中的空格、反斜杠和中文不能被改写。
String _property(String value) => value.codeUnits
    .map(
      (unit) => switch (unit) {
        0x5c => r'\\',
        0x0a => r'\n',
        0x0d => r'\r',
        0x09 => r'\t',
        0x0c => r'\f',
        0x20 ||
        0x3d ||
        0x3a ||
        0x23 ||
        0x21 => '\\${String.fromCharCode(unit)}',
        _ when unit < 0x20 || unit > 0x7e =>
          '\\u${unit.toRadixString(16).padLeft(4, '0')}',
        _ => String.fromCharCode(unit),
      },
    )
    .join();
