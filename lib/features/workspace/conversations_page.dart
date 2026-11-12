import 'dart:async';

import 'package:flutter/material.dart';
import 'package:codex_go/shared/formatting/local_time.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/features/conversation/conversation_search.dart';
import 'package:codex_go/features/conversation/conversation_manager.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';

import 'workspace_navigation.dart';

class ConversationsPage extends StatefulWidget {
  const ConversationsPage({
    required this.runtime,
    required this.workspaceId,
    required this.onOpen,
    required this.onNew,
    required this.onHosts,
    required this.onWorkspace,
    this.sidebar = false,
    super.key,
  });
  final CodexRuntime runtime;
  final String? workspaceId;
  final ValueChanged<String> onOpen;
  final VoidCallback onNew;
  final VoidCallback onHosts;
  final ValueChanged<String?> onWorkspace;
  final bool sidebar;
  @override
  State<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends State<ConversationsPage> {
  final _query = TextEditingController();
  late final ConversationSearch _search;
  ConversationFilter _filter = ConversationFilter.all;
  String? _host;
  bool _connected = false;
  @override
  void initState() {
    super.initState();
    _host = widget.runtime.selectedHostId;
    _connected = widget.runtime.isConnected;
    _search = ConversationSearch(widget.runtime)..addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ConversationsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_host != widget.runtime.selectedHostId ||
        oldWidget.workspaceId != widget.workspaceId ||
        _connected != widget.runtime.isConnected) {
      _host = widget.runtime.selectedHostId;
      _connected = widget.runtime.isConnected;
      _search.search(_query.text, widget.workspaceId);
    }
  }

  @override
  void dispose() {
    _search.removeListener(_changed);
    _search.dispose();
    _query.dispose();
    super.dispose();
  }

  bool _attention(String id) =>
      widget.runtime.approvals.any((a) => a.threadId == id) ||
      widget.runtime.userInputRequests.any((r) => r.threadId == id);
  bool _matchesFilter(TaskRecord task) => switch (_filter) {
    ConversationFilter.all => true,
    ConversationFilter.attention =>
      _attention(task.id) ||
          task.status == TaskStatus.running ||
          task.status == TaskStatus.queued,
    ConversationFilter.pinned => task.isPinned,
  };
  TaskRecord _record(TaskSnapshot task) =>
      widget.runtime.taskState.tasks[task.id] ??
      TaskRecord(
        id: task.id,
        title: task.title,
        cwd: task.cwd,
        status: task.status,
        updatedAt: task.updatedAt,
        items: task.items,
        ownership: TaskOwnership.available,
        revision: 0,
        isPinned: task.isPinned,
        model: task.model,
        reasoningEffort: task.reasoningEffort,
      );
  Future<void> _refresh() async {
    if (!widget.runtime.isConnected) return;
    await widget.runtime.refreshTasks(resetPages: true);
    await widget.runtime.refreshSidebarPins();
    if (_query.text.trim().isNotEmpty) {
      _search.search(_query.text, widget.workspaceId);
    }
  }

