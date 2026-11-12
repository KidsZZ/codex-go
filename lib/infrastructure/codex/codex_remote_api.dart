// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';
import 'dart:convert';

import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/domain/conversations/message_attachments.dart';
import 'package:codex_go/domain/workspaces/remote_project.dart';
import 'package:codex_go/infrastructure/codex/json_rpc_client.dart';
import 'package:codex_go/domain/conversations/permission_mode.dart';
import 'package:codex_go/domain/conversations/mcp_mentions.dart';

final class RemoteMcpServer {
  const RemoteMcpServer({
    required this.name,
    required this.authStatus,
    required this.tools,
    this.pluginId,
    this.error,
  });
  final String name;
  final String authStatus;
  final List<String> tools;
  final String? pluginId;
  final String? error;
}

final class RemoteTaskBatch {
  const RemoteTaskBatch({required this.tasks, required this.loadedThreadIds});

  final List<TaskSnapshot> tasks;
  final Set<String> loadedThreadIds;
}

final class RemoteTaskPage {
  const RemoteTaskPage({required this.tasks, required this.nextCursor});

  final List<TaskSnapshot> tasks;
  final String? nextCursor;
}

final class RemoteTurnPage {
  const RemoteTurnPage({required this.items, required this.nextCursor});

  final List<TaskItem> items;
  final String? nextCursor;
}

typedef RemoteSubagentDetails = ({String? nickname, String? role});

