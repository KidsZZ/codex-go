// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/features/conversation/widgets/timeline_item.dart';
import 'package:codex_go/l10n/strings.dart';

/// 过程按回合收纳，展开后仍可复制原始命令、思考与中间回复。
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
    final commands = items.where((i) => i.kind == TaskItemKind.command).length;
    final files = items.where((i) => i.kind == TaskItemKind.file).length;
    final duration = turn.durationMs;
    return ExpansionTile(
      key: ValueKey('process:${items.first.id}'),
      initiallyExpanded: expanded,
      onExpansionChanged: onExpanded,
      expansionAnimationStyle: const AnimationStyle(
        duration: Duration.zero,
        reverseDuration: Duration.zero,
      ),
      tilePadding: const EdgeInsets.symmetric(horizontal: 4),
      childrenPadding: const EdgeInsets.fromLTRB(8, 0, 0, 16),
      shape: const Border(),
      collapsedShape: const Border(),
      leading: const Icon(Icons.check, size: 18),
      title: Text(
        context.l10n.completedSteps(
          (items.length).toString(),
          (duration == null
                  ? ''
                  : context.l10n.durationSeconds((duration / 1000).round()))
              .toString(),
        ),
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: Text(
        [
          if (commands > 0) context.l10n.commandCount((commands).toString()),
          if (files > 0) context.l10n.fileOperationCount((files).toString()),
          if (commands == 0 && files == 0) context.l10n.viewExecutionProcess,
        ].join(' · '),
        style: const TextStyle(fontSize: 11),
      ),
      children: [
        for (final item in items)
          TimelineItemView(item: item, loadImage: loadImage),
      ],
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
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.difference_outlined, size: 19),
        title: Text(
          context.l10n.changedFileCount((files.length).toString()),
          style: const TextStyle(fontSize: 13),
        ),
        children: [
          for (final entry in files.entries)
            ListTile(
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined, size: 17),
              title: Text(
                entry.key,
                style: const TextStyle(fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (context) => SafeArea(
                  child: SizedBox(
                    height: MediaQuery.sizeOf(context).height * .85,
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(
                            entry.key,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: context.l10n.copyDiff,
                            icon: const Icon(Icons.copy, size: 18),
                            onPressed: () => Clipboard.setData(
                              ClipboardData(
                                text: entry.value.map((c) => c.diff).join('\n'),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (final change in entry.value) ...[
                                  Text(
                                    change.kind,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium,
                                  ),
                                  SelectableText(
                                    change.diff.isEmpty
                                        ? context.l10n.diffUnavailable
                                        : change.diff,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
