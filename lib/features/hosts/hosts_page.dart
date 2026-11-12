import 'package:flutter/material.dart';
import 'package:codex_go/infrastructure/storage/host_profile.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';

import 'host_actions.dart';
import 'port_forwards_view.dart';

class HostsPage extends StatefulWidget {
  const HostsPage({
    required this.runtime,
    required this.onConnected,
    super.key,
  });
  final CodexRuntime runtime;
  final VoidCallback onConnected;
  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  bool _mutating = false;
  bool get _connecting =>
      widget.runtime.connectionPhase == RemoteConnectionPhase.connecting ||
      widget.runtime.connectionPhase == RemoteConnectionPhase.reconnecting;
  void _error(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _edit([HostProfile? profile]) async {
    if (_mutating || _connecting) return;
    setState(() => _mutating = true);
    try {
      await editHostProfile(context, widget.runtime, profile: profile);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _remove(HostProfile profile) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.removeHostQuestion),
        content: Text(context.l10n.removeHostDescription(profile.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.remove),
          ),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    setState(() => _mutating = true);
    try {
      await widget.runtime.deleteProfile(profile.id);
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<void> _connect(HostProfile profile) async {
    try {
      await widget.runtime.connectHost(profile);
      if (mounted &&
          widget.runtime.isConnected &&
          widget.runtime.selectedHostId == profile.id) {
        widget.onConnected();
      }
    } catch (e) {
      _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.runtime;
    final colors = Theme.of(context).colorScheme;
    final l = context.l10n;
    return Column(
      children: [
        GoSectionHeading(
          l.navHosts,
          subtitle: l.goConnectionHint,
          trailing: IconButton.filled(
            onPressed: _mutating || _connecting ? null : _edit,
            tooltip: l.addHost,
            icon: const Icon(Icons.add),
          ),
        ),
        if (_mutating) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: c.profiles.isEmpty
              ? GoEmptyState(
                  icon: Icons.lan_outlined,
                  title: l.goWelcomeTitle,
                  description: l.goWelcomeBody,
                  action: FilledButton.icon(
                    onPressed: _mutating ? null : _edit,
                    icon: const Icon(Icons.add),
                    label: Text(l.goAddFirstHost),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  children: [
                    for (final profile in c.profiles)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _HostCard(
                          profile: profile,
                          active:
                              c.selectedHostId == profile.id && c.isConnected,
                          connecting:
                              c.selectedHostId == profile.id && _connecting,
                          onConnect: _mutating || _connecting
                              ? null
                              : () => _connect(profile),
                          onDisconnect: () => c.disconnect(),
                          onEdit: _mutating || _connecting
                              ? null
                              : () => _edit(profile),
                          onRemove: _mutating || _connecting
                              ? null
                              : () => _remove(profile),
                          onPorts: c.selectedHostId == profile.id
                              ? () => showPortForwards(context, c)
                              : null,
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.verified_user_outlined,
                          size: 15,
                          color: colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            l.goConnectionSecurity,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.profile,
    required this.active,
    required this.connecting,
    required this.onDisconnect,
    this.onConnect,
    this.onEdit,
    this.onRemove,
    this.onPorts,
  });
  final HostProfile profile;
  final bool active, connecting;
  final VoidCallback onDisconnect;
  final VoidCallback? onConnect, onEdit, onRemove, onPorts;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l = context.l10n;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (active || connecting)
            Container(
              height: 3,
              color: active ? colors.secondary : colors.primary,
            ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: active
                            ? colors.secondaryContainer
                            : colors.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Icons.dns_outlined,
                        color: active ? colors.secondary : colors.primary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            profile.label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${profile.user}@${profile.hostName}:${profile.port}',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.onSurfaceVariant,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: l.hostActions,
                      enabled: onEdit != null,
                      onSelected: (value) =>
                          value == 'edit' ? onEdit?.call() : onRemove?.call(),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'edit', child: Text(l.editHost)),
                        PopupMenuItem(value: 'remove', child: Text(l.remove)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _Tag(
                      icon: Icons.terminal_rounded,
                      label: switch (profile.appServerMode) {
                        AppServerMode.shared => l.sharedMode,
                        AppServerMode.custom => l.customMode,
                        AppServerMode.isolated => l.isolatedMode,
                      },
                    ),
                    if (active)
                      _Tag(
                        icon: Icons.check_circle_outline,
                        label: l.goConnectionReady,
                        active: true,
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (onPorts != null)
                      OutlinedButton.icon(
                        onPressed: onPorts,
                        icon: const Icon(Icons.settings_ethernet, size: 17),
                        label: Text(l.sshPorts),
                      ),
                    if (connecting)
                      OutlinedButton.icon(
                        onPressed: onDisconnect,
                        icon: const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        label: Text(l.goConnectionCancelled),
                      )
                    else if (active)
                      OutlinedButton.icon(
                        onPressed: onDisconnect,
                        icon: const Icon(Icons.link_off, size: 18),
                        label: Text(l.goDisconnect),
                      )
                    else
                      FilledButton.icon(
                        onPressed: onConnect,
                        icon: const Icon(Icons.arrow_forward, size: 18),
                        label: Text(l.connect),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label, this.active = false});
  final IconData icon;
  final String label;
  final bool active;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: active ? colors.secondaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 13,
            color: active ? colors.secondary : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: active ? colors.secondary : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
