import 'package:codex_go/features/hosts/host_actions.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/features/conversation/conversation_view.dart';
import 'package:codex_go/features/hosts/hosts_page.dart';
import 'package:codex_go/features/hosts/port_forwards_view.dart';
import 'package:codex_go/features/settings/settings_page.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/shared/media/remote_port_link_scope.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';

import 'conversations_page.dart';
import 'workspaces_page.dart';
import 'workspace_navigation.dart';

class WorkspaceShell extends StatefulWidget {
  const WorkspaceShell({required this.runtime, this.navigation, super.key});
  final CodexRuntime runtime;
  final WorkspaceNavigation? navigation;
  @override
  State<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends State<WorkspaceShell> {
  late final WorkspaceNavigation _navigation;
  late final Listenable _changes;
  String? _host;
  String? _previousTask;
  Timer? _pins;
  @override
  void initState() {
    super.initState();
    _navigation = widget.navigation ?? WorkspaceNavigation();
    _changes = Listenable.merge([widget.runtime, _navigation]);
    _host = widget.runtime.selectedHostId;
    _previousTask = widget.runtime.selectedTaskId;
    widget.runtime.addListener(_runtimeChanged);
    unawaited(widget.runtime.refreshSidebarPins());
    _pins = Timer.periodic(
      const Duration(seconds: 30),
      (_) => widget.runtime.refreshSidebarPins(),
    );
  }

  void _runtimeChanged() {
    if (_previousTask != null &&
        widget.runtime.selectedTaskId == null &&
        _navigation.detail) {
      _navigation.backToList();
    }
    _previousTask = widget.runtime.selectedTaskId;
    if (_host != widget.runtime.selectedHostId) {
      _host = widget.runtime.selectedHostId;
      _navigation.resetHost();
    }
    // 工作区被远端移除后自动回到全部会话，避免用失效目录创建新会话。
    if (_navigation.workspaceId != null &&
        !widget.runtime.projects.any((p) => p.id == _navigation.workspaceId)) {
      _navigation.selectWorkspace(null);
    }
  }

  @override
  void dispose() {
    _pins?.cancel();
    widget.runtime.removeListener(_runtimeChanged);
    if (widget.navigation == null) _navigation.dispose();
    super.dispose();
  }

  void _hosts() {
    _navigation.select(GoDestination.hosts);
    if (widget.runtime.profiles.isEmpty) unawaited(_addFirstHost());
  }

  Future<void> _addFirstHost() async {
    try {
      await editHostProfile(context, widget.runtime);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  void _new() {
    widget.runtime.clearSelectedTask();
    _navigation.openConversation();
  }

  void _open(String id) {
    _navigation.openConversation();
    unawaited(widget.runtime.selectTask(id));
  }

  void _workspace(String? id) {
    widget.runtime.clearSelectedTask();
    _navigation.selectWorkspace(id);
    unawaited(widget.runtime.selectProject(id));
  }

  Widget _conversation() {
    final c = widget.runtime;
    final project = c.projects
        .where((p) => p.id == _navigation.workspaceId)
        .firstOrNull;
    final task =
        c.selectedTask ??
        TaskRecord(
          id: 'draft:${project?.id ?? 'default'}',
          title: context.l10n.newChat,
          cwd: project?.cwd ?? '',
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          status: TaskStatus.unknown,
          items: const [],
          ownership: TaskOwnership.available,
          revision: 0,
        );
    return ConversationView(
      key: ValueKey('${c.selectedHostId}:${task.id}'),
      controller: c,
      task: task,
      newConversation: c.selectedTask == null,
      projectId: project?.id,
      showBackButton:
          MediaQuery.sizeOf(context).width < 1000 ||
          MediaQuery.sizeOf(context).height < 500,
      onOpenNavigation: _navigation.backToList,
      onNewConversation: _new,
      onConnect: _hosts,
    );
  }

  Widget _list({bool sidebar = false}) => ConversationsPage(
    key: ValueKey('conversations:${widget.runtime.selectedHostId}:$sidebar'),
    runtime: widget.runtime,
    workspaceId: _navigation.workspaceId,
    sidebar: sidebar,
    onOpen: _open,
    onNew: _new,
    onHosts: _hosts,
    onWorkspace: _workspace,
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _changes,
    builder: (context, _) {
      final size = MediaQuery.sizeOf(context);
      // 横屏手机仍保留单栏，避免键盘挤占正文；宽屏才同时展示列表与对话。
      final wide = size.width >= 1000 && size.height >= 500;
      final chatting = _navigation.destination == GoDestination.conversations;
      widget.runtime.setConversationVisible(
        chatting && (wide || _navigation.detail),
      );
      final l = context.l10n;
      final destinations = [
        (
          GoDestination.conversations,
          l.navConversations,
          Icons.chat_bubble_outline_rounded,
          Icons.chat_bubble_rounded,
        ),
        (
          GoDestination.workspaces,
          l.navWorkspaces,
          Icons.folder_outlined,
          Icons.folder_rounded,
        ),
        (
          GoDestination.hosts,
          l.navHosts,
          Icons.dns_outlined,
          Icons.dns_rounded,
        ),
        (
          GoDestination.settings,
          l.navSettings,
          Icons.tune_rounded,
          Icons.tune_rounded,
        ),
      ];
      final page = switch (_navigation.destination) {
        GoDestination.conversations =>
          wide
              ? Row(
                  children: [
                    SizedBox(width: 336, child: _list(sidebar: true)),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: ColoredBox(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLowest,
                        child: _conversation(),
                      ),
                    ),
                  ],
                )
              : _navigation.detail
              ? _conversation()
              : _list(),
        GoDestination.workspaces => WorkspacesPage(
          runtime: widget.runtime,
          onOpen: _workspace,
          onHosts: _hosts,
        ),
        GoDestination.hosts => HostsPage(
          runtime: widget.runtime,
          onConnected: () => _navigation.select(GoDestination.conversations),
        ),
        GoDestination.settings => SettingsPage(runtime: widget.runtime),
      };
      return RemotePortLinkScope(
        onOpen: (context, uri, opener) =>
            openRemotePortLink(context, widget.runtime, uri, opener),
        child: PopScope(
          canPop:
              widget.runtime.hostKeyChallenge == null &&
              !_navigation.detail &&
              _navigation.destination == GoDestination.conversations,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (widget.runtime.hostKeyChallenge != null) {
              widget.runtime.answerHostKey(false);
              return;
            }
            if (_navigation.detail) {
              _navigation.backToList();
            } else {
              _navigation.select(GoDestination.conversations);
            }
          },
          child: Scaffold(
            bottomNavigationBar:
                wide ||
                    _navigation.detail ||
                    MediaQuery.viewInsetsOf(context).bottom > 0
                ? null
                : NavigationBar(
                    selectedIndex: _navigation.destination.index,
                    onDestinationSelected: (index) =>
                        _navigation.select(GoDestination.values[index]),
                    destinations: [
                      for (final (_, label, icon, selected) in destinations)
                        NavigationDestination(
                          icon: Icon(icon),
                          selectedIcon: Icon(selected),
                          label: label,
                        ),
                    ],
                  ),
            body: Stack(
              children: [
                SafeArea(
                  bottom: false,
                  child: Column(
                    children: [
                      if (widget.runtime.error case final error?)
                        _ConnectionNotice(
                          runtime: widget.runtime,
                          error: error,
                        ),
                      Expanded(
                        child: Row(
                          children: [
                            if (wide)
                              NavigationRail(
                                selectedIndex: _navigation.destination.index,
                                labelType: NavigationRailLabelType.all,
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .surface,
                                onDestinationSelected: (index) => _navigation
                                    .select(GoDestination.values[index]),
                                leading: const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16),
                                  child: GoMark(size: 38),
                                ),
                                destinations: [
                                  for (final (_, label, icon, selected)
                                      in destinations)
                                    NavigationRailDestination(
                                      icon: Icon(icon),
                                      selectedIcon: Icon(selected),
                                      label: Text(label),
                                    ),
                                ],
                              ),
                            Expanded(
                              child: wide && !chatting
                                  ? Center(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 960,
                                        ),
                                        child: page,
                                      ),
                                    )
                                  : page,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.runtime.hostKeyChallenge != null)
                  _HostTrustPrompt(runtime: widget.runtime),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ConnectionNotice extends StatelessWidget {
  const _ConnectionNotice({required this.runtime, required this.error});
  final CodexRuntime runtime;
  final String error;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.error_outline, size: 20),
      title: Text(error, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.goStatusDetails),
          content: SingleChildScrollView(child: SelectableText(error)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.close),
            ),
          ],
        ),
      ),
      trailing: IconButton(
        tooltip: context.l10n.dismiss,
        onPressed: runtime.clearError,
        icon: const Icon(Icons.close, size: 18),
      ),
    ),
  );
}

class _HostTrustPrompt extends StatelessWidget {
  const _HostTrustPrompt({required this.runtime});
  final CodexRuntime runtime;
  @override
  Widget build(BuildContext context) {
    final challenge = runtime.hostKeyChallenge!;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: AlertDialog(
            scrollable: true,
            title: Text(context.l10n.trustThisHostQuestion),
            content: SizedBox(
              width: 420,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(challenge.label),
                  const SizedBox(height: 14),
                  Text(challenge.algorithm),
                  const SizedBox(height: 8),
                  SelectableText(
                    challenge.fingerprint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => runtime.answerHostKey(false),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: () => runtime.answerHostKey(true),
                child: Text(context.l10n.trust),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