  Future<void> _chooseWorkspace() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              ListTile(
                title: Text(
                  context.l10n.chooseWorkspace,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.apps_rounded),
                      title: Text(context.l10n.allWorkspaces),
                      selected: widget.workspaceId == null,
                      onTap: () => Navigator.pop(context, ''),
                    ),
                    for (final project in widget.runtime.projects)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(project.name),
                        subtitle: Text(
                          project.cwd,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        selected: widget.workspaceId == project.id,
                        onTap: () => Navigator.pop(context, project.id),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) widget.onWorkspace(result.isEmpty ? null : result);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.runtime;
    final colors = Theme.of(context).colorScheme;
    final l = context.l10n;
    final project = c.projects
        .where((p) => p.id == widget.workspaceId)
        .firstOrNull;
    final query = _query.text.trim().toLowerCase();
    final searching = query.isNotEmpty;
    final remoteSearch = searching && c.isConnected;
    var tasks = remoteSearch
        ? _search.results.map(_record).toList()
        : (project == null ? c.sidebarTasks : c.sidebarProjectTasks).toList();
    tasks = tasks
        .where(
          (task) =>
              _matchesFilter(task) &&
              (remoteSearch ||
                  !searching ||
                  '${task.title} ${task.cwd} ${task.items.lastOrNull?.text ?? ''}'
                      .toLowerCase()
                      .contains(query)),
        )
        .toList();
    tasks.sort(
      (a, b) => a.isPinned != b.isPinned
          ? (a.isPinned ? -1 : 1)
          : b.updatedAt.compareTo(a.updatedAt),
    );
    final hasMore = remoteSearch
        ? _search.hasMore
        : project == null
        ? c.hasMoreRecentTasks
        : c.hasMoreProjectTasks;
    final loadingMore = remoteSearch
        ? _search.loading
        : project == null
        ? c.isLoadingRecentTasks
        : c.isLoadingProjectPage;
    final hasHost = c.profiles.isNotEmpty;
    return LayoutBuilder(
      builder: (context, viewport) {
        // Scaffold 已扣除键盘高度，使用实际内容约束判断紧凑布局。
        final compact = viewport.maxHeight < 520;

        return Column(
          children: [
            if (!compact)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.sidebar ? 18 : 24,
                  20,
                  16,
                  16,
                ),
                child: Row(
                  children: [
                    // 品牌与连接入口共用顶部空间，保留完整触控区域。
                    Expanded(
                      child: InkWell(
                        onTap: widget.onHosts,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Row(
                            children: [
                              const GoMark(size: 36),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Codex Go',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge,
                                    ),
                                    if (hasHost)
                                      _HostSummary(runtime: c)
                                    else
                                      Text(
                                        l.navConversations,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (hasHost)
                      IconButton(
                        tooltip: l.goHistoryManager,
                        onPressed: c.isConnected
                            ? () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => ConversationManager(
                                    controller: c,
                                    onOpenTask: (task) {
                                      c.cacheFoundTask(task);
                                      widget.onOpen(task.id);
                                    },
                                  ),
                                ),
                              )
                            : null,
                        icon: const Icon(Icons.manage_search_rounded),
                      ),
                  ],
                ),
              ),
            if (hasHost && !compact)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: c.projects.isEmpty ? null : _chooseWorkspace,
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: Text(
                          project?.name ?? l.allWorkspaces,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      onPressed: widget.onNew,
                      tooltip: l.newChat,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              ),
            if (hasHost) const SizedBox(height: 12),
            if (hasHost)
              Padding(
                key: const ValueKey('conversation-search-field'),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: l.searchConversations,
                    isDense: true,
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: searching
                        ? IconButton(
                            tooltip: l.goClearSearch,
                            onPressed: () {
                              _query.clear();
                              _search.search('', widget.workspaceId);
                            },
                            icon: const Icon(Icons.close, size: 18),
                          )
                        : null,
                  ),
                  onChanged: (value) =>
                      _search.search(value, widget.workspaceId),
                ),
              ),
            if (hasHost)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final (filter, label, icon) in [
                        (
                          ConversationFilter.all,
                          l.all,
                          Icons.chat_bubble_outline_rounded,
                        ),
                        (
                          ConversationFilter.attention,
                          l.attention,
                          Icons.bolt_rounded,
                        ),
                        (
                          ConversationFilter.pinned,
                          l.pinned,
                          Icons.push_pin_outlined,
                        ),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: FilterChip(
                            selected: _filter == filter,
                            showCheckmark: false,
                            avatar: Icon(
                              icon,
                              size: 15,
                              color: _filter == filter
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                            label: Text(label),
                            onSelected: (_) => setState(() => _filter = filter),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (searching && !c.isConnected)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  l.goSearchOffline,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
            if (_search.loading) const LinearProgressIndicator(minHeight: 2),
            if (remoteSearch && _search.error != null)
              ListTile(
                leading: Icon(Icons.error_outline, color: colors.error),
                title: Text(l.searchFailed(_search.error!)),
                trailing: TextButton(
                  onPressed: _search.retry,
                  child: Text(l.retry),
                ),
              ),
            Expanded(
              child: !hasHost
                  ? GoEmptyState(
                      icon: Icons.devices_rounded,
                      title: l.goWelcomeTitle,
                      description: l.goWelcomeBody,
                      action: FilledButton.icon(
                        onPressed: widget.onHosts,
                        icon: const Icon(Icons.add),
                        label: Text(l.goAddFirstHost),
                      ),
                    )
                  : tasks.isEmpty && !_search.loading && !hasMore
                  ? GoEmptyState(
                      icon: searching
                          ? Icons.search_off_rounded
                          : _filter == ConversationFilter.attention
                          ? Icons.check_circle_outline
                          : Icons.forum_outlined,
                      title: searching
                          ? l.goNoSearchResults
                          : _filter == ConversationFilter.attention
                          ? l.goAttentionEmpty
                          : _filter == ConversationFilter.pinned
                          ? l.goPinnedEmpty
                          : l.goNoConversations,
                      description: searching
                          ? l.goNoSearchHint
                          : _filter == ConversationFilter.attention
                          ? l.goAttentionEmptyHint
                          : _filter == ConversationFilter.pinned
                          ? l.goPinnedEmptyHint
                          : l.goNoConversationsHint,
                      action: searching || _filter != ConversationFilter.all
                          ? null
                          : FilledButton.icon(
                              onPressed: widget.onNew,
                              icon: const Icon(Icons.add),
                              label: Text(l.goNewConversation),
                            ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                        itemCount:
                            tasks.length + (hasMore || loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == tasks.length) {
                            return Padding(
                              padding: const EdgeInsets.all(12),
                              child: loadingMore
                                  ? const Center(
                                      child: CircularProgressIndicator(),
                                    )
                                  : TextButton(
                                      onPressed: remoteSearch
                                          ? _search.more
                                          : project == null
                                          ? c.loadMoreRecentTasks
                                          : c.loadMoreProjectTasks,
                                      child: Text(l.loadMore),
                                    ),
                            );
                          }
                          final task = tasks[index];
                          final group = _group(context, task);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (index == 0 ||
                                  group != _group(context, tasks[index - 1]))
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    16,
                                    12,
                                    8,
                                  ),
                                  child: Text(
                                    group,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: colors.onSurfaceVariant,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              _ConversationRow(
                                task: task,
                                selected:
                                    c.selectedTaskId == task.id &&
                                    widget.sidebar,
                                attention: _attention(task.id),
                                unread: c.isTaskUnread(task.id),
                                onTap: () {
                                  if (remoteSearch) {
                                    c.cacheFoundTask(
                                      _search.results.firstWhere(
                                        (r) => r.id == task.id,
                                      ),
                                    );
                                  }
                                  widget.onOpen(task.id);
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  String _group(BuildContext context, TaskRecord task) {
    final l = context.l10n;
    if (task.isPinned) return l.pinned;
    final now = DateUtils.dateOnly(DateTime.now());
    final date = DateUtils.dateOnly(task.updatedAt.toLocal());
    final days = now.difference(date).inDays;
    return days <= 0
        ? l.today
        : days == 1
        ? l.yesterday
        : days < 7
        ? l.pastWeek
        : l.earlier;
  }
}

/// 长主机名优先省略，连接状态始终可见；触控由整个品牌区域承载。
class _HostSummary extends StatelessWidget {
  const _HostSummary({required this.runtime});
  final CodexRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connecting =
        runtime.connectionPhase == RemoteConnectionPhase.connecting ||
        runtime.connectionPhase == RemoteConnectionPhase.reconnecting;
    final status = runtime.isConnected
        ? context.l10n.connected
        : connecting
        ? context.l10n.connecting
        : context.l10n.offline;
    return DefaultTextStyle.merge(
      style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            size: 7,
            color: runtime.isConnected
                ? colors.secondary
                : connecting
                ? colors.primary
                : colors.outline,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              runtime.selectedHost?.label ?? context.l10n.connectHost,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(status),
          const SizedBox(width: 2),
          Icon(
            Icons.chevron_right_rounded,
            size: 14,
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.task,
    required this.selected,
    required this.attention,
    required this.unread,
    required this.onTap,
  });
  final TaskRecord task;
  final bool selected, attention, unread;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final running =
        task.status == TaskStatus.running || task.status == TaskStatus.queued;
    final folder =
        task.cwd.split('/').where((p) => p.isNotEmpty).lastOrNull ?? '';
    final preview = task.items
        .where(
          (i) => i.kind == TaskItemKind.agent || i.kind == TaskItemKind.user,
        )
        .lastOrNull
        ?.text
        .replaceAll(RegExp(r'\s+'), ' ');
    final locale = Localizations.localeOf(context).toLanguageTag();
    final timeLabel = formatLocalTime(task.updatedAt, locale);
    final tone = attention
        ? colors.tertiary
        : running
        ? colors.primary
        : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected
            ? colors.primaryContainer
            : colors.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected
                ? colors.primary.withValues(alpha: .25)
                : colors.outlineVariant.withValues(alpha: .55),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Icon(
                        attention
                            ? Icons.pending_actions_rounded
                            : running
                            ? Icons.bolt_rounded
                            : Icons.chat_bubble_outline_rounded,
                        size: 18,
                        color: tone,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: unread || selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (unread)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 6),
                        child: Icon(
                          Icons.circle,
                          size: 7,
                          color: colors.primary,
                        ),
                      ),
                  ],
                ),
                if (preview != null && preview.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 7, left: 28),
                    child: Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    const SizedBox(width: 28),
                    if (task.isPinned) ...[
                      Icon(
                        Icons.push_pin_rounded,
                        size: 12,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                      child: Text(
                        attention
                            ? context.l10n.goConversationPending
                            : running
                            ? context.l10n.running
                            : folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: tone),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message: formatFullLocalTime(task.updatedAt, locale),
                      child: Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
