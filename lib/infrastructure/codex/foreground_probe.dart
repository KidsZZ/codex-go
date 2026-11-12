// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/foundation.dart';

import 'package:codex_go/infrastructure/platform/diagnostics.dart';
import 'package:codex_go/infrastructure/codex/json_rpc_client.dart';

/// A slow or rejected RPC is not evidence that the transport disconnected.
Future<bool> foregroundTransportDisconnected(
  JsonRpcClient rpc, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  Diagnostics.record('probe.start');
  try {
    await rpc.requestWithTimeout('model/list', {
      'limit': 1,
      'includeHidden': false,
    }, timeout);
    Diagnostics.record('probe.success');
  } on RpcDisconnectedException {
    Diagnostics.record('probe.disconnected');
    return true;
  } catch (exception) {
    Diagnostics.record(
      'probe.inconclusive',
      Diagnostics.errorFields(exception),
    );
    debugPrint('Foreground probe inconclusive; keeping connection: $exception');
  }
  return false;
}
