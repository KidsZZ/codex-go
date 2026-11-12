part of 'codex_runtime.dart';

/// 协议通知与会话事件归并职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeEvents on CodexRuntime {
  Future<void> _ensureThreadSubscribed(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    _ensureCurrentSession(api, attempt, epoch, profileId);
    if (_subscribedThreadIds.contains(threadId)) return;
    final pending = _pendingThreadSubscriptions[threadId];
    if (pending != null) return pending;
    final operation = () async {
      final tierRevision = _serviceTierRevisions[threadId];
      final settings = await api.resumeThread(threadId);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      _taskReducer.setTurnSettings(
        epoch,
        threadId,
        settings.model,
        settings.effort,
      );
      if (_serviceTierRevisions[threadId] == tierRevision) {
        _taskReducer.setServiceTier(epoch, threadId, settings.serviceTier);
      }
      _subscribedThreadIds = {..._subscribedThreadIds, threadId};
    }();
    _pendingThreadSubscriptions[threadId] = operation;
    try {
      await operation;
    } finally {
      if (identical(_pendingThreadSubscriptions[threadId], operation)) {
        unawaited(_pendingThreadSubscriptions.remove(threadId));
      }
    }
  }

  bool _isCurrentSession(
    CodexRemoteApi api,
    int attempt,
    int epoch,
    String profileId,
  ) =>
      identical(api, _api) &&
      attempt == _connectionAttempt &&
      epoch == _epoch &&
      profileId == _selectedHostId;

  void _ensureCurrentSession(
    CodexRemoteApi api,
    int attempt,
    int epoch,
    String profileId,
  ) {
    if (!_isCurrentSession(api, attempt, epoch, profileId)) {
      throw StateError('The remote connection changed while sending.');
    }
  }

  void _handleNotification(int attempt, RpcNotification notification) {
    if (attempt != _connectionAttempt) return;
    final method = notification.method;
    final params = notification.params;
    if (method == 'thread/settings/updated') {
      final id = params['threadId'];
      final settings = params['threadSettings'];
      if (id is String &&
          settings is Map &&
          settings.containsKey('serviceTier')) {
        final tier = settings['serviceTier'];
        if (tier == null || tier is String) {
          _serviceTierRevisions[id] = (_serviceTierRevisions[id] ?? 0) + 1;
          _taskReducer.setServiceTier(_epoch, id, tier as String?);
          _notify();
        }
      }
      return;
    }
    if (method == 'account/rateLimits/updated') {
      accountUsage.update(params);
      return;
    }
    if (method == 'account/updated') {
      accountUsage.bind(_api);
      unawaited(accountUsage.refresh());
      return;
    }
    if (method == 'thread/name/updated') {
      final id = params['threadId'] as String?;
      final name = params['threadName'] as String?;
      if (id != null && name != null) {
        _taskReducer.updateMetadata(_epoch, id, title: name);
        _notify();
      }
    }
    if (method == 'thread/goal/updated' || method == 'thread/goal/cleared') {
      final id = params['threadId'] as String?;
      if (id != null) {
        _goalRevisions[id] = (_goalRevisions[id] ?? 0) + 1;
        _goals[id] = method.endsWith('/cleared')
            ? null
            : CodexRemoteApi.parseGoal(params['goal']);
        _notify();
      }
      return;
    }
    if (method == 'thread/unarchived') {
      // 恢复的旧会话可能早于增量扫描标记，需要重新核对完整目录历史。
      _projectSync?.invalidateMemberships();
    }
    if (method == 'project/changed' ||
        method == 'thread/project/updated' ||
        method == 'thread/name/updated' ||
        method == 'thread/metadata/updated' ||
        method == 'thread/archived' ||
        method == 'thread/unarchived') {
      _projectSyncTimer?.cancel();
      _projectSyncTimer = Timer(const Duration(milliseconds: 250), () {
        if (attempt == _connectionAttempt && isConnected) {
          unawaited(refreshTasks(resetPages: true));
        }
      });
    }
    if (method == 'thread/reverted') {
      final id = params['threadId'] as String?;
      if (id != null) {
        _agentDeltaBatcher.clear();
        _taskReducer.replaceItems(_epoch, id, const []);
        if (_selectedTaskId == id) unawaited(_loadInitialTaskContext(id));
      }
    }
    if (notification.method == 'serverRequest/resolved') {
      final id = notification.params['requestId'];
      final threadId = notification.params['threadId'];
      _userInputRequests = _userInputRequests
          .where((r) => r.id != id || r.threadId != threadId)
          .toList();
      _approvals = _approvals
          .where((r) => r.requestId != id || r.threadId != threadId)
          .toList();
      _notify();
      return;
    }
    final event = CodexRemoteApi.parseNotification(
      notification.method,
      notification.params,
    );
    if (notification.method == 'item/agentMessage/delta' && event != null) {
      _agentDeltaBatcher.add(event);
      return;
    }
    if (notification.method == 'item/completed' ||
        notification.method == 'turn/completed') {
      _agentDeltaBatcher.flush();
    }
    if (event != null) _taskReducer.applyEvent(_epoch, event);
    final threadId =
        notification.params['threadId'] as String? ??
        (notification.params['thread'] is Map
            ? (notification.params['thread'] as Map)['id'] as String?
            : null);
    var activeTurnChanged = false;
    if (notification.method == 'turn/started') {
      final turn = notification.params['turn'];
      final turnId = turn is Map ? turn['id'] as String? : null;
      if (threadId != null && turnId != null) {
        activeTurnChanged = _activeTurnIds[threadId] != turnId;
        _activeTurnIds[threadId] = turnId;
      }
    } else if (notification.method == 'turn/completed' && threadId != null) {
      _interactiveThreadIds.remove(threadId);
      activeTurnChanged = _activeTurnIds.remove(threadId) != null;
      unawaited(refreshTasks());
      unawaited(_flushQueuedPrompt(threadId));
    }
    if (hasRemoteNotificationVisibleChange(
      event: event,
      activeTurnChanged: activeTurnChanged,
    )) {
      _notify();
    }
  }

  void _applyAgentDeltaBatch(List<TaskEvent> events) {
    _taskReducer.applyEvents(_epoch, events);
    _notify();
  }

  void _handleServerRequest(int attempt, RpcServerRequest request) {
    if (attempt != _connectionAttempt) return;
    if (request.method == 'item/tool/requestUserInput') {
      if (_userInputRequests.any((r) => r.id == request.id)) return;
      try {
        final input = UserInputRequest(request);
        _userInputRequests = [..._userInputRequests, input];
        _notify();
      } catch (_) {
        _rpc?.respondError(request.id, -32602, 'Invalid user input request');
      }
      return;
    }
    if (!request.method.contains('requestApproval')) {
      _rpc?.respondError(request.id, -32601, 'Unsupported server request');
      return;
    }
    try {
      final approval = CodexRemoteApi.parseApproval(request);
      _approvals = [..._approvals, approval];
      _notify();
    } on FormatException {
      // 缺失权限范围的请求不能作为普通命令审批处理。
      _rpc?.respondError(request.id, -32602, 'Invalid approval request');
    }
  }

  CodexRemoteApi _requireApi() {
    final api = _api;
    if (api == null || !isConnected) {
      throw StateError('Connect to a host first.');
    }
    return api;
  }

  void answerUserInput(UserInputRequest request, Map<String, String> answers) {
    if (!isConnected || !_userInputRequests.any((r) => identical(r, request))) {
      return;
    }
    try {
      _rpc!.respond(request.id, request.response(answers));
    } catch (_) {
      _error = 'Could not send answers. Check the connection and retry.';
      _notify();
      return;
    }
    _userInputRequests = _userInputRequests
        .where((r) => !identical(r, request))
        .toList();
    _notify();
  }
}
