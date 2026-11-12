import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/l10n/strings.dart';

import 'activity_presentation.dart';
import 'code_block.dart';
import 'process_disclosure.dart';
import 'timeline_item.dart';

/// 正常结束后收纳过程，摘要仍可读出做过的工作，正文与错误保留在时间线上。
class TurnProcess extends StatelessWidget {
  const TurnProcess({
    required this.items,
    required this.turn,
    this.loadImage,
    this.expanded = false,
    this.onExpanded,
    super.key,
  });
  final List<TaskItem> items;
  final TaskTurnInfo turn;
  final bool expanded;
  final ValueChanged<bool>? onExpanded;
  final Future<Uint8List> Function(String)? loadImage;
  @override
  Widget build(BuildContext context) {
    final duration = turn.durationMs;
    final summary = activitySummary(context, items);
    return ProcessDisclosure(
      key: PageStorageKey('process:${items.first.id}'),
      icon: Icons.check_rounded,
      label: duration == null
          ? context.l10n.chatProcess
          : '${context.l10n.completed}${context.l10n.durationSeconds((duration / 1000).round())}',
      detail: summary.isEmpty ? context.l10n.viewExecutionProcess : summary,
      initiallyExpanded: expanded,
      onChanged: onExpanded,
      child: ProcessDetailViewport(
        itemCount: items.length,
        itemBuilder: (_, index) => Padding(
          padding: EdgeInsets.symmetric(
            vertical: items[index].kind == TaskItemKind.agent ? 6 : 0,
          ),
          child: TimelineItemView(
            key: ValueKey(items[index].id),
            item: items[index],
            loadImage: loadImage,
            showActions: false,
          ),
        ),
      ),
    );
  }
}

class TurnChanges extends StatelessWidget {
  const TurnChanges({required this.items, super.key});
  final List<TaskItem> items;
  @override
  Widget build(BuildContext context) {
    final files = <String, List<TaskFileChange>>{};
    for (final item in items) {
      for (final change in item.changes) {
        (files[change.path] ??= []).add(change);
      }
    }
    final allDiffs = files.values
        .expand((v) => v)
        .map((c) => c.diff)
        .join('\n');
    return ProcessDisclosure(
      key: PageStorageKey('changes:${items.first.id}'),
      icon: Icons.difference_outlined,
      label: context.l10n.changedFileCount(files.length.toString()),
      color: Theme.of(context).colorScheme.tertiary,
      trailing: _DiffCount(diff: allDiffs),
      child: Column(
        children: [
          for (final entry in files.entries)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                entry.key,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'GoMono', fontSize: 12),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _DiffCount(
                  diff: entry.value.map((c) => c.diff).join('\n'),
                ),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: () => _showDiff(context, entry.key, entry.value),
            ),
        ],
      ),
    );
  }

  void _showDiff(
    BuildContext context,
    String path,
    List<TaskFileChange> changes,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: Column(
            children: [
              ListTile(
                title: Text(path, maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: context.l10n.close,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final change in changes)
                        change.diff.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(context.l10n.diffUnavailable),
                              )
                            : ConversationCodeBlock(
                                code: change.diff,
                                language: 'diff',
                              ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiffCount extends StatelessWidget {
  const _DiffCount({required this.diff});
  final String diff;
  @override
  Widget build(BuildContext context) {
    final lines = diff.split('\n');
    final added = lines
        .where((s) => s.startsWith('+') && !s.startsWith('+++'))
        .length;
    final removed = lines
        .where((s) => s.startsWith('-') && !s.startsWith('---'))
        .length;
    if (added == 0 && removed == 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '+$added',
            style: TextStyle(color: colors.secondary),
          ),
          const TextSpan(text: '  '),
          TextSpan(
            text: '−$removed',
            style: TextStyle(color: colors.error),
          ),
        ],
      ),
      style: const TextStyle(fontFamily: 'GoMono', fontSize: 11),
    );
  }
}
