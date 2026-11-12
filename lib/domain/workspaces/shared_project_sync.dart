// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:codex_go/infrastructure/storage/profile_store.dart';
import 'package:codex_go/infrastructure/codex/codex_remote_api.dart';
import 'package:codex_go/domain/workspaces/remote_project.dart';

/// The server is authoritative. Local records are a cache, except for legacy
/// projects which are imported once, with a stable retry-safe creation key.
final class SharedProjectSync {
  SharedProjectSync(this.api, this.store, this.hostId, this.checkSession);

  final CodexRemoteApi api;
  final ProfileStore store;
  final String hostId;
  final void Function() checkSession;

  // 以项目和根目录保存扫描进度；只在当前连接中复用，重连后重新核对历史。
  final Map<(String, String), String> _membershipHeads = {};

  var _membershipGeneration = 0;

  void invalidateMemberships() {
    _membershipGeneration++;
    _membershipHeads.clear();
  }

  Future<List<RemoteProject>> synchronize() async {
    final remote = await api.readProjects(hostId);
    checkSession();
    final cached = await store.readProjects(hostId);
    checkSession();
    for (final local in cached.where(
      (project) => project.remoteId == null && !project.discovered,
    )) {
      final matches = remote.where((p) => p.containsCwd(local.cwd)).toList();
      // Do not guess between two shared projects that use the same directory.
      final project = matches.length == 1
          ? matches.single
          : await api.createProject(local);
      checkSession();
      if (!remote.any((p) => p.remoteId == project.remoteId)) {
        remote.add(project);
      }
      await adoptUnassignedTasks(project, cwd: local.cwd);
      checkSession();
      // Remove the legacy record only after both the server and cache succeeded.
      await store.writeProject(project);
      checkSession();
      await store.deleteProject(hostId, local.id);
      checkSession();
    }
    for (final project in remote) {
      if (!cached.contains(project)) await store.writeProject(project);
      checkSession();
    }
    for (final local in cached.where((project) => project.remoteId != null)) {
      if (!remote.any((project) => project.remoteId == local.remoteId)) {
        await store.deleteProject(hostId, local.id);
        checkSession();
      }
    }
    return [
      ...remote,
      ...cached.where(
        (local) =>
            local.discovered &&
            !remote.any((shared) => shared.containsCwd(local.cwd)),
      ),
    ];
  }

  /// 给已有共享项目补齐目录归属，重叠根目录由用户明确选择，不能自动猜测。
  Future<bool> reconcileMemberships(List<RemoteProject> projects) async {
    final generation = _membershipGeneration;
    final ownersByRoot = <String, Map<String, RemoteProject>>{};
    for (final project in projects) {
      final id = project.remoteId;
      if (id == null) continue;
      for (final path in project.roots) {
        final root = normalizeRemoteCwd(path);
        if (!root.startsWith('/')) continue;
        (ownersByRoot[root] ??= {})[id] = project;
      }
    }
    final owners = <(String, String), RemoteProject>{
      for (final entry in ownersByRoot.entries)
        if (entry.value.length == 1)
          (entry.value.keys.single, entry.key): entry.value.values.single,
    };
    _membershipHeads.removeWhere((key, _) => !owners.containsKey(key));
    var changed = false;
    for (final entry in owners.entries) {
      checkSession();
      final result = await _adoptUnassignedTasks(
        entry.value,
        cwd: entry.key.$2,
        stopAtThreadId: _membershipHeads[entry.key],
      );
      checkSession();
      changed = changed || result.changed;
      // 扫描期间若恢复了旧会话，保留失效状态，下次刷新会重新完整扫描。
      if (generation != _membershipGeneration) continue;
      final head = result.headThreadId;
      if (head == null) {
        _membershipHeads.remove(entry.key);
      } else {
        _membershipHeads[entry.key] = head;
      }
    }
    return changed;
  }

  Future<void> adoptUnassignedTasks(
    RemoteProject project, {
    required String cwd,
  }) async {
    await _adoptUnassignedTasks(project, cwd: cwd);
  }

  Future<({bool changed, String? headThreadId})> _adoptUnassignedTasks(
    RemoteProject project, {
    required String cwd,
    String? stopAtThreadId,
  }) async {
    final normalizedCwd = normalizeRemoteCwd(cwd);
    final cursors = <String>{};
    String? cursor;
    String? headThreadId;
    var changed = false;
    do {
      checkSession();
      // 归属更新可能改变活跃时间，使用创建时间分页，避免更新过程中漏项。
      final page = await api.readTaskPage(
        cwd: cwd,
        cursor: cursor,
        sortKey: 'created_at',
      );
      checkSession();
      if (headThreadId == null && page.tasks.isNotEmpty) {
        headThreadId = page.tasks.first.id;
      }
      var reachedPreviousHead = false;
      for (final task in page.tasks) {
        reachedPreviousHead = reachedPreviousHead || task.id == stopAtThreadId;
        // 精确匹配根目录；已有归属保持不变，不能把家目录的子项目一并归入。
        if (task.projectId != null ||
            normalizeRemoteCwd(task.cwd) != normalizedCwd) {
          continue;
        }
        await api.assignThreadProject(task.id, project.remoteId!);
        checkSession();
        changed = true;
      }
      // 本页仍逐项检查，可处理最近会话重新变为未归属的情况。
      if (reachedPreviousHead) break;
      cursor = page.nextCursor;
      if (cursor != null && !cursors.add(cursor)) {
        throw StateError(
          'Task pagination repeated a cursor during project migration.',
        );
      }
    } while (cursor != null);
    return (changed: changed, headThreadId: headThreadId);
  }
}
