// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';

import 'package:flutter/material.dart';

import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/l10n/strings.dart';

/// Full server search and archive/pin management live behind one entry point.
class ConversationManager extends StatefulWidget {
  const ConversationManager({
    required this.controller,
    required this.onOpenTask,
    super.key,
  });
  final CodexRuntime controller;
  final ValueChanged<TaskSnapshot> onOpenTask;

  @override
  State<ConversationManager> createState() => _ConversationManagerState();
}

class _ConversationManagerState extends State<ConversationManager> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<TaskSnapshot> _tasks = [];
  String? _cursor;
  String? _error;
  bool _archived = false;
  bool _pinned = false;
  bool _loading = false;
  bool _mutating = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    final generation = ++_generation;
    final host = widget.controller.selectedHostId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.controller.findTasks(
        query: _search.text,
        archived: _archived,
        pinned: _pinned ? true : null,
        cursor: more ? _cursor : null,
      );
      if (!mounted ||
          generation != _generation ||
          host != widget.controller.selectedHostId) {
        return;
      }
      setState(() {
        _tasks = more ? [..._tasks, ...page.tasks] : page.tasks;
        _cursor = page.nextCursor;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _action(TaskSnapshot task, String action) async {
    if (_mutating) return;
    setState(() => _mutating = true);
    try {
      switch (action) {
        case 'rename':
          final name = await askTaskName(context, task.title);
          if (name == null || !mounted) return;
          await widget.controller.renameTask(task.id, name);
        case 'pin':
          await widget.controller.pinTask(task.id, !task.isPinned);
        case 'archive':
          if (!_archived && !await confirmArchive(context)) return;
          await widget.controller.archiveTask(task.id, !_archived);
      }
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(l.goHistoryManager)),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    hintText: l.searchAllTasks,
                    prefixIcon: const Icon(Icons.search),
                  ),
                  onChanged: (_) {
                    _debounce?.cancel();
                    ++_generation;
                    _debounce = Timer(const Duration(milliseconds: 350), _load);
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    FilterChip(
                      label: Text(l.pinned),
                      selected: _pinned,
                      onSelected: _mutating
                          ? null
                          : (value) {
                              setState(() => _pinned = value);
                              _load();
                            },
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: Text(l.archived),
                      selected: _archived,
                      onSelected: _mutating
                          ? null
                          : (value) {
                              setState(() => _archived = value);
                              _load();
                            },
                    ),
                  ],
                ),
              ),
            ),
            if (_loading || _mutating)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (_error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: TextButton.icon(
                    onPressed: _loading ? null : _load,
                    icon: Icon(Icons.error_outline, color: colors.error),
                    label: Text(
                      l.searchFailed(_error!),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              sliver: SliverList.builder(
                itemCount: _tasks.length,
                itemBuilder: (context, index) {
                  final task = _tasks[index];
                  return ListTile(
                    title: Text(
                      task.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      task.cwd,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: Icon(
                      task.isPinned
                          ? Icons.push_pin_outlined
                          : _archived
                          ? Icons.inventory_2_outlined
                          : Icons.chat_bubble_outline,
                      size: 20,
                    ),
                    onTap: _archived || _mutating
                        ? null
                        : () {
                            Navigator.pop(context);
                            widget.onOpenTask(task);
                          },
                    trailing: PopupMenuButton<String>(
                      enabled: !_mutating && !_loading,
                      onSelected: (value) => _action(task, value),
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'rename', child: Text(l.rename)),
                        PopupMenuItem(
                          value: 'pin',
                          child: Text(task.isPinned ? l.unpin : l.pin),
                        ),
                        PopupMenuItem(
                          value: 'archive',
                          child: Text(_archived ? l.restore : l.archive),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (!_loading && _tasks.isEmpty && _error == null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l.noTasksFound,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            if (_cursor != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextButton(
                    onPressed: _loading ? null : () => _load(more: true),
                    child: Text(l.loadMore),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<String?> askTaskName(BuildContext context, String initial) async {
  final editor = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.renameTask),
      content: TextField(controller: editor, autofocus: true, maxLength: 200),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (editor.text.trim().isNotEmpty) {
              Navigator.pop(context, editor.text.trim());
            }
          },
          child: Text(context.l10n.save),
        ),
      ],
    ),
  );
  // The dialog may still be animating out when its future completes.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  editor.dispose();
  return result;
}

Future<bool> confirmArchive(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.archiveTaskQuestion),
        content: Text(context.l10n.thisHidesTheTaskAndMayArchiveIts),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.archive),
          ),
        ],
      ),
    ) ??
    false;
