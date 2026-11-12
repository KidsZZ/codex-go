// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:codex_go/domain/conversations/task_reducer.dart';

/// 行是回合的阅读投影。稳定 ID 同时用于折叠状态与滚动锚点。
sealed class TimelineEntry {
  const TimelineEntry();
  String get key;
}

final class TimelineMessageEntry extends TimelineEntry {
  const TimelineMessageEntry(this.item, {this.showActions = true});
  final TaskItem item;
  final bool showActions;
  @override
  String get key => 'message:${item.id}';
}

final class TimelineActivityEntry extends TimelineEntry {
  const TimelineActivityEntry(this.items);
  final List<TaskItem> items;
  @override
  String get key => 'activity:${items.first.id}';
}

final class TimelineProcessEntry extends TimelineEntry {
  const TimelineProcessEntry(this.items, this.turn);
  final List<TaskItem> items;
  final TaskTurnInfo turn;
  @override
  String get key => 'process:${items.first.id}';
}

final class TimelineChangesEntry extends TimelineEntry {
  const TimelineChangesEntry(this.items);
  final List<TaskItem> items;
  @override
  String get key => 'changes:${items.first.id}';
}

List<TimelineEntry> buildTimelineEntries(List<TaskItem> items) {
  final result = <TimelineEntry>[];
  final lastAnswers = <String, String>{};
  final lastMessages = <String, String>{};
  for (final item in items) {
    if (item.kind == TaskItemKind.agent &&
        item.turnId != null &&
        item.text.trim().isNotEmpty) {
      lastMessages[item.turnId!] = item.id;
    }
    if (item.kind == TaskItemKind.agent &&
        item.turnId != null &&
        item.phase != 'commentary' &&
        item.text.trim().isNotEmpty) {
      lastAnswers[item.turnId!] = item.id;
    }
  }
  for (final entry in lastMessages.entries) {
    lastAnswers.putIfAbsent(entry.key, () => entry.value);
  }
  var segment = <TaskItem>[];
  void flush() {
    if (segment.isEmpty) return;
    final turn = segment
        .map((i) => i.turn)
        .whereType<TaskTurnInfo>()
        .firstOrNull;
    final process = <TaskItem>[];
    final exposed = <TaskItem>[];
    if (turn?.completed == true) {
      for (final item in segment) {
        final isAnswer =
            item.kind == TaskItemKind.agent &&
            (item.phase == 'final_answer' ||
                lastAnswers[item.turnId] == item.id);
        if (const {
              'failed',
              'declined',
              'denied',
              'errored',
              'interrupted',
            }.contains(item.status) ||
            isAnswer ||
            item.attachments.isNotEmpty ||
            item.questions.isNotEmpty ||
            item.subagents.isNotEmpty ||
            item.kind == TaskItemKind.notice) {
          exposed.add(item);
        } else {
          process.add(item);
        }
      }
      if (process.isNotEmpty) {
        result.add(TimelineProcessEntry(List.unmodifiable(process), turn!));
      }
      final changed = segment
          .where(
            (item) =>
                item.changes.isNotEmpty &&
                item.status != 'failed' &&
                item.status != 'declined',
          )
          .toList();
      if (changed.isNotEmpty) {
        result.add(TimelineChangesEntry(List.unmodifiable(changed)));
      }
    } else {
      exposed.addAll(segment);
    }
    var activities = <TaskItem>[];
    void flushActivities() {
      if (activities.isEmpty) return;
      result.add(TimelineActivityEntry(List.unmodifiable(activities)));
      activities = [];
    }

    for (final item in exposed) {
      if (item.kind == TaskItemKind.agent || item.kind == TaskItemKind.user) {
        flushActivities();
        if (item.text.trim().isNotEmpty ||
            item.attachments.isNotEmpty ||
            item.questions.isNotEmpty) {
          result.add(
            TimelineMessageEntry(
              item,
              showActions:
                  item.kind == TaskItemKind.user ||
                  item.turnId == null ||
                  (lastAnswers[item.turnId] == item.id &&
                      (item.phase != 'commentary' || turn?.completed == true)),
            ),
          );
        }
      } else {
        activities.add(item);
      }
    }
    flushActivities();
    segment = [];
  }

  for (final item in items) {
    // 用户插话切开过程段，绝不被折叠容器吞掉。
    if (item.kind == TaskItemKind.user) {
      flush();
      if (item.text.trim().isNotEmpty || item.attachments.isNotEmpty) {
        result.add(TimelineMessageEntry(item));
      }
    } else {
      if (segment.isNotEmpty && segment.last.turnId != item.turnId) flush();
      segment.add(item);
    }
  }
  flush();
  return List.unmodifiable(result);
}
