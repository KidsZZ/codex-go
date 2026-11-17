import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'util/bytes.dart';

/// 公钥来自用户扫描的电脑二维码，连接时不允许服务端替换。
final class RelayEndpoint {
  RelayEndpoint({required String url, required this.hostKey})
    : url = validateRelayUrl(url) {
    validateRelayKey(hostKey);
  }
  factory RelayEndpoint.fromJson(Map<String, dynamic> json) => RelayEndpoint(
    url: json['url'] as String,
    hostKey: json['hostKey'] as String,
  );
  final String url;
  final String hostKey;
  Map<String, dynamic> toJson() => {'url': url, 'hostKey': hostKey};
  @override
  bool operator ==(Object other) =>
      other is RelayEndpoint && other.url == url && other.hostKey == hostKey;
  @override
  int get hashCode => Object.hash(url, hostKey);
}

String validateRelayUrl(String value) {
  final uri = Uri.parse(value);
  final local = ['localhost', '127.0.0.1', '::1'].contains(uri.host);
  if (!uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !RegExp(r'^/(?:[A-Za-z0-9_-]+/)*relay$').hasMatch(uri.path) ||
      (uri.scheme != 'wss' && !(uri.scheme == 'ws' && local))) {
    throw const FormatException('INVALID_RELAY_URL');
  }
  return uri.toString();
}

void validateRelayKey(String value) {
  if (!identityKeyPattern.hasMatch(value) ||
      fromBase64Url(value).length != 32 ||
      toBase64Url(fromBase64Url(value)) != value) {
    throw const FormatException('INVALID_DEVICE_KEY');
  }
}

String relayFingerprint(String key) => sha256
    .convert(fromBase64Url(key))
    .toString()
    .substring(0, 24)
    .toUpperCase();

/// 二维码承载完整信任锚点；不向服务端换取公钥，不把秘密放入 HTTP URL。
final class RelayPairingOffer {
  RelayPairingOffer._(this.endpoint, this.secret, this.expires, this.name);
  factory RelayPairingOffer.parse(String text) {
    if (text.length > 4096) throw const FormatException('INVALID_PAIRING_QR');
    final uri = Uri.parse(text.trim());
    if (uri.scheme != 'codex-go' ||
        uri.host != 'pair' ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        !uri.hasFragment) {
      throw const FormatException('INVALID_PAIRING_QR');
    }
    final json = jsonDecode(
      utf8.decode(fromBase64Url(uri.fragment)),
    ) as Map<String, dynamic>;
    if (json['v'] != 1) {
      throw const FormatException('UNSUPPORTED_PAIRING_VERSION');
    }
    final endpoint = RelayEndpoint(
      url: json['relay'] as String,
      hostKey: json['host'] as String,
    );
    final secret = json['secret'] as String;
    validateRelayKey(secret);
    final expires = DateTime.fromMillisecondsSinceEpoch(json['expires'] as int);
    final now = DateTime.now();
    if (!expires.isAfter(now) ||
        expires.difference(now) > const Duration(minutes: 6)) {
      throw const FormatException('PAIRING_EXPIRED');
    }
    final name = json['name'] as String;
    if (name.isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
      throw const FormatException('INVALID_DEVICE_NAME');
    }
    return RelayPairingOffer._(endpoint, secret, expires, name);
  }
  final RelayEndpoint endpoint;
  final String secret;
  final DateTime expires;
  final String name;
}
