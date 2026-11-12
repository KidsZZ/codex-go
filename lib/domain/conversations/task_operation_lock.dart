// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
final class TaskOperationLease {
  TaskOperationLease._();
}

final class TaskOperationLock {
  final Map<String, TaskOperationLease> _owners = {};

  TaskOperationLease? tryAcquire(String threadId) {
    final candidate = TaskOperationLease._();
    final owner = _owners.putIfAbsent(threadId, () => candidate);
    return identical(owner, candidate) ? candidate : null;
  }

  void release(String threadId, TaskOperationLease owner) {
    if (identical(_owners[threadId], owner)) _owners.remove(threadId);
  }

  void clear() => _owners.clear();
}
