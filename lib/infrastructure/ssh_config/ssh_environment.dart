// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
final _sshEnvironmentName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

enum SshEnvironmentErrorKind {
  missingEquals,
  invalidName,
  invalidValue,
  duplicateName,
}

/// 保留结构化行号与错误类型，界面可翻译提示而无需解析异常文本。
/// 不记录变量值，避免把凭据带入校验提示。
final class SshEnvironmentException extends FormatException {
  const SshEnvironmentException(
    this.kind,
    String message, {
    this.line,
    this.variable,
  }) : super(message);
  final SshEnvironmentErrorKind kind;
  final int? line;
  final String? variable;
}

bool isValidSshEnvironmentName(String name) =>
    _sshEnvironmentName.hasMatch(name);

MapEntry<String, String> parseSshEnvironmentAssignment(String assignment) {
  final separator = assignment.indexOf('=');
  if (separator < 0) {
    throw const SshEnvironmentException(
      SshEnvironmentErrorKind.missingEquals,
      'Environment assignment must contain an equals sign.',
    );
  }
  final name = assignment.substring(0, separator);
  if (!isValidSshEnvironmentName(name)) {
    throw const SshEnvironmentException(
      SshEnvironmentErrorKind.invalidName,
      'Invalid environment variable name.',
    );
  }
  final value = assignment.substring(separator + 1);
  if (value.contains('\u0000') ||
      value.contains('\r') ||
      value.contains('\n')) {
    throw const SshEnvironmentException(
      SshEnvironmentErrorKind.invalidValue,
      'Environment variable value contains a forbidden control character.',
    );
  }
  return MapEntry(name, value);
}

Map<String, String> parseSshEnvironmentLines(String source) {
  final environment = <String, String>{};
  final lines = source.split(RegExp(r'\r?\n'));
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.trim().isEmpty) continue;
    late final MapEntry<String, String> assignment;
    try {
      assignment = parseSshEnvironmentAssignment(line);
    } on SshEnvironmentException catch (error) {
      throw SshEnvironmentException(
        error.kind,
        'Invalid environment assignment on line ${index + 1}: ${error.message}',
        line: index + 1,
      );
    }
    if (environment.containsKey(assignment.key)) {
      throw SshEnvironmentException(
        SshEnvironmentErrorKind.duplicateName,
        'Duplicate environment variable ${assignment.key} on line ${index + 1}.',
        line: index + 1,
        variable: assignment.key,
      );
    }
    environment[assignment.key] = assignment.value;
  }
  return Map.unmodifiable(environment);
}

String formatSshEnvironmentLines(Map<String, String> environment) {
  final names = environment.keys.toList()..sort();
  return names.map((name) => '$name=${environment[name]}').join('\n');
}

String? validateSshEnvironmentLines(String? source) {
  try {
    parseSshEnvironmentLines(source ?? '');
    return null;
  } on FormatException catch (error) {
    return error.message.toString();
  }
}
