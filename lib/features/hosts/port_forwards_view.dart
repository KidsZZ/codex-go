// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/infrastructure/ports/port_forward.dart';
import 'package:codex_go/infrastructure/ports/port_discovery.dart';
import 'package:codex_go/shared/media/preview_browser.dart';
import 'package:codex_go/l10n/strings.dart';

Future<bool> openForwardedPage(
  Uri uri,
  Future<bool> Function(Uri) external, {
  Future<bool> Function(Uri)? inApp,
}) async {
  if (inApp == null && !PreviewBrowser.supported) return external(uri);
  try {
    if (await (inApp ?? PreviewBrowser.openPage)(uri)) return true;
  } on PlatformException {
    // Devices without an enabled system WebView can still use their browser.
  }
  return external(uri);
}

Future<void> showPortForwards(
  BuildContext context,
  CodexRuntime controller,
) async {
  final hostId = controller.selectedHostId;
  if (hostId == null) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => PortForwardsPanel(
      controller: controller,
      hostId: hostId,
      hostLabel: controller.selectedHost?.label ?? hostId,
    ),
  );
}

void _message(BuildContext context, String value) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
}

Future<void> openRemotePortLink(
  BuildContext context,
  CodexRuntime controller,
  Uri source,
  Future<bool> Function(Uri) openBrowser,
) async {
  try {
    mapForwardedUri(
      source,
      1024,
    ); // Reject credential-bearing/invalid URLs first.
    final hostId = controller.selectedHostId;
    if (hostId == null || !controller.isConnected) {
      throw StateError(
        context.l10n.reconnectSshBeforeOpeningTheRemoteLocalhostLink,
      );
    }
    final existing = controller.portForwards.loopbackRule(
      hostId,
      source.port,
      source.host,
    );
    final current = existing == null
        ? null
        : controller.portForwards.stateFor(existing.id).localPort;
    Uri mapped;
    if (existing?.enabled == true && current != null) {
      mapped = mapForwardedUri(source, current);
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.forwardRemotePortQuestion),
          content: Text(
            context.l10n.confirmForwardPort(
              (source.host).toString(),
              (source.port).toString(),
              (controller.selectedHost?.label ?? hostId).toString(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.forwardAndOpen),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      mapped = await controller.forwardLoopbackUrl(hostId, source);
    }
    if (!context.mounted ||
        controller.selectedHostId != hostId ||
        !controller.isConnected) {
      return;
    }
    if (!await openForwardedPage(mapped, openBrowser) && context.mounted) {
      _message(context, context.l10n.couldNotOpenTheBrowser);
    }
  } catch (error) {
    if (context.mounted) _message(context, '$error');
  }
}

class PortForwardsPanel extends StatefulWidget {
  const PortForwardsPanel({
    required this.controller,
    required this.hostId,
    required this.hostLabel,
    super.key,
  });
  final CodexRuntime controller;
  final String hostId;
  final String hostLabel;
  @override
  State<PortForwardsPanel> createState() => _PortForwardsPanelState();
}

class _PortForwardsPanelState extends State<PortForwardsPanel> {
  List<ListeningPort> _discovered = const [];
  bool _discovering = false;
  String? _discoveryError;
  bool get _sameHost => widget.controller.selectedHostId == widget.hostId;
  @override
  void initState() {
    super.initState();
    if (widget.controller.canDiscoverPorts) unawaited(_discover());
  }

  Future<void> _discover() async {
    if (_discovering || !_sameHost) return;
    setState(() {
      _discovering = true;
      _discoveryError = null;
    });
    try {
      final result = await widget.controller.discoverPorts(widget.hostId);
      if (mounted && _sameHost) setState(() => _discovered = result);
    } catch (error) {
      if (mounted) setState(() => _discoveryError = error.toString());
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _edit({PortForwardRule? rule, ListeningPort? candidate}) async {
    if (!_sameHost) return;
    final result = await showDialog<PortForwardRule>(
      context: context,
      builder: (_) => _PortEditor(
        hostId: widget.hostId,
        id: rule?.id ?? widget.controller.portForwards.newId(),
        rule: rule,
        candidate: candidate,
      ),
    );
    if (result == null || !mounted || !_sameHost) return;
    try {
      await widget.controller.savePortForward(result);
    } catch (error) {
      if (mounted) _message(context, '$error');
    }
  }

  Future<void> _toggle(PortForwardRule rule, bool enabled) async {
    try {
      await widget.controller.savePortForward(rule.copyWith(enabled: enabled));
    } catch (error) {
      if (mounted) _message(context, '$error');
    }
  }

  Future<void> _action(PortForwardRule rule, String action) async {
    if (!_sameHost) return;
    try {
      final state = widget.controller.portForwards.stateFor(rule.id);
      switch (action) {
        case 'edit':
          await _edit(rule: rule);
          break;
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(context.l10n.removeForwardingRuleQuestion),
              content: Text(
                context.l10n.removeForwardingDescription(
                  (rule.remoteAddress).toString(),
                ),
              ),
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
          if (confirmed == true && mounted && _sameHost) {
            await widget.controller.removePortForward(rule.id);
          }
          break;
        case 'retry':
          await widget.controller.portForwards.retry();
          break;
        case 'copy':
          if (state.localPort != null) {
            await Clipboard.setData(
              ClipboardData(text: '127.0.0.1:${state.localPort}'),
            );
            if (mounted) _message(context, context.l10n.localAddressCopied);
          }
          break;
        case 'open':
        case 'external':
          if (state.localPort != null) {
            final uri = Uri(
              scheme: rule.scheme,
              host: '127.0.0.1',
              port: state.localPort,
              path: '/',
            );
            Future<bool> external(Uri value) =>
                launchUrl(value, mode: LaunchMode.externalApplication);
            final opened = action == 'external'
                ? await external(uri)
                : await openForwardedPage(uri, external);
            if (!opened && mounted) {
              _message(context, context.l10n.couldNotOpenTheBrowser);
            }
          }
          break;
      }
    } catch (error) {
      if (mounted) _message(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      widget.controller.portForwards,
    ]),
    builder: (context, _) {
      final manager = widget.controller.portForwards;
      final rules = manager.forHost(widget.hostId);
      final candidates = _discovered
          .where(
            (port) => !rules.any(
              (rule) =>
                  rule.remoteHost == port.host && rule.remotePort == port.port,
            ),
          )
          .toList();
      return SafeArea(
        top: false,
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.portsForHost(
                          (widget.hostLabel).toString(),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const Key('ports-discover'),
                      tooltip: context.l10n.discoverListeningPorts,
                      onPressed:
                          _sameHost &&
                              widget.controller.canDiscoverPorts &&
                              !_discovering
                          ? _discover
                          : null,
                      icon: const Icon(Icons.refresh),
                    ),
                    IconButton(
                      key: const Key('ports-add'),
                      tooltip: context.l10n.addForwardingRule,
                      onPressed: _sameHost ? () => _edit() : null,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
              ),
              if (!_sameHost)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(context.l10n.hostChangedCloseAndReopenPorts),
                ),
              if (!widget.controller.isConnected)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    context
                        .l10n
                        .offlineEnabledRulesResumeWhenThisHostReconnects,
                  ),
                ),
              if (_discovering) const LinearProgressIndicator(),
              if (_discoveryError != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_discoveryError!),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    if (rules.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          context.l10n.noForwardedPortsAddOneChooseADetected,
                        ),
                      ),
                    for (final rule in rules)
                      _ruleCard(rule, manager.stateFor(rule.id)),
                    if (candidates.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(context.l10n.detectedOnTheSshHost),
                      ),
                      for (final port in candidates)
                        ListTile(
                          title: Text(port.address),
                          subtitle: Text(
                            context.l10n.detectedListenerNotForwardedYet,
                          ),
                          trailing: TextButton(
                            onPressed: _sameHost
                                ? () => _edit(candidate: port)
                                : null,
                            child: Text(context.l10n.forward),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Text(
                  context.l10n.phoneSshHostTcpListensOnlyOn127,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _ruleCard(PortForwardRule rule, PortForwardState state) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    rule.label.isEmpty ? rule.remoteAddress : rule.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Switch(
                  key: ValueKey('port-toggle-${rule.id}'),
                  value: rule.enabled,
                  onChanged: _sameHost ? (value) => _toggle(rule, value) : null,
                ),
                PopupMenuButton<String>(
                  key: ValueKey('port-actions-${rule.id}'),
                  enabled: _sameHost,
                  tooltip: context.l10n.portActions,
                  onSelected: (value) => _action(rule, value),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'edit',
                      child: Text(context.l10n.editPorts),
                    ),
                    PopupMenuItem(
                      value: 'open',
                      enabled: state.listening,
                      child: Text(context.l10n.openInApp),
                    ),
                    PopupMenuItem(
                      value: 'external',
                      enabled: state.listening,
                      child: Text(context.l10n.openInExternalBrowser),
                    ),
                    PopupMenuItem(
                      value: 'copy',
                      enabled: state.listening,
                      child: Text(context.l10n.copyLocalAddress),
                    ),
                    PopupMenuItem(
                      value: 'retry',
                      child: Text(context.l10n.retryForwarding),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(context.l10n.removeRule),
                    ),
                  ],
                ),
              ],
            ),
            SelectableText(
              '${state.localPort == null ? (rule.localPort == 0 ? "Auto" : "127.0.0.1:${rule.localPort}") : "127.0.0.1:${state.localPort}"} → ${rule.remoteAddress}',
            ),
            Text(
              !rule.enabled
                  ? context.l10n.stopped
                  : state.listening
                  ? context.l10n.listeningConnections(
                      (state.connections).toString(),
                    )
                  : state.error != null
                  ? context.l10n.forwardingFailed
                  : context.l10n.waitingForSsh,
            ),
            if (state.error != null)
              Text(
                state.error!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PortEditor extends StatefulWidget {
  const _PortEditor({
    required this.hostId,
    required this.id,
    this.rule,
    this.candidate,
  });
  final String hostId;
  final String id;
  final PortForwardRule? rule;
  final ListeningPort? candidate;
  @override
  State<_PortEditor> createState() => _PortEditorState();
}

class _PortEditorState extends State<_PortEditor> {
  late final _host = TextEditingController(
    text: widget.rule?.remoteHost ?? widget.candidate?.host ?? '127.0.0.1',
  );
  late final _remote = TextEditingController(
    text: (widget.rule?.remotePort ?? widget.candidate?.port)?.toString() ?? '',
  );
  late final _local = TextEditingController(
    text: (widget.rule?.localPort ?? 0).toString(),
  );
  late final _label = TextEditingController(text: widget.rule?.label ?? '');
  late bool _https = widget.rule?.scheme == 'https';
  String? _error;
  @override
  void dispose() {
    _host.dispose();
    _remote.dispose();
    _local.dispose();
    _label.dispose();
    super.dispose();
  }

  void _save() {
    try {
      final result = PortForwardRule(
        id: widget.id,
        hostId: widget.hostId,
        remoteHost: _host.text,
        remotePort: int.tryParse(_remote.text) ?? -1,
        localPort: _local.text.trim().isEmpty
            ? 0
            : int.tryParse(_local.text) ?? -1,
        label: _label.text.trim(),
        enabled: widget.rule?.enabled ?? true,
        scheme: _https ? 'https' : 'http',
      );
      Navigator.pop(context, result);
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.rule == null
          ? context.l10n.forwardAPort
          : context.l10n.editForwarding,
    ),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('port-remote-host'),
              controller: _host,
              decoration: InputDecoration(
                labelText: context.l10n.hostReachedFromSshServer,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('port-remote-port'),
              controller: _remote,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.remotePort165535,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('port-local-port'),
              controller: _local,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: context.l10n.phonePort0Auto,
                helperText: context.l10n.autoTriesTheRemotePortThenAnAvailable,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('port-label'),
              controller: _label,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: context.l10n.labelOptional,
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(context.l10n.httpsBrowserLink),
              subtitle: Text(
                context.l10n.tcpForwardingAlsoWorksForNonWebServices,
              ),
              value: _https,
              onChanged: (value) => setState(() => _https = value),
            ),
            if (widget.rule != null)
              Text(
                context.l10n.changingTheRouteClosesItsCurrentClientConnections,
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        key: const Key('port-save'),
        onPressed: _save,
        child: Text(context.l10n.save),
      ),
    ],
  );
}
