part of 'codex_runtime.dart';

/// 消息发送、插话与持久队列职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeOutbox on CodexRuntime {
  Future<TaskMessageDisposition> sendPrompt(
    String prompt, {
    String? taskId,
    TaskSendMode mode = TaskSendMode.auto,
    RemoteSkill? skill,
    String? model,
    String? effort,
    String? serviceTier,
    PermissionMode permissionMode = PermissionMode.inherit,
    List<RemoteAttachment> attachments = const [],
  }) async {
    final api = _api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId;
    if (profileId == null) throw StateError('Select a host first.');
    if (!isConnected && mode == TaskSendMode.steer) {
      throw StateError(
        'Reconnect to steer the active turn. Use Queue while offline.',
      );
    }
    var task = taskId == null ? selectedTask : taskState.tasks[taskId];
    if (task == null) throw StateError('Select or create a task first.');
    task = _taskReducer.state.tasks[task.id] ?? task;
    final normalized = attachmentPrompt(prompt, attachments);
    if (normalized.isEmpty) throw ArgumentError('Message is required.');
    final pending = QueuedTaskMessage(
      id: 'queued-${DateTime.now().microsecondsSinceEpoch}-${_nextQueuedMessageId++}',
      text: skill == null ? normalized : '\$${skill.name} $normalized',
      skill: skill,
      model: model,
      effort: effort,
      serviceTier: serviceTier,
      permissionMode: permissionMode,
      imagePaths: List.unmodifiable(
        attachments.where((file) => file.isImage).map((file) => file.path),
      ),
    );
    if (!isConnected ||
        api == null ||
        mode == TaskSendMode.queue ||
        (mode == TaskSendMode.auto && _messageQueue.hasPending(task.id))) {
      await _enqueuePrompt(task.id, pending);
      return TaskMessageDisposition.queued;
    }

    var activeTurnId = _activeTurnIds[task.id];
    if (mode == TaskSendMode.steer ||
        (activeTurnId == null &&
            (task.status == TaskStatus.running ||
                task.status == TaskStatus.queued))) {
      activeTurnId = await api.readActiveTurnId(task.id);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      if (activeTurnId != null) {
        _activeTurnIds[task.id] = activeTurnId;
      } else {
        _activeTurnIds.remove(task.id);
      }
    }
    final route = mode == TaskSendMode.auto
        ? chooseTaskMessageRoute(task.status, activeTurnId: activeTurnId)
        : chooseExplicitMessageRoute(mode, activeTurnId: activeTurnId);
    switch (route) {
      case TaskMessageRoute.steer:
        return _steerPrompt(
          task,
          pending,
          activeTurnId!,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
          queueIfFinished: mode != TaskSendMode.steer,
        );
      case TaskMessageRoute.queue:
        await _enqueuePrompt(task.id, pending);
        return TaskMessageDisposition.queued;
      case TaskMessageRoute.start:
        await _startPendingPrompt(task, pending);
        return TaskMessageDisposition.started;
    }
  }

  Future<TaskMessageDisposition> _steerPrompt(
    TaskRecord task,
    QueuedTaskMessage pending,
    String turnId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
    bool queueIfFinished = true,
  }) async {
    _setLocalUserMessageStatus(task.id, pending, 'sending', epoch: epoch);
    var steerRequested = false;
    try {
      if (requiresThreadResumeForSteer(
        subscribed: _subscribedThreadIds.contains(task.id),
      )) {
        await _ensureThreadSubscribed(
          task.id,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      }
      final mentions = await api.resolveMcpMentions(
        task.id,
        pending.text,
        skillName: pending.skill?.name,
      );
      _ensureCurrentSession(api, attempt, epoch, profileId);
      try {
        await _journalPrompt(profileId, task.id, pending);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        steerRequested = true;
        await api.steerTurn(
          task.id,
          turnId,
          pending.text,
          imagePaths: pending.imagePaths,
          mcpMentions: mentions,
        );
        await _settlePrompt(profileId, task.id, pending, 'sent');
      } on RpcRemoteException {
        steerRequested = false;
        final refreshedTurnId = await api.readActiveTurnId(task.id);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        if (refreshedTurnId == null) {
          _activeTurnIds.remove(task.id);
          if (!queueIfFinished) {
            throw StateError(
              'The turn finished before Steer was accepted. '
              'Use Auto to start a new turn.',
            );
          }
          _setLocalUserMessageStatus(task.id, pending, 'queued', epoch: epoch);
          await _enqueuePrompt(task.id, pending);
          return TaskMessageDisposition.queued;
        }
        if (refreshedTurnId == turnId) rethrow;
        _activeTurnIds[task.id] = refreshedTurnId;
        steerRequested = true;
        await api.steerTurn(
          task.id,
          refreshedTurnId,
          pending.text,
          imagePaths: pending.imagePaths,
          mcpMentions: mentions,
        );
        await _settlePrompt(profileId, task.id, pending, 'sent');
      }
      _recordSubmittedPrompt(
        task.id,
        pending,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      );
      return TaskMessageDisposition.steered;
    } catch (exception) {
      if (steerRequested && _isUncertainSubmissionFailure(exception)) {
        await _settlePrompt(profileId, task.id, pending, 'uncertain');
        _setLocalUserMessageStatus(task.id, pending, 'uncertain', epoch: epoch);
        return TaskMessageDisposition.queued;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      await _settlePrompt(profileId, task.id, pending, 'sent');
      rethrow;
    }
  }

  Future<void> _enqueuePrompt(
    String threadId,
    QueuedTaskMessage pending,
  ) async {
    _captureSubmittedDraft(_selectedHostId!, threadId);
    if (!_messageQueue.values(threadId).contains(pending)) {
      _messageQueue.enqueue(threadId, pending);
    }
    _deliveryStates[pending.id] = 'queued';
    try {
      await _saveWorkspace();
    } catch (_) {
      _messageQueue.remove(threadId, pending);
      _deliveryStates.remove(pending.id);
      rethrow;
    }
    _notify();
    unawaited(_flushQueuedPrompt(threadId));
  }

  Future<void> _journalPrompt(
    String host,
    String task,
    QueuedTaskMessage pending,
  ) async {
    _captureSubmittedDraft(host, task);
    final queue = _outboxes.putIfAbsent(host, TaskMessageQueue.new);
    if (!queue.values(task).contains(pending)) queue.enqueue(task, pending);
    _deliveryStates[pending.id] = 'sending';
    _markQueuedMessageInFlight(task, pending.id);
    await _saveWorkspace();
  }

  Future<void> _settlePrompt(
    String host,
    String task,
    QueuedTaskMessage pending,
    String state,
  ) async {
    _unmarkQueuedMessageInFlight(task, pending.id);
    if (state == 'sent') {
      _outboxes[host]?.remove(task, pending);
      _deliveryStates.remove(pending.id);
    } else {
      _deliveryStates[pending.id] = state;
    }
    try {
      await _saveWorkspace();
    } catch (error) {
      _error =
          'Could not save delivery status. Check conversation before retrying: $error';
    }
    if (!_disposed) _notify();
  }

  void _captureSubmittedDraft(String host, String task) {
    final draft = _drafts[(host, task)];
    if (draft != null && draft.sending) {
      _savedDrafts[(host, task)] = draft.toJson();
    }
  }

  Future<void> retryQueuedMessage(String taskId, String messageId) async {
    final pending = _messageQueue
        .values(taskId)
        .where((message) => message.id == messageId)
        .firstOrNull;
    if (pending == null || _deliveryStates[messageId] == 'sending') return;
    _requireApi();
    _deliveryStates[messageId] = 'queued';
    await _saveWorkspace();
    await _flushQueuedPrompt(taskId);
    _notify();
  }

  Future<void> _startPendingPrompt(
    TaskRecord task,
    QueuedTaskMessage pending, {
    bool keepOnFailure = false,
  }) async {
    final api = _requireApi();
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    final profileId = _selectedHostId!;
    _setLocalUserMessageStatus(task.id, pending, 'sending', epoch: epoch);
    var turnRequested = false;
    try {
      if (requiresThreadResumeForSend(
        subscribed: _subscribedThreadIds.contains(task.id),
      )) {
        await _ensureThreadSubscribed(
          task.id,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      }
      final mentions = await api.resolveMcpMentions(
        task.id,
        pending.text,
        skillName: pending.skill?.name,
      );
      _ensureCurrentSession(api, attempt, epoch, profileId);
      await _journalPrompt(profileId, task.id, pending);
      _ensureCurrentSession(api, attempt, epoch, profileId);
      turnRequested = true;
      await api.startTurn(
        task.id,
        pending.text,
        skill: pending.skill,
        model: pending.model,
        effort: pending.effort,
        serviceTier: pending.serviceTier,
        imagePaths: pending.imagePaths,
        permissionMode: pending.permissionMode,
        mcpMentions: mentions,
      );
      await _settlePrompt(profileId, task.id, pending, 'sent');
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      _taskReducer.setTurnSettings(
        epoch,
        task.id,
        pending.model,
        pending.effort,
      );
      _recordSubmittedPrompt(
        task.id,
        pending,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      );
    } catch (exception) {
      if (turnRequested && _isUncertainSubmissionFailure(exception)) {
        await _settlePrompt(profileId, task.id, pending, 'uncertain');
        _setLocalUserMessageStatus(task.id, pending, 'uncertain', epoch: epoch);
        return;
      }
      _setLocalUserMessageStatus(task.id, pending, 'failed', epoch: epoch);
      await _settlePrompt(
        profileId,
        task.id,
        pending,
        keepOnFailure ? 'failed' : 'sent',
      );
      rethrow;
    }
  }

  void _setLocalUserMessageStatus(
    String threadId,
    QueuedTaskMessage pending,
    String status, {
    required int epoch,
  }) {
    if (_disposed) return;
    if (status == 'sending') {
      _taskReducer.appendPendingUserMessage(
        epoch,
        threadId,
        pending.timelineItemId,
        pending.text,
      );
    } else {
      _taskReducer.updatePendingUserMessageStatus(
        epoch,
        threadId,
        pending.timelineItemId,
        status,
      );
    }
    _notify();
  }

  void _recordSubmittedPrompt(
    String threadId,
    QueuedTaskMessage pending, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
  }) {
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    _setLocalUserMessageStatus(threadId, pending, 'sent', epoch: epoch);
    _interactiveThreadIds.add(threadId);
    _taskReducer.markLocalParticipation(epoch, threadId);
    _taskReducer.applyEvent(
      epoch,
      TaskEvent.statusChanged(threadId, TaskStatus.running),
    );
    _notify();
    unawaited(
      _catchUpTaskContext(
        threadId,
        api: api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      ),
    );
  }

  Future<void> _recoverSelectedTaskAfterReconnect(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    final threadId = _selectedTaskId;
    if (threadId == null) return;
    await _loadInitialTaskContext(threadId);
    if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
    await _catchUpTaskContext(
      threadId,
      api: api,
      attempt: attempt,
      epoch: epoch,
      profileId: profileId,
      readItems: false,
    );
  }

  Future<void> _catchUpTaskContext(
    String threadId, {
    required CodexRemoteApi api,
    required int attempt,
    required int epoch,
    required String profileId,
    bool readItems = true,
  }) async {
    if (readItems) {
      try {
        _agentDeltaBatcher.flush();
        final readToken = _taskReducer.captureItemsRead(epoch, threadId);
        final page = await api.readThreadTurnsPage(threadId);
        if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
        _agentDeltaBatcher.flush();
        _taskReducer.mergeLatestItems(
          epoch,
          threadId,
          page.items,
          readToken: readToken,
        );
        if (_selectedTaskId == threadId &&
            _historyLoadState.taskId != threadId) {
          final token = _historyLoadState.beginInitial(threadId);
          _historyLoadState.complete(token, nextCursor: page.nextCursor);
        }
        _notify();
      } catch (exception) {
        debugPrint('Could not catch up selected task context: $exception');
      }
    }
    try {
      final activeTurnId = await api.readActiveTurnId(threadId);
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      if (activeTurnId == null) {
        _activeTurnIds.remove(threadId);
      } else {
        _activeTurnIds[threadId] = activeTurnId;
      }
      _notify();
    } catch (exception) {
      debugPrint('Could not refresh selected task turn state: $exception');
    }
  }

  Future<void> _flushQueuedPrompt(String threadId) async {
    final operation = _messageOperations.tryAcquire(threadId);
    if (operation == null) return;
    try {
      final pending = _messageQueue.peek(threadId);
      final task = _taskReducer.state.tasks[threadId];
      if (pending == null ||
          task == null ||
          !isConnected ||
          (_deliveryStates[pending.id] != null &&
              _deliveryStates[pending.id] != 'queued')) {
        return;
      }
      String? activeTurnId;
      var activeTurnChecked = false;
      {
        final api = _requireApi();
        final attempt = _connectionAttempt;
        final epoch = _epoch;
        final profileId = _selectedHostId!;
        activeTurnId = await api.readActiveTurnId(threadId);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        activeTurnChecked = true;
        if (activeTurnId == null) {
          _activeTurnIds.remove(threadId);
        } else {
          _activeTurnIds[threadId] = activeTurnId;
        }
      }
      if (chooseQueuedPromptAction(
            task.status,
            activeTurnId: activeTurnId,
            activeTurnChecked: activeTurnChecked,
          ) ==
          QueuedPromptAction.wait) {
        return;
      }
      _markQueuedMessageInFlight(threadId, pending.id);
      try {
        await _startPendingPrompt(task, pending, keepOnFailure: true);
      } finally {
        _unmarkQueuedMessageInFlight(threadId, pending.id);
      }
    } catch (exception) {
      _error = _friendlyError(exception);
      _notify();
    } finally {
      _messageOperations.release(threadId, operation);
    }
  }

  void _flushReadyQueuedPrompts() {
    for (final threadId in _messageQueue.threadIds) {
      if (!_taskReducer.state.tasks.containsKey(threadId)) {
        _taskReducer.applyEvent(
          _epoch,
          TaskEvent.statusChanged(threadId, TaskStatus.unknown),
        );
      }
      unawaited(_flushQueuedPrompt(threadId));
    }
  }

  void _markQueuedMessageInFlight(String threadId, String messageId) {
    final ids = _inFlightQueuedMessageIds.putIfAbsent(threadId, () => {});
    if (ids.add(messageId) && !_disposed) _notify();
  }

  void _unmarkQueuedMessageInFlight(String threadId, String messageId) {
    final ids = _inFlightQueuedMessageIds[threadId];
    if (ids == null || !ids.remove(messageId)) return;
    if (ids.isEmpty) _inFlightQueuedMessageIds.remove(threadId);
    if (!_disposed) _notify();
  }

  Future<void> removeQueuedMessage(String taskId, String messageId) async {
    if (_deliveryStates[messageId] == 'sending') {
      throw StateError('This message is already being sent.');
    }
    final operation = _messageOperations.tryAcquire(taskId);
    if (operation == null) {
      throw StateError('A queued message is already being sent.');
    }
    try {
      final pending = _messageQueue
          .values(taskId)
          .where((message) => message.id == messageId)
          .firstOrNull;
      if (pending != null && _messageQueue.remove(taskId, pending)) {
        _deliveryStates.remove(pending.id);
        await _saveWorkspace();
        _notify();
      }
    } finally {
      _messageOperations.release(taskId, operation);
    }
  }

  Future<void> steerQueuedMessage(String taskId, String messageId) async {
    if (_deliveryStates[messageId] == 'sending' ||
        _deliveryStates[messageId] == 'uncertain') {
      throw StateError('Check delivery before sending this message again.');
    }
    final operation = _messageOperations.tryAcquire(taskId);
    if (operation == null) {
      throw StateError('A queued message is already being sent.');
    }
    try {
      final pending = _messageQueue
          .values(taskId)
          .where((message) => message.id == messageId)
          .firstOrNull;
      if (pending == null) return;
      final api = _requireApi();
      final attempt = _connectionAttempt;
      final epoch = _epoch;
      final profileId = _selectedHostId!;
      var turnId = _activeTurnIds[taskId];
      if (turnId == null) {
        turnId = await api.readActiveTurnId(taskId);
        _ensureCurrentSession(api, attempt, epoch, profileId);
        if (turnId != null) _activeTurnIds[taskId] = turnId;
      }
      if (turnId == null) {
        throw StateError('This task does not have an active turn to steer.');
      }
      _markQueuedMessageInFlight(taskId, pending.id);
      _setLocalUserMessageStatus(taskId, pending, 'sending', epoch: epoch);
      var steerRequested = false;
      try {
        if (requiresThreadResumeForSteer(
          subscribed: _subscribedThreadIds.contains(taskId),
        )) {
          await _ensureThreadSubscribed(
            taskId,
            api: api,
            attempt: attempt,
            epoch: epoch,
            profileId: profileId,
          );
        }
        final mentions = await api.resolveMcpMentions(
          taskId,
          pending.text,
          skillName: pending.skill?.name,
        );
        _ensureCurrentSession(api, attempt, epoch, profileId);
        try {
          await _journalPrompt(profileId, taskId, pending);
          _ensureCurrentSession(api, attempt, epoch, profileId);
          steerRequested = true;
          await api.steerTurn(
            taskId,
            turnId,
            pending.text,
            imagePaths: pending.imagePaths,
            mcpMentions: mentions,
          );
          await _settlePrompt(profileId, taskId, pending, 'sent');
        } on RpcRemoteException {
          steerRequested = false;
          final refreshedTurnId = await api.readActiveTurnId(taskId);
          _ensureCurrentSession(api, attempt, epoch, profileId);
          if (refreshedTurnId == null) {
            _activeTurnIds.remove(taskId);
            throw StateError(
              'This task no longer has an active turn to steer.',
            );
          }
          if (refreshedTurnId == turnId) rethrow;
          _activeTurnIds[taskId] = refreshedTurnId;
          steerRequested = true;
          await api.steerTurn(
            taskId,
            refreshedTurnId,
            pending.text,
            imagePaths: pending.imagePaths,
            mcpMentions: mentions,
          );
          await _settlePrompt(profileId, taskId, pending, 'sent');
        }
        _recordSubmittedPrompt(
          taskId,
          pending,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
        if (_messageQueue.remove(taskId, pending)) _notify();
      } catch (exception) {
        if (steerRequested && _isUncertainSubmissionFailure(exception)) {
          await _settlePrompt(profileId, taskId, pending, 'uncertain');
          _setLocalUserMessageStatus(
            taskId,
            pending,
            'uncertain',
            epoch: epoch,
          );
          return;
        }
        await _settlePrompt(profileId, taskId, pending, 'failed');
        _setLocalUserMessageStatus(taskId, pending, 'queued', epoch: epoch);
        rethrow;
      }
    } finally {
      _unmarkQueuedMessageInFlight(taskId, messageId);
      _messageOperations.release(taskId, operation);
    }
  }
}
