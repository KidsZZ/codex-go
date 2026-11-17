import 'dart:convert';
import 'dart:typed_data';

// 协议只接受无填充、规范的 Base64URL，避免一个身份存在多种字符串表示。
String toBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
Uint8List fromBase64Url(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(value)) {
    throw const FormatException('INVALID_BASE64URL');
  }
  final bytes = base64Url.decode(base64Url.normalize(value));
  if (toBase64Url(bytes) != value) {
    throw const FormatException('NON_CANONICAL_BASE64URL');
  }
  return bytes;
}

final identityKeyPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