final class RemoteSkill {
  const RemoteSkill({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;
}

final class RemoteReasoningEffort {
  const RemoteReasoningEffort({
    required this.effort,
    required this.description,
  });

  final String effort;
  final String description;
}

final class RemoteModel {
  const RemoteModel({
    required this.id,
    required this.model,
    required this.displayName,
    required this.description,
    required this.isDefault,
    required this.defaultReasoningEffort,
    required this.supportedReasoningEfforts,
    this.serviceTiers = const [],
    this.defaultServiceTier,
  });

  final String id;
  final String model;
  final String displayName;
  final String description;
  final bool isDefault;
  final String defaultReasoningEffort;
  final List<RemoteReasoningEffort> supportedReasoningEfforts;
  final List<String> serviceTiers;
  final String? defaultServiceTier;
  String? get fastServiceTier => serviceTiers.contains('fast')
      ? 'fast'
      : serviceTiers.contains('priority')
      ? 'priority'
      : null;
  bool get supportsFast =>
      serviceTiers.contains('fast') || serviceTiers.contains('priority');
  String? get ultraFastServiceTier =>
      serviceTiers.where(isUltraFastTier).firstOrNull;
}

bool isUltraFastTier(String? tier) =>
    tier?.toLowerCase().replaceAll(RegExp('[-_]'), '') == 'ultrafast';

final class RemoteThreadGoal {
  const RemoteThreadGoal({
    required this.objective,
    required this.status,
    required this.tokenBudget,
    required this.tokensUsed,
    required this.timeUsedSeconds,
  });

  final String objective;
  final String status;
  final int? tokenBudget;
  final int tokensUsed;
  final int timeUsedSeconds;
}

final class PendingApproval {
  const PendingApproval({
    required this.requestId,
    required this.method,
    required this.threadId,
    required this.title,
    required this.detail,
    required this.availableDecisions,
    required this.requestedPermissions,
  });

  final Object requestId;
  final String method;
  final String threadId;
  final String title;
  final String detail;
  final List<String> availableDecisions;
  final Map<String, dynamic>? requestedPermissions;

  bool get isPermissionRequest => method == 'item/permissions/requestApproval';
}

final class CodexRemoteApi {
  final _mcpCatalog =
      <String, ({DateTime expires, Future<List<RemoteMcpServer>> load})>{};
  CodexRemoteApi(this._rpc);

  final JsonRpcClient _rpc;

  Stream<RpcNotification> get notifications => _rpc.notifications;
  Stream<RpcServerRequest> get serverRequests => _rpc.serverRequests;

  Future<Map<String, dynamic>> readAccountRateLimits() async => _map(
    await _rpc.requestWithTimeout(
      'account/rateLimits/read',
      const {},
      const Duration(seconds: 10),
    ),
  );

  Future<void> initialize() async {
    await _rpc.request('initialize', {
      'clientInfo': {
        'name': 'codex_go',
        'title': 'Codex Go',
        'version': '0.1.0',
      },
      'capabilities': {'experimentalApi': true},
    });
    _rpc.notify('initialized', const {});
  }

  Future<RemoteTaskBatch> readTaskBatch() async {
    final page = await readTaskPage();
    final loaded = await readLoadedThreadIds();
    return RemoteTaskBatch(tasks: page.tasks, loadedThreadIds: loaded);
  }

  Future<RemoteTaskPage> readTaskPage({
    String? cwd,
    String? projectId,
    String? cursor,
    String sortKey = 'recency_at',
    String? searchTerm,
    bool archived = false,
    bool? isPinned,
  }) async {
    final result = _map(
      await _rpc.request('thread/list', {
        'limit': 20,
        'archived': archived,
        if (searchTerm != null && searchTerm.trim().isNotEmpty)
          'searchTerm': searchTerm.trim(),
        if (isPinned != null) 'isPinned': isPinned,
        'sortKey': sortKey,
        'sortDirection': 'desc',
        if (cwd != null) 'cwd': cwd,
        if (projectId != null) 'projectId': projectId,
        if (cursor != null) 'cursor': cursor,
      }),
    );
    final data = result['data'] as List<dynamic>? ?? const [];
    return RemoteTaskPage(
      tasks: List.unmodifiable(data.map((item) => parseThread(_map(item)))),
      nextCursor: result['nextCursor'] as String?,
    );
  }

  Future<List<RemoteProject>> readProjects(String hostId) async {
    final projects = <RemoteProject>[];
    final cursors = <String>{};
    String? cursor;
    do {
      final result = _map(
        await _rpc.request('project/list', {
          'limit': 100,
          'sortKey': 'recencyAt',
          if (cursor != null) 'cursor': cursor,
        }),
      );
      for (final project in result['data'] as List<dynamic>? ?? const []) {
        projects.add(_parseProject(_map(project), hostId));
      }
      cursor = result['nextCursor'] as String?;
      if (cursor != null && !cursors.add(cursor)) {
        throw StateError('Project pagination repeated a cursor.');
      }
    } while (cursor != null);
    return projects;
  }

  Future<RemoteProject> createProject(RemoteProject project) async {
    final result = _map(
      await _rpc.request('project/create', {
        'name': project.name,
        'roots': [
          for (final path in project.roots)
            if (path.isNotEmpty) {'path': path},
        ],
        'idempotencyKey': 'codex-go:${project.id}',
      }),
    );
    return _parseProject(_map(result['project']), project.hostId);
  }

  Future<RemoteProject> updateProject(RemoteProject project) async {
    final result = _map(
      await _rpc.request('project/update', {
        'projectId': project.remoteId,
        'name': project.name,
        'roots': [
          for (final path in project.roots)
            if (path.isNotEmpty) {'path': path},
        ],
      }),
    );
    return _parseProject(_map(result['project']), project.hostId);
  }

  Future<void> deleteProject(String projectId) async {
    await _rpc.request('project/delete', {'projectId': projectId});
  }

  Future<void> assignThreadProject(String threadId, String projectId) async {
    await _rpc.request('thread/metadata/update', {
      'threadId': threadId,
      'projectId': projectId,
    });
  }

  static RemoteProject _parseProject(
    Map<String, dynamic> value,
    String hostId,
  ) {
    final roots = (value['roots'] as List<dynamic>? ?? const [])
        .map((root) => _map(root)['path'])
        .whereType<String>()
        .toList();
    final id = value['id'] as String;
    return RemoteProject(
      id: 'remote:$id',
      remoteId: id,
      hostId: hostId,
      name: value['name'] as String,
      cwd: roots.firstOrNull ?? '',
      additionalRoots: List.unmodifiable(roots.skip(1)),
      updatedAt: [value['updatedAt'], value['recencyAt']]
          .whereType<num>()
          .map((time) => _parseTime(time))
          .fold<DateTime?>(
            null,
            (latest, time) =>
                latest == null || time.isAfter(latest) ? time : latest,
          ),
    );
  }

  Future<Set<String>> readAllTaskCwds() async {
    final activity = await readProjectActivity();
    return Set.unmodifiable(activity.keys);
  }

  Future<Map<String, DateTime>> readProjectActivity({
    bool includeArchived = false,
  }) async {
    final activity = <String, DateTime>{};
    for (final archived in [false, if (includeArchived) true]) {
      final seenCursors = <String>{};
      String? cursor;
      do {
        final page = await readTaskPage(
          cursor: cursor,
          archived: archived,
          sortKey: 'created_at',
        );
        for (final task in page.tasks) {
          final cwd = task.cwd.trim();
          if (cwd.isEmpty) continue;
          final current = activity[cwd];
          if (current == null || task.updatedAt.isAfter(current)) {
            activity[cwd] = task.updatedAt;
          }
        }
        final nextCursor = page.nextCursor;
        if (nextCursor != null && !seenCursors.add(nextCursor)) {
          throw StateError('Workspace scan repeated a cursor.');
        }
        cursor = nextCursor;
      } while (cursor != null);
    }
    return Map.unmodifiable(activity);
  }

  Future<Set<String>> readLoadedThreadIds() async {
    final loadedResult = _map(
      await _rpc.request('thread/loaded/list', const {}),
    );
    final rawLoaded = loadedResult['data'] ?? loadedResult['threadIds'];
    final loaded = rawLoaded is List
        ? rawLoaded
              .map((item) => item is Map ? item['id'] : item)
              .whereType<String>()
              .toSet()
        : <String>{};
    return loaded;
  }

  Future<TaskSnapshot> readThread(String threadId) async {
    final result = _map(
      await _rpc.request('thread/read', {
        'threadId': threadId,
        'includeTurns': true,
      }),
    );
    return parseThread(_map(result['thread']));
  }

  Future<RemoteSubagentDetails> readSubagentDetails(String threadId) async {
    final result = _map(
      await _rpc.request('thread/read', {
        'threadId': threadId,
        'includeTurns': false,
      }),
    );
    final thread = _map(result['thread']);
    final source = _map(_map(thread['source'])['subAgent']);
    final spawn = _map(source['thread_spawn']);
    return (
      nickname: _firstText(thread['agentNickname'], spawn['agent_nickname']),
      role: _firstText(thread['agentRole'], spawn['agent_role']),
    );
  }

  final Map<String, Map<String, TaskTurnInfo>> _turnInfo = {};
  final Map<String, String?> _turnCursors = {};

  Future<RemoteTurnPage> readThreadTurnsPage(
    String threadId, {
    String? cursor,
  }) async {
    final result = _map(
      await _rpc.requestWithTimeout('thread/items/list', {
        'threadId': threadId,
        'limit': 20,
        'sortDirection': 'desc',
        if (cursor != null) 'cursor': cursor,
      }, const Duration(minutes: 2)),
    );
    final entries = result['data'] as List<dynamic>? ?? const [];
    final items = <TaskItem>[];
    for (final entry in entries.reversed) {
      final item = _parseItem(_map(_map(entry)['item']));
      if (item != null) {
        items.add(item.copyWith(turnId: _map(entry)['turnId'] as String?));
      }
    }
    return RemoteTurnPage(
      items: List.unmodifiable(items),
      nextCursor: result['nextCursor'] as String?,
    );
  }

  Future<Map<String, TaskTurnInfo>> readTurnPresentation(
    String threadId,
    List<TaskItem> items, {
    String? cursor,
  }) async {
    final info = _turnInfo.putIfAbsent(threadId, () => {});
    String? turnCursor = cursor == null ? null : _turnCursors[threadId];
    final seenCursors = <String>{};
    if (cursor == null || items.any((item) => !info.containsKey(item.turnId))) {
      do {
        final metadata = _map(
          await _rpc.request('thread/turns/list', {
            'threadId': threadId,
            'limit': 20,
            'itemsView': 'notLoaded',
            'sortDirection': 'desc',
            if (turnCursor != null) 'cursor': turnCursor,
          }),
        );
        for (final raw in metadata['data'] as List? ?? const []) {
          final turn = _parseTurnInfo(_map(raw));
          if (turn != null) info[turn.id] = turn;
        }
        turnCursor = metadata['nextCursor'] as String?;
        if (turnCursor != null && !seenCursors.add(turnCursor)) {
          throw StateError('Turn metadata repeated a cursor.');
        }
        _turnCursors[threadId] = turnCursor;
      } while (turnCursor != null &&
          items.any((item) => !info.containsKey(item.turnId)));
    }
    return Map.unmodifiable(info);
  }

  Future<String?> readActiveTurnId(String threadId) async {
    final result = _map(
      await _rpc.request('thread/turns/list', {
        'threadId': threadId,
        'limit': 1,
        'sortDirection': 'desc',
        'itemsView': 'notLoaded',
      }),
    );
    final turns = result['data'] as List<dynamic>? ?? const [];
    for (final rawTurn in turns) {
      final turn = _map(rawTurn);
      if (_isActiveTurnStatus(turn['status'])) {
        return turn['id'] as String?;
      }
    }
    return null;
  }

  Future<({String id, String? serviceTier})> startThread({
    String? cwd,
    String? projectId,
  }) async {
    final result = _map(
      await _rpc.request('thread/start', {
        if (cwd != null && cwd.trim().isNotEmpty) 'cwd': cwd.trim(),
        if (projectId != null) 'projectId': projectId,
      }),
    );
    return (
      id: _map(result['thread'])['id'] as String,
      serviceTier: result['serviceTier'] as String?,
    );
  }

  Future<({String? model, String? effort, String? serviceTier})> resumeThread(
    String threadId,
  ) async {
    final result = _map(
      await _rpc.request('thread/resume', {
        'threadId': threadId,
        'excludeTurns': true,
      }),
    );
    return (
      model: result['model'] as String?,
      effort: result['reasoningEffort'] as String?,
      serviceTier: result['serviceTier'] as String?,
    );
  }

  Future<void> startTurn(
    String threadId,
    String text, {
    RemoteSkill? skill,
    String? model,
    String? effort,
    String? serviceTier,
    List<String> imagePaths = const [],
    PermissionMode permissionMode = PermissionMode.inherit,
    List<McpMention> mcpMentions = const [],
  }) async {
    await _rpc.request('turn/start', {
      'threadId': threadId,
      ...permissionMode.turnParams,
      'input': [
        {'type': 'text', 'text': text},
        for (final path in imagePaths) {'type': 'localImage', 'path': path},
        for (final mention in mcpMentions) mention.toInput(),
        if (skill != null)
          {'type': 'skill', 'name': skill.name, 'path': skill.path},
      ],
      if (model != null) 'model': model,
      if (effort != null) 'effort': effort,
      if (serviceTier != null) 'serviceTierForTurn': serviceTier,
    });
  }

  Future<List<RemoteModel>> readModelCatalog() async {
    final models = <RemoteModel>[];
    final seenIds = <String>{};
    String? cursor;
    do {
      final result = _map(
        await _rpc.request('model/list', {
          'limit': 100,
          'includeHidden': false,
          if (cursor != null) 'cursor': cursor,
        }),
      );
      for (final rawModel in result['data'] as List<dynamic>? ?? const []) {
        final model = _parseModel(_map(rawModel));
        if (model != null && seenIds.add(model.id)) models.add(model);
      }
      final nextCursor = result['nextCursor'] as String?;
      cursor = nextCursor == cursor ? null : nextCursor;
    } while (cursor != null);
    return List.unmodifiable(models);
  }

  Future<List<McpMention>> resolveMcpMentions(
    String threadId,
    String text, {
    String? skillName,
  }) async {
    final names = mcpMentionNames(text, skillName: skillName);
    if (names.isEmpty) return const [];
    try {
      final catalog = await listMcpServers(threadId);
      final available = <String, String?>{};
      final plugins = <String, Set<String>>{};
      for (final server in catalog) {
        final id = server.pluginId;
        if (id == null || !_pluginId.hasMatch(id)) {
          available[server.name] = null;
          continue;
        }
        available[server.name] = id;
        plugins.putIfAbsent(id.split('@').first, () => {}).add(id);
      }
      return [
        for (final name in names)
          if (available.containsKey(name))
            McpMention(name, pluginId: available[name])
          else if (plugins[name]?.length == 1)
            McpMention(name, pluginId: plugins[name]!.single),
      ];
    } on RpcRemoteException catch (error) {
      // Older app servers can still accept plain messages.
      if (error.code == -32601) return const [];
      rethrow;
    }
  }

  Future<List<RemoteMcpServer>> listMcpServers(
    String threadId, {
    bool refresh = false,
  }) async {
    final now = DateTime.now();
    final cached = _mcpCatalog.remove(threadId);
    if (!refresh && cached != null && cached.expires.isAfter(now)) {
      _mcpCatalog[threadId] = cached;
      return cached.load;
    }
    final load = _readMcpServers(threadId);
    _mcpCatalog[threadId] = (
      expires: now.add(const Duration(seconds: 30)),
      load: load,
    );
    if (_mcpCatalog.length > 16) _mcpCatalog.remove(_mcpCatalog.keys.first);
    try {
      return await load;
    } catch (_) {
      if (identical(_mcpCatalog[threadId]?.load, load)) {
        _mcpCatalog.remove(threadId);
      }
      rethrow;
    }
  }

  Future<List<RemoteMcpServer>> _readMcpServers(String threadId) async {
    final servers = <RemoteMcpServer>[];
    final seen = <String>{};
    final cursors = <String>{};
    String? cursor;
    do {
      final result = _map(
        await _rpc.request('mcpServerStatus/list', {
          'threadId': threadId,
          'limit': 50,
          'detail': 'toolsAndAuthOnly',
          if (cursor != null) 'cursor': cursor,
        }),
      );
      for (final raw in result['data'] as List? ?? const []) {
        final server = _map(raw);
        final name = server['name'] as String?;
        if (name == null || !seen.add(name)) continue;
        final tools =
            (server['tools'] as Map? ?? const {}).keys.cast<String>().toList()
              ..sort();
        servers.add(
          RemoteMcpServer(
            name: name,
            authStatus: server['authStatus'] as String? ?? 'unknown',
            tools: tools,
            pluginId: server['pluginId'] as String?,
            error: server['toolsError'] as String?,
          ),
        );
      }
      final next = result['nextCursor'] as String?;
      if (next == null) break;
      if (!cursors.add(next)) {
        throw StateError('MCP pagination did not advance');
      }
      cursor = next;
    } while (true);
    return servers;
  }

  Future<List<RemoteSkill>> listSkills(String cwd) async {
    final result = _map(
      await _rpc.request('skills/list', {
        'cwds': [cwd],
      }),
    );
    final skills = <RemoteSkill>[];
    for (final rawGroup in result['data'] as List<dynamic>? ?? const []) {
      final group = _map(rawGroup);
      for (final rawSkill in group['skills'] as List<dynamic>? ?? const []) {
        final skill = _map(rawSkill);
        final name = skill['name'] as String?;
        final path = skill['path'] as String?;
        if (name == null ||
            name.isEmpty ||
            path == null ||
            path.isEmpty ||
            skill['enabled'] == false) {
          continue;
        }
        skills.add(
          RemoteSkill(
            name: name,
            description: skill['description'] as String? ?? '',
            path: path,
          ),
        );
      }
    }
    skills.sort((first, second) => first.name.compareTo(second.name));
    return List.unmodifiable(skills);
  }

  Future<RemoteThreadGoal?> readThreadGoal(String threadId) async {
    final result = _map(
      await _rpc.request('thread/goal/get', {'threadId': threadId}),
    );
    return _parseGoal(result['goal']);
  }

  Future<RemoteThreadGoal> setThreadGoal(
    String threadId, {
    String? objective,
    int? tokenBudget,
    String? status = 'active',
  }) async {
    final result = _map(
      await _rpc.request('thread/goal/set', {
        'threadId': threadId,
        'origin': 'user',
        if (objective != null) 'objective': objective,
        if (status != null) 'status': status,
        if (tokenBudget != null) 'tokenBudget': tokenBudget,
      }),
    );
    return _parseGoal(result['goal'])!;
  }

  Future<void> clearThreadGoal(String threadId) async {
    await _rpc.request('thread/goal/clear', {
      'threadId': threadId,
      'origin': 'user',
    });
  }

  static RemoteThreadGoal? parseGoal(Object? value) => _parseGoal(value);

  Future<void> renameThread(String id, String name) async {
    await _rpc.request('thread/name/set', {'threadId': id, 'name': name});
  }

  Future<void> pinThread(String id, bool pinned) async {
    final result = _map(
      await _rpc.request('thread/metadata/update', {
        'threadId': id,
        'isPinned': pinned,
      }),
    );
    if (_map(result['thread'])['isPinned'] != pinned) {
      throw UnsupportedError(
        'This server did not confirm pinning. Update remote Codex.',
      );
    }
  }

  Future<void> archiveThread(String id, {required bool archived}) async {
    await _rpc.request(archived ? 'thread/archive' : 'thread/unarchive', {
      'threadId': id,
    });
  }

  Future<TaskSnapshot> forkThread(String id, {String? lastTurnId}) async {
    final result = _map(
      await _rpc.request('thread/fork', {
        'threadId': id,
        'excludeTurns': true,
        if (lastTurnId != null) 'lastTurnId': lastTurnId,
      }),
    );
    return parseThread(_map(result['thread']));
  }

  Future<void> revertThread(String id, String turnId) async {
    await _rpc.request('thread/revert', {
      'threadId': id,
      'beforeTurnId': turnId,
    });
  }

  Future<void> compactThread(String threadId) async {
    await _rpc.request('thread/compact/start', {'threadId': threadId});
  }

  Future<void> interruptTurn(String threadId, String turnId) async {
    await _rpc.request('turn/interrupt', {
      'threadId': threadId,
      'turnId': turnId,
    });
  }

  Future<void> steerTurn(
    String threadId,
    String expectedTurnId,
    String text, {
    List<String> imagePaths = const [],
    List<McpMention> mcpMentions = const [],
  }) async {
    await _rpc.request('turn/steer', {
      'threadId': threadId,
      'expectedTurnId': expectedTurnId,
      'input': [
        {'type': 'text', 'text': text},
        for (final path in imagePaths) {'type': 'localImage', 'path': path},
        for (final mention in mcpMentions) mention.toInput(),
      ],
    });
  }

  void answerApproval(PendingApproval approval, String decision) {
    if (!approval.availableDecisions.contains(decision)) {
      throw ArgumentError.value(decision, 'decision', 'Unsupported decision');
    }
    if (!approval.isPermissionRequest) {
      _rpc.respond(approval.requestId, {'decision': decision});
      return;
    }

    // 权限审批返回实际授予的权限，而不是命令审批的 decision。
    // 同意时仅回传本次申请的范围；拒绝时返回空集合，避免意外扩大权限。
    final grantedPermissions = switch (decision) {
      'accept' || 'acceptForSession' => approval.requestedPermissions!,
      'decline' => <String, dynamic>{},
      _ => throw ArgumentError.value(decision, 'decision'),
    };
    _rpc.respond(approval.requestId, {
      'permissions': grantedPermissions,
      'scope': decision == 'acceptForSession' ? 'session' : 'turn',
    });
  }

  static TaskSnapshot parseThread(Map<String, dynamic> thread) {
    final id = thread['id'] as String? ?? 'unknown';
    final items = <TaskItem>[];
    final turns = thread['turns'] as List<dynamic>? ?? const [];
    for (final rawTurn in turns) {
      final turn = _map(rawTurn);
      for (final rawItem in turn['items'] as List<dynamic>? ?? const []) {
        final item = _parseItem(_map(rawItem));
        if (item != null) {
          items.add(
            item.copyWith(
              turnId: turn['id'] as String?,
              turn: _parseTurnInfo(turn),
            ),
          );
        }
      }
    }
    final title =
        _firstText(
          thread['name'],
          thread['title'],
          thread['preview'],
          items
              .where((item) => item.kind == TaskItemKind.user)
              .firstOrNull
              ?.text,
        ) ??
        'Task ${id.length > 8 ? id.substring(0, 8) : id}';
    return TaskSnapshot(
      id: id,
      title: title,
      status: _parseStatus(thread['status']),
      cwd: thread['cwd'] as String? ?? '',
      projectId: thread['projectId'] as String?,
      isPinned: thread['isPinned'] == true,
      updatedAt: _parseTime(
        thread['updatedAt'] ?? thread['createdAt'] ?? thread['updated_at'],
      ),
      items: List.unmodifiable(items),
      model: thread['model'] as String?,
      reasoningEffort: thread['reasoningEffort'] as String?,
    );
  }

  static TaskEvent? parseNotification(
    String method,
    Map<String, dynamic> params,
  ) {
    final threadId =
        params['threadId'] as String? ??
        _map(params['thread'])['id'] as String?;
    if (threadId == null) return null;
    switch (method) {
      case 'turn/started':
      case 'thread/started':
        return TaskEvent.statusChanged(threadId, TaskStatus.running);
      case 'turn/completed':
        final status = _parseStatus(_map(params['turn'])['status']);
        return TaskEvent.statusChanged(
          threadId,
          status,
          turn: _parseTurnInfo(_map(params['turn'])),
        );
      case 'item/agentMessage/delta':
        final itemId = params['itemId'] as String? ?? 'agent-message';
        final sequence = params['sequence'] ?? params['deltaIndex'];
        final delta = params['delta'] as String? ?? '';
        if (delta.isEmpty) return null;
        return TaskEvent.agentDelta(
          threadId,
          itemId,
          sequence == null ? null : '$threadId:$itemId:$sequence',
          delta,
          turnId: params['turnId'] as String?,
        );
      case 'item/started':
      case 'item/completed':
        final item = _map(params['item']);
        final parsed = _parseItem(item);
        return parsed == null
            ? null
            : TaskEvent.itemChanged(
                threadId,
                parsed.copyWith(turnId: params['turnId'] as String?),
              );
      default:
        return null;
    }
  }

  static PendingApproval parseApproval(RpcServerRequest request) {
    final params = request.params;
    final isPermissionRequest =
        request.method == 'item/permissions/requestApproval';
    final permissions = params['permissions'];
    if (isPermissionRequest && permissions is! Map<String, dynamic>) {
      throw const FormatException('Missing or invalid requested permissions');
    }
    final requestedPermissions = isPermissionRequest
        ? Map<String, dynamic>.unmodifiable(permissions as Map<String, dynamic>)
        : null;
    final command = params['command'];
    final detail = isPermissionRequest
        ? _permissionApprovalDetail(params, requestedPermissions!)
        : command is List
        ? command.join(' ')
        : _firstText(command, params['reason'], params['cwd']) ??
              request.method;
    final decisions = isPermissionRequest
        ? const ['accept', 'acceptForSession', 'decline']
        : (params['availableDecisions'] as List<dynamic>?)
                  ?.whereType<String>()
                  .toList(growable: false) ??
              const ['accept', 'decline'];
    return PendingApproval(
      requestId: request.id,
      method: request.method,
      threadId: params['threadId'] as String? ?? '',
      title: isPermissionRequest
          ? 'Approve additional permissions'
          : request.method.contains('fileChange')
          ? 'Approve file changes'
          : 'Approve command',
      detail: detail,
      availableDecisions: decisions,
      requestedPermissions: requestedPermissions,
    );
  }
}

String _permissionApprovalDetail(
  Map<String, dynamic> params,
  Map<String, dynamic> permissions,
) {
  final lines = <String>[
    if (_firstText(params['reason']) case final reason?) reason,
    if (_firstText(params['cwd']) case final cwd?) 'Working directory: $cwd',
    if (_map(permissions['network'])['enabled'] == true) 'Network access',
  ];
  final fileSystem = _map(permissions['fileSystem']);
  // 展示协议中实际申请的路径与访问方式，避免只显示理由而隐藏授权范围。
  for (final raw in fileSystem['entries'] as List<dynamic>? ?? const []) {
    final entry = _map(raw);
    final path = _map(entry['path']);
    final special = _map(path['value']);
    final basePath = switch (special['kind']) {
      'root' => '/',
      'minimal' => 'System runtime files',
      'project_roots' => 'Project roots',
      'tmpdir' => 'Temporary directory',
      'slash_tmp' => '/tmp',
      _ => _firstText(special['path'], special['kind']) ?? 'Unknown path',
    };
    final label =
        _firstText(path['path'], path['pattern']) ??
        [
          basePath,
          if (_firstText(special['subpath']) case final subpath?) subpath,
        ].join('/');
    final access = switch (entry['access']) {
      'read' => 'Read',
      'write' => 'Write',
      'deny' => 'Deny',
      _ => entry['access']?.toString() ?? 'Access',
    };
    lines.add('$access: $label');
  }
  for (final access in ['read', 'write']) {
    for (final path in fileSystem[access] as List<dynamic>? ?? const []) {
      lines.add('${access == 'read' ? 'Read' : 'Write'}: $path');
    }
  }
  return lines.isEmpty
      ? 'No additional permissions requested'
      : lines.join('\n');
}

bool _isActiveTurnStatus(Object? raw) {
  final status = raw is Map ? raw['type'] ?? raw['status'] : raw;
  return switch (status?.toString().toLowerCase()) {
    'active' || 'running' || 'inprogress' || 'in_progress' => true,
    _ => false,
  };
}

RemoteThreadGoal? _parseGoal(Object? raw) {
  final goal = _map(raw);
  if (goal.isEmpty) return null;
  final objective = goal['objective'] as String?;
  if (objective == null || objective.isEmpty) return null;
  return RemoteThreadGoal(
    objective: objective,
    status: goal['status'] as String? ?? 'active',
    tokenBudget: (goal['tokenBudget'] as num?)?.toInt(),
    tokensUsed: (goal['tokensUsed'] as num?)?.toInt() ?? 0,
    timeUsedSeconds: (goal['timeUsedSeconds'] as num?)?.toInt() ?? 0,
  );
}

TaskTurnInfo? _parseTurnInfo(Map<String, dynamic> value) {
  final id = value['id'];
  if (id is! String) return null;
  return TaskTurnInfo(
    id: id,
    status: value['status'] as String? ?? 'unknown',
    durationMs: (value['durationMs'] as num?)?.toInt(),
  );
}

TaskItem? _parseItem(Map<String, dynamic> item) {
  final type = item['type'] as String? ?? 'unknown';
  final id = item['id'] as String? ?? '$type-${item.hashCode}';
  final text = _extractText(item);
  final kind = switch (type) {
    'userMessage' => TaskItemKind.user,
    'agentMessage' => TaskItemKind.agent,
    'commandExecution' => TaskItemKind.command,
    'fileChange' => TaskItemKind.file,
    'mcpToolCall' ||
    'dynamicToolCall' ||
    'collabAgentToolCall' ||
    'subAgentActivity' => TaskItemKind.tool,
    'reasoning' => TaskItemKind.reasoning,
    _ => TaskItemKind.notice,
  };
  final attachments = outputImageAttachments(item);
  final questions = <TaskQuestion>[];
  if (kind == TaskItemKind.agent && item['questions'] is List) {
    for (final raw in item['questions'] as List) {
      final question = _map(raw);
      final title = question['title'] as String?;
      if (title == null || title.trim().isEmpty) continue;
      questions.add(
        TaskQuestion(
          title: title,
          options: List.unmodifiable(
            (question['options'] as List<dynamic>? ?? const [])
                .whereType<String>()
                .where((option) => option.trim().isNotEmpty),
          ),
        ),
      );
    }
  }
  // agentMessage 的 started 通知可能尚无正文，但携带后续流式消息的时间。
  if (kind == TaskItemKind.user &&
      text.trim().isEmpty &&
      attachments.isEmpty &&
      questions.isEmpty) {
    return null;
  }
  final presentation = _itemPresentation(type, item, text);
  return TaskItem(
    id: id,
    kind: kind,
    title: presentation.title,
    text: kind == TaskItemKind.user ? text : presentation.text,
    attachments: attachments,
    questions: List.unmodifiable(questions),
    subagents: _parseSubagents(type, item),
    detail: presentation.detail,
    status: item['status']?.toString(),
    phase: item['phase'] as String?,
    startedAt: _parseItemTime(item['startedAtMs']),
    completedAt: _parseItemTime(item['completedAtMs']),
    changes: List.unmodifiable([
      for (final raw in item['changes'] as List? ?? const [])
        TaskFileChange(
          path: _map(raw)['path'] as String? ?? '',
          kind: _map(_map(raw)['kind'])['type'] as String? ?? 'update',
          diff: _map(raw)['diff'] as String? ?? '',
        ),
    ]),
  );
}

List<SubagentReference> _parseSubagents(
  String type,
  Map<String, dynamic> item,
) {
  if (type == 'subAgentActivity') {
    final id = _firstText(item['agentThreadId']);
    if (id == null) return const [];
    return [
      SubagentReference(
        id,
        path: _firstText(item['agentPath']),
        status: switch (item['kind']) {
          'started' => 'running',
          'completed' => 'completed',
          'interrupted' => 'interrupted',
          _ => null,
        },
      ),
    ];
  }
  if (type != 'collabAgentToolCall') return const [];
  final states = _map(item['agentsStates']);
  final receivers = item['receiverThreadIds'];
  return List.unmodifiable([
    for (final id in {
      if (receivers is List) ...receivers.whereType<String>(),
      ...states.keys,
    })
      if (id.isNotEmpty && id != item['senderThreadId'])
        SubagentReference(id, status: _firstText(_map(states[id])['status'])),
  ]);
}

_ItemPresentation _itemPresentation(
  String type,
  Map<String, dynamic> item,
  String extractedText,
) {
  switch (type) {
    case 'agentMessage':
      return _ItemPresentation(text: extractedText);
    case 'reasoning':
      final summary = _readTextBlocks(item['summary']);
      final content = _readTextBlocks(item['content']);
      return _ItemPresentation(
        title: 'Reasoning',
        text: summary.isNotEmpty
            ? summary
            : content.isNotEmpty
            ? content
            : 'Reasoning',
        detail: summary.isNotEmpty && content.isNotEmpty && content != summary
            ? content
            : null,
      );
    case 'commandExecution':
      final command = _firstText(item['command']) ?? 'Command';
      final output = _firstText(item['aggregatedOutput'], item['output']);
      final cwd = item['cwd'] as String?;
      return _ItemPresentation(
        title: command,
        text: cwd == null || cwd.isEmpty ? command : cwd,
        detail: output,
      );
    case 'fileChange':
      final changes = item['changes'] as List<dynamic>? ?? const [];
      final lines = <String>[];
      final diffs = <String>[];
      for (final raw in changes) {
        final change = _map(raw);
        final path = change['path'] as String? ?? 'unknown file';
        final changeKind = change['kind']?.toString() ?? 'change';
        lines.add('$changeKind  $path');
        final diff = change['diff'] as String?;
        if (diff != null && diff.isNotEmpty) diffs.add('$path\n$diff');
      }
      return _ItemPresentation(
        title: changes.length == 1
            ? '1 file changed'
            : '${changes.length} files changed',
        text: lines.isEmpty ? 'File changes' : lines.join('\n'),
        detail: diffs.isEmpty ? null : diffs.join('\n\n'),
      );
    case 'mcpToolCall':
      final server = item['server']?.toString();
      final tool = item['tool']?.toString() ?? 'Tool';
      return _ItemPresentation(
        title: server == null || server.isEmpty ? tool : '$server · $tool',
        text: tool,
        detail: _jsonDetail(item, const ['arguments', 'result', 'error']),
      );
    case 'dynamicToolCall':
      final tool = item['tool']?.toString() ?? 'Tool';
      return _ItemPresentation(
        title: tool,
        text: tool,
        detail: _jsonDetail(item, const [
          'arguments',
          'contentItems',
          'success',
        ]),
      );
    case 'collabAgentToolCall':
      final action = switch (item['tool']) {
        'spawnAgent' => 'Spawned subagent',
        'sendInput' || 'sendMessage' || 'followupTask' => 'Messaged subagent',
        'resumeAgent' => 'Resumed subagent',
        'wait' => 'Waited for subagents',
        'closeAgent' => 'Closed subagent',
        'interruptAgent' => 'Interrupted subagent',
        'listAgents' => 'Listed subagents',
        _ => 'Subagent tool',
      };
      return _ItemPresentation(
        title: action,
        text: '',
        detail: _firstText(item['prompt']),
      );
    case 'subAgentActivity':
      final action = switch (item['kind']) {
        'started' => 'Subagent started',
        'completed' => 'Subagent completed',
        'interrupted' => 'Subagent interrupted',
        'interacted' => 'Subagent interaction',
        _ => 'Subagent activity',
      };
      return _ItemPresentation(title: action, text: '');
    default:
      return _ItemPresentation(
        text: extractedText.isEmpty ? type : extractedText,
      );
  }
}

String _readTextBlocks(Object? raw) {
  if (raw is String) return raw.trim();
  if (raw is List) {
    return raw
        .map((part) => part is String ? part : _map(part)['text'])
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .join('\n')
        .trim();
  }
  return '';
}

String? _jsonDetail(Map<String, dynamic> item, List<String> keys) {
  final detail = <String, dynamic>{};
  for (final key in keys) {
    if (item[key] != null) detail[key] = _imageSafeDetail(item[key]);
  }
  if (detail.isEmpty) return null;
  return const JsonEncoder.withIndent('  ').convert(detail);
}

Object? _imageSafeDetail(Object? value) {
  if (value is List) return value.map(_imageSafeDetail).toList();
  if (value is Map) {
    if (const ['image', 'inputImage', 'image_url'].contains(value['type'])) {
      return {
        'type': value['type'],
        'mimeType': value['mimeType'],
        'preview': 'Image displayed separately',
      };
    }
    return value.map(
      (key, entry) => MapEntry(key.toString(), _imageSafeDetail(entry)),
    );
  }
  return value;
}

final class _ItemPresentation {
  const _ItemPresentation({required this.text, this.title, this.detail});

  final String? title;
  final String text;
  final String? detail;
}

String _extractText(Map<String, dynamic> item) {
  final direct = _firstText(
    item['text'],
    item['summary'],
    item['command'],
    item['output'],
    item['name'],
  );
  if (direct != null) return direct;
  final content = item['content'];
  if (content is List) {
    return content
        .map((part) => _map(part)['text'])
        .whereType<String>()
        .join('\n');
  }
  return '';
}

TaskStatus _parseStatus(Object? raw) {
  final value = raw is Map ? raw['type'] ?? raw['status'] : raw;
  return switch (value?.toString().toLowerCase()) {
    'active' ||
    'running' ||
    'inprogress' ||
    'in_progress' => TaskStatus.running,
    'queued' || 'pending' => TaskStatus.queued,
    'completed' ||
    'complete' ||
    'idle' ||
    'notloaded' ||
    'not_loaded' => TaskStatus.completed,
    'failed' || 'error' || 'systemerror' => TaskStatus.failed,
    'interrupted' || 'cancelled' || 'canceled' => TaskStatus.interrupted,
    _ => TaskStatus.unknown,
  };
}

/// ThreadItem 明确使用 Unix 毫秒，不能沿用线程级秒时间戳的推断规则。
DateTime? _parseItemTime(Object? raw) {
  if (raw is! num || !raw.isFinite || raw.abs() > 8640000000000000) return null;
  return DateTime.fromMillisecondsSinceEpoch(raw.toInt(), isUtc: true);
}

DateTime _parseTime(Object? raw) {
  if (raw is num) {
    final milliseconds = raw > 1000000000000 ? raw.toInt() : raw.toInt() * 1000;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  if (raw is String) {
    return DateTime.tryParse(raw)?.toUtc() ?? DateTime.now().toUtc();
  }
  return DateTime.now().toUtc();
}

String? _firstText(
  Object? first, [
  Object? second,
  Object? third,
  Object? fourth,
  Object? fifth,
]) {
  for (final value in [first, second, third, fourth, fifth]) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
    if (value is List && value.isNotEmpty) return value.join(' ');
  }
  return null;
}

RemoteModel? _parseModel(Map<String, dynamic> raw) {
  final id = raw['id'] as String?;
  final model = raw['model'] as String?;
  final displayName = raw['displayName'] as String?;
  final defaultEffort = raw['defaultReasoningEffort'] as String?;
  if (raw['hidden'] == true ||
      id == null ||
      id.isEmpty ||
      model == null ||
      model.isEmpty ||
      displayName == null ||
      displayName.isEmpty ||
      defaultEffort == null ||
      defaultEffort.isEmpty) {
    return null;
  }
  final efforts = <RemoteReasoningEffort>[];
  for (final rawOption
      in raw['supportedReasoningEfforts'] as List<dynamic>? ?? const []) {
    final option = _map(rawOption);
    final effort = option['reasoningEffort'] as String?;
    if (effort == null || effort.isEmpty) continue;
    efforts.add(
      RemoteReasoningEffort(
        effort: effort,
        description: option['description'] as String? ?? '',
      ),
    );
  }
  return RemoteModel(
    id: id,
    model: model,
    displayName: displayName,
    description: raw['description'] as String? ?? '',
    isDefault: raw['isDefault'] == true,
    defaultReasoningEffort: defaultEffort,
    supportedReasoningEfforts: List.unmodifiable(efforts),
    defaultServiceTier: raw['defaultServiceTier'] as String?,
    serviceTiers: List.unmodifiable([
      for (final tier in raw['serviceTiers'] as List<dynamic>? ?? const [])
        if (_map(tier)['id'] case final String id) id,
      for (final tier
          in raw['additionalSpeedTiers'] as List<dynamic>? ?? const [])
        if (tier is String) tier,
    ]),
  );
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return const {};
}

final _pluginId = RegExp(r'^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$');

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
