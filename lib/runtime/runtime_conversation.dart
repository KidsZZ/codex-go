part of 'codex_runtime.dart';

/// 会话命令、目标与权限操作职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeConversation on CodexRuntime {
  Future<void> startNewTask({
    String? cwd,
    required String prompt,
    String? projectId,
    String? model,
    String? effort,
    String? serviceTier,
    PermissionMode permissionMode = PermissionMode.inherit,
    List<RemoteAttachment> attachments = const [],
    RemoteSkill? skill,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final host = _selectedHostId!;
    final previousSelection = _selectedTaskId;
    final navigation = _selectionRevision;
    final project = _projects.where((p) => p.id == projectId).firstOrNull;
    if (projectId != null && project == null) throw StateError('工作区已移除，请重新选择。');
    final created = await api.startThread(
      cwd: cwd,
      projectId: project?.remoteId,
    );
    _ensureCurrentSession(api, attempt, epoch, host);
    final draft = draftForTask(created.id);
    draft.permissionMode = permissionMode;
    draft.settings = TurnSettings(
      model: model,
      effort: effort,
      serviceTier: serviceTier,
    );
    _subscribedThreadIds = {..._subscribedThreadIds, created.id};
    _taskReducer.applySnapshot(
      epoch,
      TaskSnapshot(
        id: created.id,
        title: prompt.trim().isEmpty ? '新对话' : prompt.trim().split('\n').first,
        status: TaskStatus.unknown,
        cwd: cwd ?? '',
        updatedAt: DateTime.now().toUtc(),
        items: const [],
        projectId: project?.remoteId,
        model: model,
        reasoningEffort: effort,
      ),
      _interactiveThreadIds,
    );
    _taskReducer.setServiceTier(epoch, created.id, created.serviceTier);
    // 创建期间用户切到别的会话时，发送仍属于刚创建的 thread，不能抢走页面。
    if (_selectedTaskId == previousSelection &&
        navigation == _selectionRevision) {
      _selectedTaskId = created.id;
    }
    _notify();
    await sendPrompt(
      prompt,
      taskId: created.id,
      skill: skill,
      attachments: attachments,
      model: model,
      effort: effort,
      serviceTier: serviceTier,
      permissionMode: permissionMode,
    );
    if (_isCurrentSession(api, attempt, epoch, host)) await refreshTasks();
  }

  Future<List<RemoteMcpServer>> listMcpForSelectedTask() async {
    final id = _selectedTaskId;
    if (id == null) throw StateError('Select a task first.');
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    await _ensureThreadSubscribed(
      id,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
    );
    final result = await api.listMcpServers(id, refresh: true);
    _ensureCurrentSession(api, attempt, epoch, profileId);
    return result;
  }

  Future<List<RemoteSkill>> listSkillsForSelectedTask() async {
    final cwd = selectedTask?.cwd.isNotEmpty == true
        ? selectedTask!.cwd
        : selectedProject?.cwd;
    if (cwd == null || cwd.isEmpty) {
      throw StateError('The selected task has no working directory.');
    }
    return _requireApi().listSkills(cwd);
  }

  Future<void> _refreshGoal(String taskId) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    final revision = _goalRevisions[taskId] ?? 0;
    try {
      final goal = await api.readThreadGoal(taskId);
      if (api != _api ||
          epoch != _epoch ||
          revision != (_goalRevisions[taskId] ?? 0)) {
        return;
      }
      _goals[taskId] = goal;
      _notify();
    } catch (_) {
      // Older servers can omit goals; opening a conversation must still work.
    }
  }

  Future<RemoteThreadGoal?> readSelectedGoal() async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    await _refreshGoal(task.id);
    return _goals[task.id];
  }

  Future<RemoteThreadGoal> setSelectedGoal({
    required String objective,
    int? tokenBudget,
  }) async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    final normalizedObjective = objective.trim();
    if (normalizedObjective.isEmpty) {
      throw ArgumentError('Goal objective is required.');
    }
    if (tokenBudget != null && tokenBudget <= 0) {
      throw ArgumentError('Token budget must be positive.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    final result = await api.setThreadGoal(
      task.id,
      objective: normalizedObjective,
      tokenBudget: tokenBudget,
      status: _goals[task.id]?.objective == normalizedObjective
          ? _goals[task.id]!.status
          : 'active',
    );
    if (api == _api && epoch == _epoch) {
      _goals[task.id] = result;
      _notify();
    }
    return result;
  }

  Future<void> clearSelectedGoal() async {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    final api = _requireApi();
    final epoch = _epoch;
    await api.clearThreadGoal(task.id);
    if (api == _api && epoch == _epoch) {
      _goals.remove(task.id);
      _notify();
    }
  }

  Future<void> setGoalPaused(bool paused) async {
    final id = _selectedTaskId;
    if (id == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final goal = await api.setThreadGoal(
      id,
      status: paused ? 'paused' : 'active',
    );
    if (api != _api || epoch != _epoch) return;
    _goals[id] = goal;
    _notify();
  }

  Future<RemoteTaskPage> findTasks({
    String? query,
    String? cursor,
    bool archived = false,
    bool? pinned,
    String? projectId,
    String? cwd,
  }) async {
    final api = _requireApi();
    final epoch = _epoch;
    final result = await api.readTaskPage(
      searchTerm: query,
      cursor: cursor,
      archived: archived,
      isPinned: pinned,
      projectId: projectId,
      cwd: cwd,
    );
    if (api != _api || epoch != _epoch) throw StateError('Connection changed');
    return result;
  }

  void cacheFoundTask(TaskSnapshot task) =>
      _taskReducer.applySnapshot(_epoch, task, _interactiveThreadIds);

  Future<void> openFoundTask(TaskSnapshot task) async {
    cacheFoundTask(task);
    await selectTask(task.id);
  }

  Future<void> renameTask(String id, String name) async {
    if (name.trim().isEmpty) throw ArgumentError('Name is required');
    final api = _requireApi();
    final epoch = _epoch;
    await api.renameThread(id, name.trim());
    if (api != _api || epoch != _epoch) return;
    _taskReducer.updateMetadata(epoch, id, title: name.trim());
    _notify();
    await refreshTasks(resetPages: true);
  }

  Future<void> pinTask(String id, bool pinned) async {
    final api = _requireApi();
    final epoch = _epoch;
    await api.pinThread(id, pinned);
    if (api != _api || epoch != _epoch) return;
    _taskReducer.updateMetadata(epoch, id, isPinned: pinned);
    _notify();
    await refreshTasks(resetPages: true);
  }

  Future<void> archiveTask(String id, bool archived) async {
    if (archived && _messageQueue.hasPending(id)) {
      throw StateError('Resolve queued messages before archiving this task.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    await api.archiveThread(id, archived: archived);
    if (api != _api || epoch != _epoch) return;
    if (archived && _selectedTaskId == id) clearSelectedTask();
    // Rebuild catalog pages so a removed task cannot survive a head merge.
    await refreshTasks(resetPages: true);
  }

  Future<void> forkSelectedTask({String? turnId}) async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final fork = await api.forkThread(task.id, lastTurnId: turnId);
    if (api != _api || epoch != _epoch) return;
    _taskReducer.applySnapshot(epoch, fork, _interactiveThreadIds);
    await selectTask(fork.id);
    await refreshTasks();
  }

  Future<void> retryTurnInFork(TaskItem item, {String? editedPrompt}) async {
    final source = selectedTask;
    final turnId = item.turnId;
    if (source == null || turnId == null) return;
    if (source.status == TaskStatus.running) {
      throw StateError('请先停止当前回合，再重新回答。');
    }
    final user = source.items
        .where((i) => i.turnId == turnId && i.kind == TaskItemKind.user)
        .firstOrNull;
    if (user == null) throw StateError('请先加载这一回合的原始提问。');
    final api = _requireApi();
    final epoch = _epoch;
    final attempt = _connectionAttempt;
    final host = _selectedHostId!;
    final settings = draftForTask(source.id);
    final fork = await api.forkThread(source.id, lastTurnId: turnId);
    _ensureCurrentSession(api, attempt, epoch, host);
    await api.resumeThread(fork.id);
    _ensureCurrentSession(api, attempt, epoch, host);
    // 只在新分支回退目标回合，源会话始终保留；文件不会被回退。
    await api.revertThread(fork.id, turnId);
    _ensureCurrentSession(api, attempt, epoch, host);
    _taskReducer.applySnapshot(epoch, fork, _interactiveThreadIds);
    _taskReducer.replaceItems(epoch, fork.id, const []);
    _subscribedThreadIds = {..._subscribedThreadIds, fork.id};
    final draft = draftForTask(fork.id);
    draft.permissionMode = settings.permissionMode;
    draft.settings = settings.settings;
    if (_selectedTaskId == source.id) await selectTask(fork.id);
    _ensureCurrentSession(api, attempt, epoch, host);
    await sendPrompt(
      editedPrompt ?? user.text,
      taskId: fork.id,
      model: settings.settings.model ?? source.model,
      effort: settings.settings.effort ?? source.reasoningEffort,
      serviceTier: settings.settings.serviceTier ?? source.serviceTier,
      permissionMode: settings.permissionMode,
      attachments: [
        for (final file in user.attachments)
          RemoteAttachment(
            path: file.path,
            isImage: file.isImage,
            mimeType: file.mimeType,
          ),
      ],
    );
    await refreshTasks();
  }

  Future<void> revertSelectedTask(String turnId) async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final epoch = _epoch;
    final attempt = _connectionAttempt;
    final host = _selectedHostId!;
    if (_messageQueue.hasPending(task.id)) {
      throw StateError('Resolve queued messages before reverting history.');
    }
    await _ensureThreadSubscribed(
      task.id,
      api: api,
      epoch: epoch,
      attempt: attempt,
      profileId: host,
    );
    if (await api.readActiveTurnId(task.id) != null) {
      throw StateError('Stop the active turn before reverting history.');
    }
    _ensureCurrentSession(api, attempt, epoch, host);
    await api.revertThread(task.id, turnId);
    _ensureCurrentSession(api, attempt, epoch, host);
    _agentDeltaBatcher.clear();
    _taskReducer.replaceItems(epoch, task.id, const []);
    await _loadInitialTaskContext(task.id);
  }

  Future<void> compactSelectedTask() {
    final task = selectedTask;
    if (task == null) throw StateError('Select a task first.');
    return _requireApi().compactThread(task.id);
  }

  Future<void> interruptTaskAndWait(String taskId) async {
    final api = _requireApi();
    final epoch = _epoch;
    final turnId = await api.readActiveTurnId(taskId);
    if (api != _api || epoch != _epoch) throw StateError('连接已切换，请重试。');
    if (turnId == null) return;
    await api.interruptTurn(taskId, turnId);
    for (var attempt = 0; attempt < 30; attempt++) {
      if (api != _api || epoch != _epoch) throw StateError('连接已切换，请重试。');
      if (await api.readActiveTurnId(taskId) == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError('Codex 仍在停止，请稍后重发；草稿已保留。');
  }

  Future<void> interruptSelectedTask() async {
    final task = selectedTask;
    if (task == null) return;
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    // Resolve the actual active turn even if it was started by another client.
    final turnId = await api.readActiveTurnId(task.id);
    _ensureCurrentSession(api, attempt, epoch, profileId);
    if (turnId == null) {
      _activeTurnIds.remove(task.id);
      await refreshTasks();
      return;
    }
    try {
      await api.interruptTurn(task.id, turnId);
    } finally {
      if (_isCurrentSession(api, attempt, epoch, profileId)) {
        unawaited(refreshTasks());
      }
    }
  }

  void answerApproval(PendingApproval approval, String decision) {
    if (!isConnected ||
        !_approvals.any((pending) => identical(pending, approval))) {
      return;
    }
    _api!.answerApproval(approval, decision);
    _approvals = _approvals
        .where((item) => item.requestId != approval.requestId)
        .toList(growable: false);
    _notify();
  }
}
