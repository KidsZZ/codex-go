part of 'codex_runtime.dart';

/// 工作区发现、会话目录与分页职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeCatalog on CodexRuntime {
  Future<void> refreshSidebarPins() async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected || _pinScanApi == api) return;
    _pinScanApi = api;
    final token = _taskReducer.capturePageMerge(epoch);
    try {
      final found = <TaskSnapshot>[];
      final seen = <String>{};
      String? cursor;
      do {
        final page = await api.readTaskPage(isPinned: true, cursor: cursor);
        if (api != _api || epoch != _epoch) return;
        found.addAll(page.tasks);
        cursor = page.nextCursor;
        if (cursor != null && !seen.add(cursor)) throw StateError('置顶列表分页游标重复');
      } while (cursor != null);
      _taskReducer.applyPageMerge(token, found, _interactiveThreadIds);
      _sidebarPinnedIds = found.map((t) => t.id).toSet();
      _sidebarPinned
        ..clear()
        ..addEntries(found.map((t) => MapEntry(t.id, t)));
      _notify();
    } catch (_) {
      // 临时离线时保留上次已加载的置顶列表，下一轮恢复后继续刷新。
    } finally {
      if (_pinScanApi == api) _pinScanApi = null;
    }
  }

  Future<void> refreshTasks({
    bool throwOnError = false,
    bool resetPages = false,
  }) async {
    final api = _api;
    final epoch = _epoch;
    final connecting =
        _connectionPhase == RemoteConnectionPhase.connecting ||
        _connectionPhase == RemoteConnectionPhase.reconnecting;
    if (api == null || (!isConnected && !connecting)) return;
    final operation = _refreshOperations.tryAcquire(
      api,
      epoch,
      resetPages: resetPages,
    );
    if (operation == null) return;
    if (resetPages && !connecting) {
      _startProjectDiscovery(
        api,
        attempt: _connectionAttempt,
        epoch: epoch,
        profileId: _selectedHostId!,
      );
    }
    var resetNext = resetPages;
    try {
      while (true) {
        final shouldResetPages = resetNext;
        resetNext = false;
        await _syncSharedProjects(api, epoch);
        if (api != _api || epoch != _epoch) return;
        final initialProject = selectedProject;
        final token = _taskReducer.beginRefresh(epoch);
        final unassignedFuture = api.readTaskPage();
        final initialProjectFuture = initialProject == null
            ? Future<RemoteTaskPage?>.value()
            : _readProjectTasks(api, initialProject);
        final unassignedPage = await unassignedFuture;
        if (api != _api || epoch != _epoch) return;
        _discoverProjects(unassignedPage.tasks);
        final project = selectedProject;
        final selectedProjectId = project?.id;
        final projectPage = project == null
            ? null
            : initialProject?.id == project.id
            ? await initialProjectFuture
            : await _readProjectTasks(api, project);
        if (api != _api || epoch != _epoch) return;
        if (selectedProjectId != _selectedProjectId) {
          resetNext = true;
          continue;
        }
        final snapshots = <String, TaskSnapshot>{
          for (final task in unassignedPage.tasks) task.id: task,
          if (projectPage != null)
            for (final task in projectPage.tasks) task.id: task,
        };
        final loadedByUs = _interactiveThreadIds;
        _taskReducer.applyRefresh(
          token,
          snapshots.values.toList(growable: false),
          loadedByUs,
          retainExisting: true,
        );
        if (projectPage == null) {
          _taskCatalog.clearProjectPage();
        } else if (shouldResetPages) {
          _taskCatalog.replaceProjectPage(
            projectPage.tasks,
            nextCursor: projectPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeProjectHead(
            projectPage.tasks,
            nextCursor: projectPage.nextCursor,
          );
        }
        if (shouldResetPages) {
          _taskCatalog.replaceRecentPage(
            unassignedPage.tasks,
            nextCursor: unassignedPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeRecentHead(
            unassignedPage.tasks,
            nextCursor: unassignedPage.nextCursor,
          );
        }
        if (shouldResetPages) {
          _taskCatalog.replaceUnassignedPage(
            unassignedPage.tasks,
            projects: _projects,
            nextCursor: unassignedPage.nextCursor,
          );
        } else {
          _taskCatalog.mergeUnassignedHead(
            unassignedPage.tasks,
            projects: _projects,
            nextCursor: unassignedPage.nextCursor,
          );
        }
        _taskCatalog.reconcileSharedMembership(
          snapshots.values,
          project?.remoteId,
        );
        _notify();
        if (isConnected) _flushReadyQueuedPrompts();
        final queuedResetPages = operation.takeQueuedResetPages();
        if (queuedResetPages == null || !isConnected) break;
        resetNext = queuedResetPages;
      }
      _startProjectMembershipSync(api, epoch);
    } catch (exception) {
      if (throwOnError) rethrow;
      _error = _friendlyError(exception);
      _notify();
    } finally {
      _refreshOperations.release(operation);
    }
  }

  Future<void> selectTask(String taskId) async {
    _selectionRevision++;
    _markSelectedRead();
    _selectedTaskId = taskId;
    _historyLoadState.clear();
    _notify();
    await _loadInitialTaskContext(taskId);
  }

  void clearSelectedTask() {
    _selectionRevision++;
    _markSelectedRead();
    _selectedTaskId = null;
    _historyLoadState.clear();
    _notify();
  }

  Future<({RemoteTurnPage page, RemoteSubagentDetails? details})>
  readSubagentHistory(String threadId, String hostId, {String? cursor}) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected || hostId != _selectedHostId) {
      throw StateError('Connect to this host to load subagent history.');
    }
    final metadata = cursor == null
        ? api
              .readSubagentDetails(threadId)
              .then<RemoteSubagentDetails?>(
                (details) => details,
                onError: (Object _) => null,
              )
        : null;
    final page = await api.readThreadTurnsPage(threadId, cursor: cursor);
    final details = metadata == null ? null : await metadata;
    if (api != _api || epoch != _epoch || hostId != _selectedHostId) {
      throw StateError('Connection changed. Reload subagent history.');
    }
    return (page: page, details: details);
  }

  Future<void> retrySelectedTaskDetails() async {
    final taskId = _selectedTaskId;
    if (taskId != null) await _loadInitialTaskContext(taskId);
  }

  Future<void> _loadInitialTaskContext(String taskId) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    unawaited(_refreshGoal(taskId));
    final attempt = _connectionAttempt;
    final profileId = _selectedHostId!;
    final token = _historyLoadState.beginInitial(taskId);
    _notify();
    try {
      String? subscriptionError;
      try {
        await _ensureThreadSubscribed(
          taskId,
          api: api,
          attempt: attempt,
          epoch: epoch,
          profileId: profileId,
        );
      } catch (exception) {
        subscriptionError =
            'Live updates unavailable: ${_friendlyError(exception)}';
      }
      if (!_isCurrentSession(api, attempt, epoch, profileId) ||
          _selectedTaskId != taskId) {
        return;
      }
      _agentDeltaBatcher.flush();
      final readToken = _taskReducer.captureItemsRead(epoch, taskId);
      final page = await api.readThreadTurnsPage(taskId);
      if (api != _api || epoch != _epoch) return;
      if (!_historyLoadState.complete(token, nextCursor: page.nextCursor)) {
        return;
      }
      _agentDeltaBatcher.flush();
      _taskReducer.mergeLatestItems(
        epoch,
        taskId,
        page.items,
        readToken: readToken,
      );
      if (subscriptionError != null) {
        _historyLoadState.fail(token, subscriptionError);
      }
    } catch (exception) {
      if (api != _api || epoch != _epoch) return;
      _historyLoadState.fail(token, _friendlyError(exception));
    }
    _notify();
  }

  Future<void> loadTurnPresentationForTask(
    String taskId,
    List<TaskItem> items,
  ) async {
    final api = _api;
    if (api == null || !isConnected || items.isEmpty) return;
    await _loadTurnPresentation(api, _epoch, taskId, items);
  }

  Future<void> _loadTurnPresentation(
    CodexRemoteApi api,
    int epoch,
    String taskId,
    List<TaskItem> items,
  ) async {
    try {
      final turns = await api.readTurnPresentation(taskId, items);
      if (api != _api || epoch != _epoch) return;
      _taskReducer.annotateTurns(epoch, taskId, turns);
      _notify();
    } catch (_) {
      // 过程元数据读取失败时保持展开；正文和历史分页仍然可用，不猜测回合成功。
    }
  }

  Future<void> loadOlderSelectedTaskContext() async {
    final api = _api;
    final epoch = _epoch;
    if (api == null || !isConnected) return;
    final token = _historyLoadState.beginOlder();
    if (token == null) return;
    _notify();
    try {
      final page = await api.readThreadTurnsPage(
        token.taskId,
        cursor: token.cursor,
      );
      if (api != _api || epoch != _epoch || token.taskId != _selectedTaskId) {
        return;
      }
      if (!_historyLoadState.complete(token, nextCursor: page.nextCursor)) {
        return;
      }
      _taskReducer.prependItems(epoch, token.taskId, page.items);
    } catch (exception) {
      if (api != _api || epoch != _epoch) return;
      _historyLoadState.fail(token, _friendlyError(exception));
    }
    _notify();
  }

  Future<void> selectProject(String? projectId) async {
    _selectionRevision++;
    _markSelectedRead();
    final project = projectId == null
        ? null
        : _projects.where((project) => project.id == projectId).firstOrNull;
    if (projectId != null && project == null) return;
    if (_selectedProjectId == projectId) return;
    if (_selectedProjectId case final previous?) {
      _cachedProjectTaskIds[previous] = List.of(_taskCatalog.projectTaskIds);
    }
    _selectedProjectId = projectId;
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog.restoreCachedProjectPage(
      _cachedProjectTaskIds[projectId] ?? const [],
    );
    final api = _api;
    final epoch = _epoch;
    final pageToken = _taskReducer.capturePageMerge(epoch);
    final catalogGeneration = _taskCatalog.projectGeneration;
    final generation = ++_projectPageGeneration;
    if (project == null || api == null || !isConnected) {
      _loadingProjectPage = false;
      _notify();
      return;
    }
    _loadingProjectPage = true;
    _notify();
    try {
      final page = await _readProjectTasks(api, project);
      if (api != _api ||
          epoch != _epoch ||
          generation != _projectPageGeneration ||
          project.id != _selectedProjectId) {
        return;
      }
      if (!_taskCatalog.isCurrentProjectGeneration(catalogGeneration)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.replaceProjectPage(page.tasks, nextCursor: page.nextCursor);
    } catch (exception) {
      if (api == _api &&
          epoch == _epoch &&
          generation == _projectPageGeneration) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (generation == _projectPageGeneration) {
        _loadingProjectPage = false;
        _notify();
      }
    }
  }

  Future<RemoteTaskPage> _readProjectTasks(
    CodexRemoteApi api,
    RemoteProject project, {
    String? cursor,
  }) => api.readTaskPage(
    projectId: project.remoteId,
    cwd: project.remoteId == null ? project.cwd : null,
    cursor: cursor,
  );

  Future<T> _withProjectSync<T>(
    CodexRemoteApi api,
    int epoch,
    Future<T> Function(SharedProjectSync sync) action,
  ) {
    final hostId = _selectedHostId!;
    final attempt = _connectionAttempt;
    void check() => _ensureCurrentSession(api, attempt, epoch, hostId);
    if (_projectOperationApi != api || _projectSync == null) {
      _projectOperationApi = api;
      _projectOperation = Future.value();
      _projectSync = SharedProjectSync(api, _store, hostId, check);
    }
    final sync = _projectSync!;
    final result = _projectOperation.then((_) async {
      check();
      final value = await action(sync);
      check();
      return value;
    });
    _projectOperation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  void _replaceSharedProjects(List<RemoteProject> projects) {
    final previous = selectedProject;
    _projects = mergeRemoteProjects(
      hostId: _selectedHostId!,
      existing: projects,
      discoveredCwds: _projectActivityByCwd.keys,
      activityByCwd: _projectActivityByCwd,
    );
    if (!_projects.any((project) => project.id == _selectedProjectId)) {
      _selectedProjectId =
          _projects
              .where(
                (project) =>
                    previous != null && project.containsCwd(previous.cwd),
              )
              .firstOrNull
              ?.id ??
          _projects.firstOrNull?.id;
      _taskCatalog.clearProjectPage();
    }
  }

  void _startProjectMembershipSync(CodexRemoteApi api, int epoch) {
    if (!isConnected ||
        _inBackground ||
        api != _api ||
        _sharedProjectsApi != api ||
        _projectMembershipApi == api) {
      return;
    }
    _projectMembershipApi = api;
    unawaited(_reconcileProjectMemberships(api, epoch));
  }

  Future<void> _reconcileProjectMemberships(
    CodexRemoteApi api,
    int epoch,
  ) async {
    try {
      // 历史归类独立于连接初始化，避免大量旧会话拖慢或超时中断 SSH 登录。
      final changed = await _withProjectSync<bool>(
        api,
        epoch,
        (sync) => sync.reconcileMemberships(_projects),
      );
      if (changed && api == _api && epoch == _epoch && isConnected) {
        await refreshTasks(resetPages: true);
      }
    } catch (exception) {
      if (api == _api && epoch == _epoch) {
        _error = 'Project task sync failed: ${_friendlyError(exception)}';
        _notify();
      }
    } finally {
      if (_projectMembershipApi == api) _projectMembershipApi = null;
    }
  }

  Future<void> _syncSharedProjects(CodexRemoteApi api, int epoch) async {
    if (_unsupportedProjectsApi == api) return;
    try {
      await _withProjectSync<void>(api, epoch, (sync) async {
        final projects = await sync.synchronize();
        sync.checkSession();
        _sharedProjectsApi = api;
        _replaceSharedProjects(projects);
      });
    } on RpcRemoteException catch (error) {
      if (api != _api || epoch != _epoch) return;
      if (error.code == -32601) {
        _unsupportedProjectsApi = api;
      } else {
        _error = 'Project sync failed: ${_friendlyError(error)}';
      }
    } catch (error) {
      if (api != _api || epoch != _epoch) return;
      _error = 'Project sync failed: ${_friendlyError(error)}';
    }
  }

  Future<void> saveProject({
    String? projectId,
    required String name,
    required String cwd,
  }) async {
    final hostId = _selectedHostId;
    if (hostId == null) throw StateError('Connect to a host first.');
    final normalizedName = name.trim();
    final normalizedCwd = normalizeRemoteCwd(cwd);
    if (normalizedName.isEmpty || normalizedCwd.isEmpty) {
      throw ArgumentError('Project name and remote directory are required.');
    }
    if (!normalizedCwd.startsWith('/')) {
      throw ArgumentError('Use an absolute remote directory path.');
    }
    final api = _requireApi();
    final epoch = _epoch;
    if (_unsupportedProjectsApi == api) {
      throw StateError('Update remote Codex to enable shared projects.');
    }
    final previous = _projects
        .where((project) => project.id == projectId)
        .firstOrNull;
    await _withProjectSync<void>(api, epoch, (sync) async {
      final shared = await sync.synchronize();
      sync.checkSession();
      final byId = shared
          .where((project) => project.id == projectId)
          .firstOrNull;
      if (previous?.remoteId != null && byId == null) {
        throw StateError(
          'This project was deleted on another client. Refresh the list.',
        );
      }
      final byPath = shared
          .where((project) => project.containsCwd(normalizedCwd))
          .toList();
      final existing = byId ?? (byPath.length == 1 ? byPath.single : null);
      final draft =
          existing?.copyWith(name: normalizedName, cwd: normalizedCwd) ??
          RemoteProject(
            id:
                previous?.id ??
                '$hostId-${DateTime.now().microsecondsSinceEpoch}',
            hostId: hostId,
            name: normalizedName,
            cwd: normalizedCwd,
          );
      // Persist an unsynced draft first so a lost create response can be retried.
      if (existing == null) await _store.writeProject(draft);
      sync.checkSession();
      final saved = existing == null
          ? await api.createProject(draft)
          : await api.updateProject(draft);
      sync.checkSession();
      if (existing == null) {
        await sync.adoptUnassignedTasks(saved, cwd: normalizedCwd);
      }
      await _store.writeProject(saved);
      sync.checkSession();
      if (draft.remoteId == null) await _store.deleteProject(hostId, draft.id);
      sync.checkSession();
      _sharedProjectsApi = api;
      _replaceSharedProjects([
        for (final project in shared)
          if (project.remoteId != saved.remoteId) project,
        saved,
      ]);
      _selectedProjectId = saved.id;
    });
    _selectedTaskId = null;
    _historyLoadState.clear();
    _taskCatalog.clearProjectPage();
    _notify();
    await refreshTasks(resetPages: true);
  }

  Future<void> deleteProject(String projectId) async {
    final hostId = _selectedHostId;
    if (hostId == null) return;
    final api = _requireApi();
    await _withProjectSync<void>(api, _epoch, (sync) async {
      final project = _projects.where((p) => p.id == projectId).firstOrNull;
      if (project == null) return;
      if (project.remoteId != null) await api.deleteProject(project.remoteId!);
      sync.checkSession();
      await _store.deleteProject(hostId, projectId);
      sync.checkSession();
      _projects = _projects.where((p) => p.id != projectId).toList();
    });
    if (_selectedProjectId == projectId) {
      _selectedProjectId = _projects.firstOrNull?.id;
      _selectedTaskId = null;
      _historyLoadState.clear();
      _taskCatalog.clearProjectPage();
    }
    _notify();
    await refreshTasks(resetPages: true);
  }

  void toggleUnassigned() {
    _taskCatalog.toggleUnassigned();
    _notify();
  }

  Future<void> loadMoreProjectTasks() async {
    final api = _api;
    final project = selectedProject;
    final continuation = _taskCatalog.projectContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        project == null ||
        continuation == null ||
        _loadingProjectPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    final generation = ++_projectPageGeneration;
    _loadingProjectPage = true;
    _notify();
    try {
      final page = await _readProjectTasks(
        api,
        project,
        cursor: continuation.cursor,
      );
      if (api != _api ||
          epoch != _epoch ||
          generation != _projectPageGeneration ||
          project.id != _selectedProjectId) {
        return;
      }
      if (!_taskCatalog.isCurrentProjectContinuation(continuation)) return;
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendProjectPage(
        continuation,
        page.tasks,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      if (api == _api &&
          epoch == _epoch &&
          generation == _projectPageGeneration) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (generation == _projectPageGeneration) {
        _loadingProjectPage = false;
        _notify();
      }
    }
  }

  Future<void> loadMoreRecentTasks() async {
    final api = _api;
    final continuation = _taskCatalog.recentContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        continuation == null ||
        _loadingRecentPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    _loadingRecentPage = true;
    _notify();
    try {
      final page = await api.readTaskPage(cursor: continuation.cursor);
      if (api != _api || epoch != _epoch) return;
      if (!_taskCatalog.isCurrentRecentContinuation(continuation)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendRecentPage(
        continuation,
        page.tasks,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      if (api == _api && epoch == _epoch) {
        _error = _friendlyError(exception);
      }
    } finally {
      if (api == _api && epoch == _epoch) {
        _loadingRecentPage = false;
        _notify();
      }
    }
  }

  Future<void> loadMoreUnassignedTasks() async {
    final api = _api;
    final continuation = _taskCatalog.unassignedContinuation;
    final epoch = _epoch;
    if (api == null ||
        !isConnected ||
        continuation == null ||
        _loadingUnassignedPage) {
      return;
    }
    final pageToken = _taskReducer.capturePageMerge(epoch);
    _loadingUnassignedPage = true;
    _notify();
    try {
      final page = await api.readTaskPage(cursor: continuation.cursor);
      if (api != _api || epoch != _epoch) return;
      if (!_taskCatalog.isCurrentUnassignedContinuation(continuation)) return;
      _discoverProjects(page.tasks);
      final applied = _taskReducer.applyPageMerge(
        pageToken,
        page.tasks,
        _interactiveThreadIds,
      );
      if (!applied) return;
      _taskCatalog.appendUnassignedPage(
        continuation,
        page.tasks,
        projects: _projects,
        nextCursor: page.nextCursor,
      );
    } catch (exception) {
      _error = _friendlyError(exception);
    } finally {
      _loadingUnassignedPage = false;
      _notify();
    }
  }

  void _discoverProjects(Iterable<TaskSnapshot> tasks) {
    for (final task in tasks) {
      final cwd = normalizeRemoteCwd(task.cwd);
      if (cwd.isEmpty) continue;
      final current = _projectActivityByCwd[cwd];
      if (current == null || task.updatedAt.isAfter(current)) {
        _projectActivityByCwd[cwd] = task.updatedAt;
      }
    }
    _discoverProjectCwds(tasks.map((task) => task.cwd));
  }

  bool _discoverProjectCwds(Iterable<String> cwds) {
    final hostId = _selectedHostId;
    if (hostId == null) return false;
    final projects = mergeRemoteProjects(
      hostId: hostId,
      existing: _projects,
      discoveredCwds: cwds,
      activityByCwd: _projectActivityByCwd,
    );
    if (listEquals(projects, _projects)) return false;
    _projects = projects;
    if (_selectedProjectId == null ||
        !_projects.any((project) => project.id == _selectedProjectId)) {
      _selectedProjectId = _projects.firstOrNull?.id;
      _taskCatalog.clearProjectPage();
    }
    return true;
  }

  void _startProjectDiscovery(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) {
    if (_sharedProjectsApi == api) _startProjectMembershipSync(api, epoch);
    if (identical(_projectDiscoveryApi, api)) return;
    _projectDiscoveryApi = api;
    unawaited(
      _discoverAllProjects(
        api,
        attempt: attempt,
        epoch: epoch,
        profileId: profileId,
      ),
    );
  }

  Future<void> _discoverAllProjects(
    CodexRemoteApi api, {
    required int attempt,
    required int epoch,
    required String profileId,
  }) async {
    try {
      final activity = await api.readProjectActivity(includeArchived: true);
      if (!_isCurrentSession(api, attempt, epoch, profileId)) return;
      for (final entry in activity.entries) {
        final cwd = normalizeRemoteCwd(entry.key);
        final current = _projectActivityByCwd[cwd];
        if (current == null || entry.value.isAfter(current)) {
          _projectActivityByCwd[cwd] = entry.value;
        }
      }
      final changed = _discoverProjectCwds(activity.keys);
      // 和共享项目写入串行化，避免安全存储的读-改-写操作相互覆盖。
      await _withProjectSync<void>(api, epoch, (sync) async {
        for (final project in _projects) {
          sync.checkSession();
          await _store.writeProject(project);
        }
      });
      if (!_isCurrentSession(api, attempt, epoch, profileId) || !changed) {
        return;
      }
      _notify();
      await refreshTasks(resetPages: true);
    } catch (exception) {
      if (_isCurrentSession(api, attempt, epoch, profileId)) {
        _error = '工作区扫描未完成，可刷新重试：${_friendlyError(exception)}';
        _notify();
      }
    } finally {
      if (_projectDiscoveryApi == api) _projectDiscoveryApi = null;
    }
  }
}
