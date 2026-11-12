import 'package:flutter/material.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/l10n/strings.dart';

/// 将协议事件转成读者关心的动作；原始命令与输出仍在展开详情中保留。
String activityLabel(BuildContext context, TaskItem item) =>
    switch (item.activityKind) {
      TaskActivityKind.read => context.l10n.chatRead,
      TaskActivityKind.search => context.l10n.chatSearch,
      TaskActivityKind.listFiles => context.l10n.chatBrowse,
      TaskActivityKind.plan => context.l10n.chatPlan,
      TaskActivityKind.context => context.l10n.chatContext,
      _ => switch (item.kind) {
        TaskItemKind.command => context.l10n.chatExecute,
        TaskItemKind.file => context.l10n.chatEdit,
        TaskItemKind.reasoning => context.l10n.reasoning,
        TaskItemKind.tool => context.l10n.tool,
        _ => context.l10n.chatEvent,
      },
    };

String activityDetail(TaskItem item) =>
    (item.activityTarget ??
            (item.kind == TaskItemKind.reasoning
                ? item.text
                : item.title ?? item.text))
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

IconData activityIcon(TaskItem item) => switch (item.activityKind) {
  TaskActivityKind.read => Icons.description_outlined,
  TaskActivityKind.search => Icons.search_rounded,
  TaskActivityKind.listFiles => Icons.folder_open_rounded,
  TaskActivityKind.plan => Icons.checklist_rounded,
  TaskActivityKind.context => Icons.layers_outlined,
  _ => switch (item.kind) {
    TaskItemKind.command => Icons.terminal_rounded,
    TaskItemKind.file => Icons.edit_note_rounded,
    TaskItemKind.reasoning => Icons.auto_awesome_outlined,
    TaskItemKind.tool => Icons.extension_outlined,
    _ => Icons.info_outline_rounded,
  },
};

bool activityFailed(TaskItem item) => const {
  'failed',
  'declined',
  'denied',
  'errored',
  'interrupted',
}.contains(item.status);

Color activityColor(BuildContext context, TaskItem item) {
  final colors = Theme.of(context).colorScheme;
  if (activityFailed(item)) return colors.error;
  return switch (item.activityKind) {
    TaskActivityKind.read || TaskActivityKind.listFiles => colors.secondary,
    TaskActivityKind.search => colors.primary,
    _ => switch (item.kind) {
      TaskItemKind.file => colors.tertiary,
      TaskItemKind.reasoning => colors.primary,
      _ => colors.onSurfaceVariant,
    },
  };
}

String activitySummary(BuildContext context, List<TaskItem> items) {
  final counts = <String, int>{};
  for (final item in items) {
    if (item.kind == TaskItemKind.agent) continue;
    final label = activityLabel(context, item);
    counts[label] = (counts[label] ?? 0) + 1;
  }
  return counts.entries
      .map((entry) => '${entry.key} ${entry.value}')
      .join(' · ');
}
