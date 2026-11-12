// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';

import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/l10n/strings.dart';

class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({required this.phase, super.key});

  final RemoteConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final connected = phase == RemoteConnectionPhase.connected;
    final busy =
        phase == RemoteConnectionPhase.connecting ||
        phase == RemoteConnectionPhase.reconnecting;
    final color = connected
        ? Theme.of(context).colorScheme.primary
        : busy
        ? Theme.of(context).colorScheme.tertiary
        : Theme.of(context).colorScheme.outline;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Text(
          connected
              ? context.l10n.connected
              : busy
              ? context.l10n.connecting
              : context.l10n.offline,
          style: Theme.of(context).textTheme.labelMedium,
        ),
      ],
    );
  }
}
