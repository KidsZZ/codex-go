part of 'codex_runtime.dart';

/// 偏好、草稿与队列落盘职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimePersistence on CodexRuntime {
  /// 语言随工作区偏好一起落盘，不接触主机凭据或远端配置。
  Future<void> setLanguage(String? code) async {
    if (!_workspaceLoaded) return;
    if (code != null && code != 'zh' && code != 'en') {
      throw ArgumentError.value(code, 'code');
    }
    final previous = _language.value;
    _language.value = code;
    _notify();
    try {
      await _saveWorkspace();
    } catch (_) {
      _language.value = previous;
      _notify();
      rethrow;
    }
  }

  TaskDraft draftForTask(String taskId) {
    final hostId = _selectedHostId ?? '';
    return _drafts.putIfAbsent((hostId, taskId), () {
      final draft = TaskDraft(
        retainFilesOnDispose: _store is WorkspaceStore,
        canUpload: () =>
            isConnected &&
            _selectedHostId == hostId &&
            _workspaceHostId == hostId,
        upload: (attachment, target, cancellation, {onProgress}) {
          if (_selectedHostId != hostId) {
            throw StateError(
              'Reconnect to the original host to resume upload.',
            );
          }
          return uploadAttachmentNow(
            attachment,
            target,
            cancellation,
            onProgress: onProgress,
          );
        },
      );
      final saved = _savedDrafts[(hostId, taskId)];
      if (saved != null) draft.restore(saved);
      void save() {
        if (_disposed || draft.sending) return;
        _savedDrafts[(hostId, taskId)] = draft.toJson();
        _draftSaveTimer?.cancel();
        _draftSaveTimer = Timer(const Duration(milliseconds: 200), () {
          unawaited(
            _saveWorkspace().catchError((Object error) {
              _error = 'Could not save draft: $error';
              if (!_disposed) _notify();
            }),
          );
        });
      }

      draft.composer.addListener(save);
      draft.addListener(save);
      return draft;
    });
  }

  bool isTaskUnread(String id) {
    final host = _selectedHostId;
    final task = taskState.tasks[id];
    if (host == null ||
        task == null ||
        (_selectedTaskId == id && !_inBackground && _conversationVisible)) {
      return false;
    }
    final baseline = _attentionBaseline.putIfAbsent(
      host,
      () => DateTime.now().toUtc(),
    );
    return task.updatedAt.isAfter(_readActivity[(host, id)] ?? baseline);
  }

  void _markSelectedRead() {
    final host = _selectedHostId;
    final task = selectedTask;
    if (host != null &&
        task != null &&
        _conversationVisible &&
        !_inBackground) {
      _readActivity[(host, task.id)] = task.updatedAt;
    }
  }

  Future<void> _restoreWorkspace() async {
    final store = _store;
    if (store is! WorkspaceStore) return;
    final saved = await (store as WorkspaceStore).readWorkspace();
    _appearance.value =
        AppAppearance.values
            .where((value) => value.name == saved['appearance'])
            .firstOrNull ??
        AppAppearance.system;
    final language = saved['language'];
    _language.value = language == 'zh' || language == 'en'
        ? language as String
        : null;
    portForwards.restore(saved['portForwards']);
    for (final raw in saved['readActivity'] as List? ?? const []) {
      final entry = raw as Map;
      final time = DateTime.tryParse(entry['at'] as String? ?? '');
      if (time != null) {
        _readActivity[(entry['host'] as String, entry['task'] as String)] =
            time;
      }
    }
    for (final entry
        in (saved['attentionBaseline'] as Map? ?? const {}).entries) {
      final time = DateTime.tryParse(entry.value as String);
      if (time != null) _attentionBaseline[entry.key as String] = time;
    }
    for (final raw in saved['drafts'] as List? ?? const []) {
      final entry = raw as Map;
      _savedDrafts[(entry['host'] as String, entry['task'] as String)] =
          (entry['draft'] as Map).cast<String, dynamic>();
    }
    for (final raw in saved['outbox'] as List? ?? const []) {
      final entry = raw as Map;
      final message = QueuedTaskMessage.fromJson(entry['message'] as Map);
      final host = entry['host'] as String;
      _outboxes
          .putIfAbsent(host, TaskMessageQueue.new)
          .enqueue(entry['task'] as String, message);
      _deliveryStates[message.id] = entry['state'] == 'sending'
          ? 'uncertain'
          : entry['state'] as String? ?? 'queued';
    }
    _workspaceLoaded = true;
  }

  Future<void> _saveWorkspace() {
    final store = _store;
    if (store is! WorkspaceStore) return Future.value();
    if (!_workspaceLoaded) {
      return Future.error(StateError('Draft storage has not been restored.'));
    }
    final snapshot = <String, dynamic>{
      'language': _language.value,
      'appearance': _appearance.value.name,
      'readActivity': [
        for (final e in _readActivity.entries)
          {'host': e.key.$1, 'task': e.key.$2, 'at': e.value.toIso8601String()},
      ],
      'attentionBaseline': {
        for (final e in _attentionBaseline.entries)
          e.key: e.value.toIso8601String(),
      },
      'portForwards': portForwards.rules.map((rule) => rule.toJson()).toList(),
      'drafts': [
        for (final entry in _savedDrafts.entries)
          {'host': entry.key.$1, 'task': entry.key.$2, 'draft': entry.value},
      ],
      'outbox': [
        for (final host in _outboxes.entries)
          for (final task in host.value.threadIds)
            for (final message in host.value.values(task))
              {
                'host': host.key,
                'task': task,
                'message': message.toJson(),
                'state': _deliveryStates[message.id] ?? 'queued',
              },
      ],
    };
    final result = _workspaceWrite.then(
      (_) => (store as WorkspaceStore).writeWorkspace(snapshot),
    );
    _workspaceWrite = result.catchError((Object _) {});
    return result;
  }

  Future<void> flushWorkspace() async {
    _markSelectedRead();
    _draftSaveTimer?.cancel();
    if (!_workspaceLoaded) return;
    await _saveWorkspace();
  }
}
