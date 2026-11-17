import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../util/bytes.dart';

// 仅实现手机需要的 IK 发起端，按 Noise rev34 的固定消息顺序驱动密码库。
// 协议依据：https://noiseprotocol.org/noise.html；Node 对端采用 ds-harness-remote
// 的 MIT 封装。X25519 和 ChaCha20-Poly1305 均由 cryptography 提供。
// 不包含 dsh-Go 的 AGPL 状态机源码，也不支持动态密码套件或降级。
final class DeviceIdentity {
  DeviceIdentity._(this.privateBytes, this.publicBytes);
  factory DeviceIdentity.fromPrivateKey(List<int> bytes) {
    if (bytes.length != 32) throw const FormatException('INVALID_KEY');
    final private = Uint8List.fromList(bytes);
    final public = _dh(private, [9, ...List<int>.filled(31, 0)]);
    return DeviceIdentity._(private, public);
  }
  factory DeviceIdentity.generate() {
    final random = Random.secure();
    return DeviceIdentity.fromPrivateKey(
      List.generate(32, (_) => random.nextInt(256)),
    );
  }
  final Uint8List privateBytes;
  final Uint8List publicBytes;
  String get privateKeyBase64Url => toBase64Url(privateBytes);
  String get publicKeyBase64Url => toBase64Url(publicBytes);
  void destroy() => privateBytes.fillRange(0, 32, 0);
}

Uint8List _dh(List<int> secret, List<int> public) {
  final result = const DartX25519().sharedSecretSync(
    keyPairData: SimpleKeyPairData(
      secret,
      publicKey: SimplePublicKey(
        List<int>.filled(32, 0),
        type: KeyPairType.x25519,
      ),
      type: KeyPairType.x25519,
    ),
    remotePublicKey: SimplePublicKey(public, type: KeyPairType.x25519),
  ) as SecretKeyData;
  final bytes = Uint8List.fromList(result.bytes);
  if (bytes.every((byte) => byte == 0)) {
    throw const FormatException('LOW_ORDER_KEY');
  }
  return bytes;
}

List<int> _sha(List<int> data) => hash.sha256.convert(data).bytes;
List<int> _mac(List<int> key, List<int> data) =>
    hash.Hmac(hash.sha256, key).convert(data).bytes;
(List<int>, List<int>) _derive(List<int> chaining, List<int> input) {
  // Noise 的 HKDF 使用两个 SHA-256 输出块，不设置额外 info。
  final prk = _mac(chaining, input);
  final first = _mac(prk, [1]);
  return (first, _mac(prk, [...first, 2]));
}

final class _Cipher {
  _Cipher(List<int> key) : key = Uint8List.fromList(key);
  final Uint8List key;
  int counter = 0;
  List<int> apply(List<int> input, List<int> aad, {required bool decrypt}) {
    if (counter >= 0x7ffffffffffffffe) throw StateError('NONCE_EXHAUSTED');
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint64(4, counter, Endian.little);
    const cipher = DartChacha20.poly1305Aead();
    final List<int> result;
    if (decrypt) {
      if (input.length < 16) throw const FormatException('TRUNCATED_TAG');
      result = cipher.decryptSync(
        SecretBox(
          input.sublist(0, input.length - 16),
          nonce: nonce,
          mac: Mac(input.sublist(input.length - 16)),
        ),
        secretKey: SecretKeyData(key),
        aad: aad,
      );
    } else {
      final box = cipher.encryptSync(
        input,
        secretKey: SecretKeyData(key),
        nonce: nonce,
        aad: aad,
      );
      result = [...box.cipherText, ...box.mac.bytes];
    }
    counter++;
    return result;
  }

  void destroy() => key.fillRange(0, key.length, 0);
}

