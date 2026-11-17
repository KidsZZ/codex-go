// 无手机时的连接诊断入口：只执行 initialize，不发送任务、不读取会话内容。
// 配对凭据从标准输入读取，不出现在命令行参数或错误日志里。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_go/infrastructure/relay/crypto/noise_ik.dart';
import 'package:codex_go/infrastructure/relay/relay_endpoint.dart';
import 'package:codex_go/infrastructure/relay/relay_rpc_transport.dart';

Future<void> main(List<String> args) async {
  final identity = DeviceIdentity.generate();
  try {
    stdout.writeln('粘贴电脑显示的配对内容：');
    final line = stdin.readLineSync();
    if (line == null) throw StateError('MISSING_PAIRING_CODE');
    final offer = RelayPairingOffer.parse(line);
    stdout.writeln('电脑指纹：${relayFingerprint(offer.endpoint.hostKey)}');
    stdout.writeln('诊断设备指纹：${relayFingerprint(identity.publicKeyBase64Url)}');
    stdout.writeln('请在电脑核对指纹并确认。');
    await initialize(offer.endpoint, identity, offer.secret);
    stdout.writeln('成功：配对、端到端加密、Codex 初始化均已完成。');
    if (args.contains('--reconnect')) {
      await initialize(offer.endpoint, identity, null);
      stdout.writeln('成功：已配对设备重新连接，无需再次授权。');
    }
    stdout.writeln(
      '这是临时诊断身份；如需撤销，请在 Host 停止后使用 --revoke ${identity.publicKeyBase64Url}。',
    );
  } catch (error) {
    if (error is StateError) {
      stderr.writeln('诊断阶段：${error.message}');
    }
    stderr.writeln('诊断失败：请检查中转、电脑确认和本地 Codex 服务。');
    exitCode = 1;
  } finally {
    identity.destroy();
  }
}

Future<void> initialize(
  RelayEndpoint endpoint,
  DeviceIdentity identity,
  String? secret,
) async {
  final transport = await RelayRpcTransport.connect(
    endpoint: endpoint,
    privateKey: identity.privateKeyBase64Url,
    pairingSecret: secret,
  );
  StreamSubscription<String>? subscription;
  try {
    final initialized = Completer<void>();
    subscription = transport.messages.listen(
      (message) {
        final value = jsonDecode(message) as Map<String, dynamic>;
        if (value['id'] != 1 || initialized.isCompleted) return;
        if (value.containsKey('result')) {
          initialized.complete();
        } else {
          initialized.completeError(StateError('CODEX_INITIALIZE_FAILED'));
        }
      },
      onDone: () {
        if (!initialized.isCompleted) {
          initialized.completeError(StateError('CONNECTION_CLOSED'));
        }
      },
    );
    transport.send(
      jsonEncode({
        'id': 1,
        'method': 'initialize',
        'params': {
          'clientInfo': {
            'name': 'codex_go_probe',
            'title': 'Codex Go Relay Probe',
            'version': '0.1.0',
          },
          'capabilities': {'experimentalApi': true},
        },
      }),
    );
    await initialized.future.timeout(const Duration(seconds: 20));
    transport.send(jsonEncode({'method': 'initialized', 'params': {}}));
  } finally {
    await subscription?.cancel();
    await transport.close();
  }
}
