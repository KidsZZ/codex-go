// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';
import 'package:codex_go/domain/conversations/permission_mode.dart';
import 'package:codex_go/l10n/strings.dart';

Future<PermissionMode?> choosePermissionMode(
  BuildContext context,
  PermissionMode value,
) async {
  final result = await showModalBottomSheet<PermissionMode>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(context.l10n.permissionsNextNewTurn),
              subtitle: Text(context.l10n.steerDoesNotChangeARunningTurnServer),
            ),
            for (final mode in PermissionMode.values)
              ListTile(
                key: ValueKey('permission-${mode.name}'),
                title: Text(_permissionLabel(context, mode)),
                subtitle: Text(_permissionDescription(context, mode)),
                trailing: mode == value ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, mode),
              ),
          ],
        ),
      ),
    ),
  );
  if (result != PermissionMode.fullAccess ||
      value == result ||
      !context.mounted) {
    return result;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.allowFullAccessQuestion),
      content: Text(context.l10n.commandsMayAccessFilesAndNetworksOutsideThe),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.allowFullAccess),
        ),
      ],
    ),
  );
  return confirmed == true ? result : null;
}

class PermissionPicker extends StatelessWidget {
  const PermissionPicker({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.compact = false,
    super.key,
  });
  final PermissionMode value;
  final ValueChanged<PermissionMode> onChanged;
  final bool enabled;
  final bool compact;
  @override
  Widget build(BuildContext context) => compact
      ? IconButton(
          key: const Key('permission-selector'),
          tooltip: context.l10n.permissionsLabel(
            _permissionLabel(context, value),
          ),
          visualDensity: VisualDensity.compact,
          icon: Icon(
            value == PermissionMode.fullAccess
                ? Icons.warning_amber
                : Icons.shield_outlined,
            size: 19,
          ),
          onPressed: !enabled
              ? null
              : () async {
                  final mode = await choosePermissionMode(context, value);
                  if (context.mounted && mode != null) onChanged(mode);
                },
        )
      : TextButton.icon(
          key: const Key('permission-selector'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
          ),
          onPressed: !enabled
              ? null
              : () async {
                  final mode = await choosePermissionMode(context, value);
                  if (context.mounted && mode != null) onChanged(mode);
                },
          icon: Icon(
            value == PermissionMode.fullAccess
                ? Icons.warning_amber
                : Icons.shield_outlined,
            size: 18,
          ),
          label: Text(_permissionLabel(context, value)),
        );
}

String _permissionLabel(BuildContext context, PermissionMode mode) =>
    switch (mode) {
      PermissionMode.inherit => context.l10n.permissionInherit,
      PermissionMode.readOnly => context.l10n.permissionReadOnly,
      PermissionMode.workspace => context.l10n.permissionWorkspace,
      PermissionMode.fullAccess => context.l10n.permissionFullAccess,
    };
String _permissionDescription(BuildContext context, PermissionMode mode) =>
    switch (mode) {
      PermissionMode.inherit => context.l10n.permissionInheritDescription,
      PermissionMode.readOnly => context.l10n.permissionReadOnlyDescription,
      PermissionMode.workspace => context.l10n.permissionWorkspaceDescription,
      PermissionMode.fullAccess => context.l10n.permissionFullAccessDescription,
    };
