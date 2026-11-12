// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
final class TaskRefreshLease<T> {
  TaskRefreshLease._(this.session, this.epoch);

  final T session;
  final int epoch;
  var _queued = false;
  var _queuedResetPages = false;

  void _queue({required bool resetPages}) {
    _queued = true;
    _queuedResetPages = _queuedResetPages || resetPages;
  }

  bool? takeQueuedResetPages() {
    if (!_queued) return null;
    final resetPages = _queuedResetPages;
    _queued = false;
    _queuedResetPages = false;
    return resetPages;
  }
}

final class TaskRefreshLock<T> {
  TaskRefreshLease<T>? _owner;

  TaskRefreshLease<T>? tryAcquire(
    T session,
    int epoch, {
    bool resetPages = false,
  }) {
    final owner = _owner;
    if (owner != null &&
        identical(owner.session, session) &&
        owner.epoch == epoch) {
      owner._queue(resetPages: resetPages);
      return null;
    }
    final replacement = TaskRefreshLease<T>._(session, epoch);
    _owner = replacement;
    return replacement;
  }

  void release(TaskRefreshLease<T> owner) {
    if (identical(_owner, owner)) _owner = null;
  }
}
