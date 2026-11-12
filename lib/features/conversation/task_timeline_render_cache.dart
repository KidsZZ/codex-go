// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:codex_go/domain/conversations/task_reducer.dart';

final class TaskTimelineRenderState {
  const TaskTimelineRenderState({
    required this.items,
    this.owner,
    this.loading = false,
    this.error,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.olderError,
  });

  final List<TaskItem> items;
  final Object? owner;
  final bool loading;
  final String? error;
  final bool hasOlder;
  final bool loadingOlder;
  final String? olderError;

  bool matches(TaskTimelineRenderState other) =>
      identical(items, other.items) &&
      identical(owner, other.owner) &&
      loading == other.loading &&
      error == other.error &&
      hasOlder == other.hasOlder &&
      loadingOlder == other.loadingOlder &&
      olderError == other.olderError;
}

final class TaskTimelineRenderCache<T> {
  TaskTimelineRenderState? _state;
  late T _value;

  T resolve(TaskTimelineRenderState state, T Function() build) {
    final current = _state;
    if (current != null && current.matches(state)) return _value;
    _state = state;
    return _value = build();
  }

  void clear() => _state = null;
}
