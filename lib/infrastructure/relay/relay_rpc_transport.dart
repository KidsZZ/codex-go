import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../codex/rpc_transport.dart';
import 'crypto/noise_ik.dart';
import 'relay_endpoint.dart';
import 'util/bytes.dart';

/// 参考 dsh-Go 的 Relay + Noise IK 分层，承载原生 Codex 双向 JSON-RPC。
/// 配对秘密仅在已验证电脑身份的加密通道内发送。
final class RelayRpcTransport implements RpcTransport {
  RelayRpcTransport._(
    this._socket,
    this._endpoint,
    this._identity,
    this._secret,
  );
  static Future<RelayRpcTransport> connect({
    required RelayEndpoint endpoint,
    required String privateKey,
    String? pairingSecret,
    void Function(RelayRpcTransport)? onCreated,
  }) async {
    validateRelayKey(privateKey);
    final identity = DeviceIdentity.fromPrivateKey(fromBase64Url(privateKey));
    WebSocket socket;
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    var abandoned = false;
    try {
      socket = await WebSocket.connect(endpoint.url, customClient: http)
          .then((value) {
            if (abandoned) {
              unawaited(value.close());
              throw StateError('RELAY_CONNECT_EXPIRED');
            }
            return value;
          })
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      abandoned = true;
      http.close(force: true);
      identity.destroy();
      rethrow;
    } finally {
      http.close(force: false);
    }
    final transport = RelayRpcTransport._(
      socket,
      endpoint,
      identity,
      pairingSecret,
    );
    // 先订阅授权结果，再暴露取消句柄，避免立即取消造成未处理的 Future 错误。
    final ready = transport._ready.future.timeout(
      Duration(seconds: pairingSecret == null ? 25 : 90),
    );
    try {
      transport._subscription = socket.listen(
        transport._receive,
        onError: (Object _) => transport._fail(),
        onDone: transport._fail,
      );
      socket.pingInterval = const Duration(seconds: 20);
      transport._write({
        'type': 'join',
        'host': endpoint.hostKey,
        'client': identity.publicKeyBase64Url,
      });
      onCreated?.call(transport);
      await ready;
      return transport;
    } catch (_) {
      await transport.close();
      rethrow;
    }
  }

  final WebSocket _socket;
  final RelayEndpoint _endpoint;
  final DeviceIdentity _identity;
  String? _secret;
  final _ready = Completer<void>();
  final _messages = StreamController<String>();
  StreamSubscription<dynamic>? _subscription;
  NoiseInitiator? _noise;
  String? _id;
  bool _closed = false;
  final _fragments = BytesBuilder(copy: false);
  static const _maxMessage = 4 * 1024 * 1024;

  @override
  Stream<String> get messages => _messages.stream;

  void _write(Map<String, Object?> value) {
    if (_closed) throw StateError('RELAY_CLOSED');
    _socket.add(jsonEncode(value));
  }

  void _receive(dynamic raw) {
    if (_closed) return;
    try {
      if (raw is! String || raw.length > 96 * 1024) {
        throw const FormatException('INVALID_FRAME');
      }
      final frame = jsonDecode(raw) as Map<String, dynamic>;
      if (frame['type'] == 'ready' && _id == null) {
        final id = frame['id'] as String;
        if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
          throw const FormatException('INVALID_CONNECTION');
        }
        _id = id;
        final noise = _noise = NoiseInitiator(
          privateKey: _identity.privateKeyBase64Url,
          hostKey: _endpoint.hostKey,
          prologue: utf8.encode(
            'CODEX-GO\u0000v=1\u0000connection=$id\u0000host=${_endpoint.hostKey}\u0000client=${_identity.publicKeyBase64Url}',
          ),
        );
        _write({
          'type': 'packet',
          'id': id,
          'data': toBase64Url(noise.writeHandshake()),
        });
        return;
      }
      if (frame['type'] != 'packet' || frame['id'] != _id || _noise == null) {
        throw const FormatException('RELAY_CLOSED');
      }
      final noise = _noise!;
      final data = fromBase64Url(frame['data'] as String);
      if (!noise.complete) {
        if (noise.readHandshake(data).isNotEmpty) {
          throw const FormatException('INVALID_HANDSHAKE');
        }
        _sendSecure({'kind': 'auth', if (_secret != null) 'secret': _secret});
        _secret = null;
        return;
      }
      final bytes = noise.decrypt(data);
      if (bytes.length < 2 ||
          bytes[0] > 1 ||
          _fragments.length + bytes.length - 1 > _maxMessage) {
        throw const FormatException('INVALID_FRAGMENT');
      }
      _fragments.add(bytes.sublist(1));
      if (bytes[0] == 0) return;
      final message = jsonDecode(
        utf8.decode(_fragments.takeBytes()),
      ) as Map<String, dynamic>;
      if (!_ready.isCompleted) {
        if (message['kind'] != 'authorized') {
          throw const FormatException('AUTH_REQUIRED');
        }
        _ready.complete();
        return;
      }
      if (message['kind'] != 'rpc' || message['message'] is! String) {
        throw const FormatException('INVALID_RPC');
      }
      _messages.add(message['message'] as String);
    } catch (_) {
      _fail();
    }
  }

  void _sendSecure(Map<String, Object?> value) {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > _maxMessage) {
      throw const FormatException('MESSAGE_TOO_LARGE');
    }
    for (var offset = 0; offset < bytes.length; offset += 48 * 1024) {
      final end = (offset + 48 * 1024).clamp(0, bytes.length);
      final encrypted = _noise!.encrypt([
        end == bytes.length ? 1 : 0,
        ...bytes.sublist(offset, end),
      ]);
      _write({'type': 'packet', 'id': _id, 'data': toBase64Url(encrypted)});
    }
  }

  @override
  void send(String message) {
    if (_closed || !_ready.isCompleted) throw StateError('RELAY_NOT_READY');
    _sendSecure({'kind': 'rpc', 'message': message});
  }

  void _fail() {
    if (_closed) return;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('RELAY_AUTH_OR_CONNECTION_FAILED'));
    }
    unawaited(close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(StateError('RELAY_CANCELLED'));
    }
    _secret = null;
    _noise?.destroy();
    _identity.destroy();
    _fragments.clear();
    await _subscription?.cancel();
    unawaited(_messages.close());
    try {
      await _socket.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      /* 不让取消界面等待失联对端。 */
    }
  }
}
