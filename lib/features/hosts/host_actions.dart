import 'package:flutter/material.dart';
import 'package:codex_go/infrastructure/storage/host_profile.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';

import 'profile_editor.dart';

/// 首次引导与主机列表使用同一条编辑流程，凭据不会绕过安全存储。
Future<void> editHostProfile(
  BuildContext context,
  CodexRuntime runtime, {
  HostProfile? profile,
}) async {
  final secret = profile == null
      ? const HostSecret()
      : await runtime.readSecret(profile.id);
  if (!context.mounted) return;
  final draft = await Navigator.of(context).push<ProfileDraft>(
    MaterialPageRoute(
      builder: (_) => ProfileEditor(profile: profile, secret: secret),
    ),
  );
  if (draft == null) return;
  // 配置更新后断开旧链路，避免界面展示新地址而实际仍连接旧地址。
  if (runtime.isConnected && runtime.selectedHostId == draft.profile.id) {
    await runtime.disconnect();
  }
  await runtime.saveProfile(draft.profile, draft.secret);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.goConnectionSaved)));
  }
}