final class NoiseInitiator {
  NoiseInitiator({
    required String privateKey,
    required String hostKey,
    required List<int> prologue,
  }) : _identity = DeviceIdentity.fromPrivateKey(fromBase64Url(privateKey)),
       _host = fromBase64Url(hostKey) {
    if (_host.length != 32) throw const FormatException('INVALID_HOST_KEY');
    _digest = utf8.encode(
      'Noise_IK_25519_ChaChaPoly_SHA256',
    ); // 名称恰为 32 字节，无需哈希或填充。
    _chain = List.of(_digest);
    _mixHash(prologue);
    _mixHash(_host); // IK 的预消息固定为 responder 静态公钥。
  }
  final DeviceIdentity _identity;
  final Uint8List _host;
  DeviceIdentity? _ephemeral;
  late List<int> _digest;
  late List<int> _chain;
  _Cipher? _handshake;
  _Cipher? _outgoing;
  _Cipher? _incoming;
  int _step = 0;
  bool _destroyed = false;
  bool get complete => _step == 2 && !_destroyed;
  void _mixHash(List<int> bytes) => _digest = _sha([..._digest, ...bytes]);
  void _mixKey(List<int> bytes) {
    final (chain, key) = _derive(_chain, bytes);
    _chain = chain;
    _handshake?.destroy();
    _handshake = _Cipher(key);
  }

  List<int> _authenticated(List<int> bytes, {required bool decrypt}) {
    final result = _handshake!.apply(bytes, _digest, decrypt: decrypt);
    _mixHash(decrypt ? bytes : result);
    return result;
  }

  Uint8List writeHandshake() {
    if (_destroyed || _step != 0) throw StateError('HANDSHAKE_ORDER');
    try {
      final ephemeral = _ephemeral = DeviceIdentity.generate();
      // -> e, es, s, ss；静态手机公钥被加密，不接受其他消息模式。
      _mixHash(ephemeral.publicBytes);
      _mixKey(_dh(ephemeral.privateBytes, _host));
      final static = _authenticated(_identity.publicBytes, decrypt: false);
      _mixKey(_dh(_identity.privateBytes, _host));
      final payload = _authenticated(const [], decrypt: false);
      _step = 1;
      return Uint8List.fromList([
        ...ephemeral.publicBytes,
        ...static,
        ...payload,
      ]);
    } catch (_) {
      destroy();
      rethrow;
    }
  }

  Uint8List readHandshake(List<int> message) {
    if (_destroyed || _step != 1 || message.length != 48) {
      throw StateError('HANDSHAKE_ORDER');
    }
    try {
      // <- e, ee, se；只有固定电脑公钥对应的私钥才能生成有效响应。
      final ephemeral = message.sublist(0, 32);
      _mixHash(ephemeral);
      _mixKey(_dh(_ephemeral!.privateBytes, ephemeral));
      _mixKey(_dh(_identity.privateBytes, ephemeral));
      final payload = _authenticated(message.sublist(32), decrypt: true);
      final (send, receive) = _derive(_chain, const []);
      _outgoing = _Cipher(send);
      _incoming = _Cipher(receive);
      _step = 2;
      _ephemeral!.destroy();
      _identity.destroy();
      _handshake!.destroy();
      return Uint8List.fromList(payload);
    } catch (_) {
      destroy();
      rethrow;
    }
  }

  Uint8List encrypt(List<int> bytes) {
    if (!complete || bytes.length > 65519) {
      throw StateError('INVALID_NOISE_MESSAGE');
    }
    return Uint8List.fromList(
      _outgoing!.apply(bytes, const [], decrypt: false),
    );
  }

  Uint8List decrypt(List<int> bytes) {
    if (!complete || bytes.length > 65535) {
      throw StateError('INVALID_NOISE_MESSAGE');
    }
    try {
      return Uint8List.fromList(
        _incoming!.apply(bytes, const [], decrypt: true),
      );
    } catch (_) {
      destroy();
      rethrow;
    }
  }

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _identity.destroy();
    _ephemeral?.destroy();
    _handshake?.destroy();
    _outgoing?.destroy();
    _incoming?.destroy();
    _chain = [];
    _digest = [];
  }
}
