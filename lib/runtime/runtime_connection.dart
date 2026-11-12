part of 'codex_runtime.dart';

/// 连接建立、恢复与生命周期职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeConnection on CodexRuntime {
  Future<void> initialize() async {
    HostProfile? autoConnectProfile;
    try {
      _profiles = await _store.readProfiles();
      autoConnectProfile = resolveAutoConnectProfile(
        _profiles,
        await _store.readAutoConnectHostId(),
      );
    } catch (exception) {
      _profiles = const [];
      _error = 'Could not read secure storage: $exception';
    }
    try {
      await _restoreWorkspace();
    } catch (exception) {
      _workspaceLoaded = false;
      _error = 'Could not restore drafts and queued messages: $exception';
    }
    _notify();
    if (autoConnectProfile != null) {
      unawaited(connectHost(autoConnectProfile));
    }
  }

  void observeNetwork() => unawaited(_network.start());

  Future<void> saveProfile(HostProfile profile, HostSecret secret) async {
    await _store.writeProfile(profile, secret);
    _profiles = await _store.readProfiles();
    _selectedHostId ??= profile.id;
    _notify();
  }

  Future<void> deleteProfile(String id) async {
    if (_selectedHostId == id) await disconnect();
    if (_workspaceHostId == id) {
      _workspaceHostId = null;
      _models = const [];
      _projects = const [];
      _selectedTaskId = null;
      _selectedProjectId = null;
      _taskCatalog.clear();
      _cachedProjectTaskIds.clear();
      _epoch = _taskReducer.beginConnection();
    }
    for (final key in _drafts.keys.where((key) => key.$1 == id).toList()) {
      final draft = _drafts.remove(key);
      if (draft != null) {
        for (final file in draft.attachments.toList()) {
          draft.removeAttachment(file);
        }
        draft.dispose();
      }
    }
    _savedDrafts.removeWhere((key, _) => key.$1 == id);
    _outboxes.remove(id);
    await portForwards.removeHost(id);
    await _saveWorkspace();
    await _store.deleteProfile(id);
    if (_selectedHostId == id) _selectedHostId = null;
    _profiles = await _store.readProfiles();
    _notify();
  }

  Future<HostSecret> readSecret(String id) => _store.readSecret(id);

  Future<void> connectHost(HostProfile profile) async {
    cancelDownload();
    final preserveWorkspace = _workspaceHostId == profile.id;
    final attempt = ++_connectionAttempt;
    _openingAttempt?.cancel(StateError('Connection replaced'));
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    _messageOperations.clear();
    _inFlightQueuedMessageIds.clear();
    await _closeTransport();
    if (attempt != _connectionAttempt) return;
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection(clearTasks: !preserveWorkspace);
    if (!preserveWorkspace) {
      _models = const [];
      _projects = const [];
      _selectedProjectId = null;
      _selectedTaskId = null;
      _taskCatalog.clear();
      _cachedProjectTaskIds.clear();
    }
    _workspaceHostId = profile.id;
    _goals.clear();
    _goalRevisions.clear();
    await _openConnection(
      profile,
      attempt: attempt,
      reconnecting: false,
      preserveWorkspace: preserveWorkspace,
    );
  }

  Future<void> _openConnection(
    HostProfile profile, {
    required int attempt,
    required bool reconnecting,
    bool preserveWorkspace = false,
  }) async {
    final setup = ConnectionSetup(attempt);
    _openingAttempt = setup;
    Diagnostics.record('connection.open', {
      'attempt': attempt,
      'reconnecting': reconnecting,
      'background': _inBackground,
    });
    _selectedHostId = profile.id;
    if (!reconnecting && !preserveWorkspace) _selectedTaskId = null;
    _connectionPhase = reconnecting
        ? RemoteConnectionPhase.reconnecting
        : RemoteConnectionPhase.connecting;
    _error = null;
    _notify();

    SshConnection? ssh;
    SshUnixTunnel? tunnel;
    JsonRpcClient? rpc;
    StreamSubscription<RpcNotification>? notifications;
    StreamSubscription<RpcServerRequest>? requests;
    var published = false;
    var stage = ConnectionStage.profile;
    try {
      if (!_inBackground) {
        await setup.run('keepAlive', () => _setKeepAlive(true));
      }
      if (attempt != _connectionAttempt) return;
      final secret = await setup.run(
        'profileSecret',
        () => _store.readSecret(profile.id),
      );
      final projects = reconnecting || preserveWorkspace
          ? _projects
          : await setup.run(
              'profileProjects',
              () => _store.readProjects(profile.id),
            );
      if (attempt != _connectionAttempt) return;
      if (!reconnecting && !preserveWorkspace) {
        _projectActivityByCwd.clear();
        _sidebarPinnedIds.clear();
        _sidebarPinned.clear();
        _projects = mergeRemoteProjects(
          hostId: profile.id,
          existing: projects,
          discoveredCwds: const [],
        );
        for (final project in _projects) {
          if (project.updatedAt != null) {
            _projectActivityByCwd[project.cwd] = project.updatedAt!;
          }
        }
        _selectedProjectId = _projects.firstOrNull?.id;
        _taskCatalog.clear();
        _historyLoadState.clear();
      }
      stage = ConnectionStage.ssh;
      ssh = await setup.run<SshConnection>(
        stage.name,
        () => _connector.connect(
          profile,
          secret,
          prompt: (challenge) {
            if (attempt != _connectionAttempt) return Future.value(false);
            return _promptForHostKey(challenge);
          },
          diagnosticAttempt: attempt,
          setup: setup,
        ),
        timeout: profile.sshOptions.setupTimeout(
          hasJumpHost: profile.proxyJump != null,
        ),
        closeLateResult: (connection) =>
            connection.close(reason: 'late_connection_setup_result'),
      );
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.remoteAppServer;
      final client = ssh.client;
      final socketPath = await setup.run(
        stage.name,
        () => resolveCodexSocketForProfile((command, {environment}) async {
          final commandWatch = Stopwatch()..start();
          final result = await client.runWithResult(
            command,
            environment: environment,
          );
          Diagnostics.record('bootstrap.commandResult', {
            'attempt': attempt,
            'mode': profile.appServerMode.name,
            'durationMs': commandWatch.elapsedMilliseconds,
            'exitCode': result.exitCode,
            'exitSignal': result.exitSignal?.signalName,
            'stdoutBytes': result.stdout.length,
            'stderrBytes': result.stderr.length,
          });
          return SshCommandResult(
            stdout: result.stdout,
            stderr: result.stderr,
            exitCode: result.exitCode,
            exitSignal: result.exitSignal?.signalName,
          );
        }, profile),
      );
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.unixTunnel;
      tunnel = await setup.run<SshUnixTunnel>(
        stage.name,
        () => SshUnixTunnel.start(
          client,
          socketPath,
          environment: profile.environment,
        ),
        closeLateResult: (value) => value.close(),
      );
      if (attempt != _connectionAttempt) return;
      stage = ConnectionStage.rpcTunnel;
      final activeTunnel = tunnel;
      setup.watchClosed(activeTunnel.firstFailure, () {});
      final transport = await setup.run(
        stage.name,
        () => WebSocketRpcTransport.connect(
          Uri.parse('ws://127.0.0.1:${activeTunnel.localPort}/'),
        ),
        closeLateResult: (value) =>
            boundedConnectionCleanup('lateWebSocket', value.close),
      );
      rpc = JsonRpcClient(transport)..start();
      setup.watchClosed(rpc.done, () {});
      final api = CodexRemoteApi(rpc);
      notifications = api.notifications.listen(
        (notification) => _handleNotification(attempt, notification),
      );
      requests = api.serverRequests.listen(
        (request) => _handleServerRequest(attempt, request),
      );
      stage = ConnectionStage.initialize;
      await setup.run(stage.name, api.initialize);
      if (attempt != _connectionAttempt) return;
      final catalog = await setup.run('modelCatalog', () async {
        try {
          return await api.readModelCatalog();
        } catch (exception) {
          debugPrint('Could not read remote model catalog: $exception');
          return _models;
        }
      });
      if (attempt != _connectionAttempt) return;
      _models = catalog;
      if (attempt != _connectionAttempt) return;

      _ssh = ssh;
      _tunnel = tunnel;
      _rpc = rpc;
      _api = api;
      _notificationSubscription = notifications;
      _requestSubscription = requests;
      _subscribedThreadIds = {};
      published = true;
      unawaited(rpc.done.then((_) => _handleTransportLoss(attempt, profile)));
      stage = ConnectionStage.refresh;
      await setup.run(
        stage.name,
        () => refreshTasks(throwOnError: true, resetPages: true),
      );
      if (attempt != _connectionAttempt) return;
      _connectionPhase = RemoteConnectionPhase.connected;
      // Optional forwarding failures are isolated from chat connectivity.
      unawaited(
        portForwards.attach(
          profile.id,
          (host, port) async =>
              SshPortForwardChannel(await ssh!.client.forwardLocal(host, port)),
        ),
      );
      setup.dispose();
      if (identical(_openingAttempt, setup)) _openingAttempt = null;
      accountUsage.bind(api);
      unawaited(accountUsage.refresh());
      Diagnostics.record('connection.ready', {'attempt': attempt});
      _reconnectAttempt = 0;
      _expediteReconnect = false;
      if (reconnecting || preserveWorkspace) {
        await _recoverSelectedTaskAfterReconnect(
          api,
          attempt: attempt,
          epoch: _epoch,
          profileId: profile.id,
        );
      }
      if (attempt != _connectionAttempt) return;
      _notify();
      _startProjectDiscovery(
        api,
        attempt: attempt,
        epoch: _epoch,
        profileId: profile.id,
      );
      await _rememberAutoConnectHost(profile.id);
      if (attempt != _connectionAttempt) return;
      _startRefreshTimer();
      _flushReadyQueuedPrompts();
      for (final key in _savedDrafts.keys.toList()) {
        if (key.$1 == profile.id) draftForTask(key.$2);
      }
      for (final entry in _drafts.entries) {
        if (entry.key.$1 == profile.id) entry.value.resumeWaitingUploads();
      }
    } catch (exception, stackTrace) {
      if (attempt != _connectionAttempt) return;
      _cancelHostKeyPrompt();
      Diagnostics.record('connection.failed', {
        'attempt': attempt,
        'stage': stage.name,
        'appServerMode': profile.appServerMode.name,
        ...Diagnostics.errorFields(
          exception,
          sensitiveValues: profile.environment.values,
        ),
      });
      debugPrint(
        'Connection failed during ${stage.name} for '
        '${profile.hostName}:${profile.port}: $exception',
      );
      debugPrintStack(stackTrace: stackTrace);
      _error = describeConnectionFailure(stage, exception, profile);
      if (published) await _closeTransport(reason: 'connection_setup_failed');
      if (attempt != _connectionAttempt) return;
      if (reconnecting) {
        _connectionPhase = RemoteConnectionPhase.reconnecting;
        _scheduleReconnect(profile, attempt);
      } else {
        _connectionPhase = RemoteConnectionPhase.disconnected;
        await _setKeepAlive(false);
      }
    } finally {
      setup.dispose();
      if (identical(_openingAttempt, setup)) _openingAttempt = null;
      if (!published) {
        await Future.wait([
          if (notifications != null)
            boundedConnectionCleanup('notifications', notifications.cancel),
          if (requests != null)
            boundedConnectionCleanup('requests', requests.cancel),
          if (rpc != null) boundedConnectionCleanup('rpc', rpc.close),
          if (tunnel != null) boundedConnectionCleanup('tunnel', tunnel.close),
          if (ssh != null)
            boundedConnectionCleanup(
              'ssh',
              () => ssh!.close(reason: 'unpublished_connection_cleanup'),
            ),
        ]);
      }
    }
    _notify();
  }

  Future<void> _handleTransportLoss(int attempt, HostProfile profile) async {
    Diagnostics.record('connection.transportLoss', {
      'attempt': attempt,
      'currentAttempt': _connectionAttempt,
      'phase': _connectionPhase.name,
      'background': _inBackground,
    });
    if (attempt != _connectionAttempt ||
        _connectionPhase != RemoteConnectionPhase.connected) {
      return;
    }
    _connectionPhase = RemoteConnectionPhase.reconnecting;
    _error = 'Remote connection lost. Reconnecting...';
    _notify();
    await _closeTransport(reason: 'transport_loss_cleanup');
    if (attempt == _connectionAttempt) {
      _notify();
      _scheduleReconnect(profile, attempt);
    }
  }

  void _scheduleReconnect(
    HostProfile profile,
    int attempt, {
    bool immediate = false,
  }) {
    if (!_networkAvailable ||
        (_inBackground && !_keepAlive.isEnabled) ||
        attempt != _connectionAttempt ||
        _reconnectTimer != null) {
      return;
    }
    const delays = [1, 2, 4, 8, 15];
    final delayIndex = _reconnectAttempt < delays.length
        ? _reconnectAttempt
        : delays.length - 1;
    final seconds = immediate || _expediteReconnect ? 0 : delays[delayIndex];
    Diagnostics.record('connection.retryScheduled', {
      'attempt': attempt,
      'delaySeconds': seconds,
      'background': _inBackground,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _expediteReconnect = false;
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: seconds), () {
      _reconnectTimer = null;
      if (attempt != _connectionAttempt) return;
      final nextAttempt = ++_connectionAttempt;
      _agentDeltaBatcher.clear();
      _epoch = _taskReducer.beginConnection(clearTasks: false);
      unawaited(
        _openConnection(profile, attempt: nextAttempt, reconnecting: true),
      );
    });
  }

  void _startRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_inBackground || !isConnected) return;
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(refreshTasks()),
    );
  }

  Future<void> _networkChanged(bool available) async {
    _networkAvailable = available;
    Diagnostics.record('connection.networkChanged', {'available': available});
    if (!available) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      return;
    }
    final profile = _profiles.where((p) => p.id == _selectedHostId).firstOrNull;
    if (profile == null) return;
    if (_openingAttempt case final setup?) {
      setup.checkDeadline();
      return;
    }
    if (_connectionPhase == RemoteConnectionPhase.reconnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _scheduleReconnect(profile, _connectionAttempt, immediate: true);
      return;
    }
    final api = _api;
    final rpc = _rpc;
    if (!isConnected ||
        api == null ||
        rpc == null ||
        _foregroundProbeApi == api) {
      return;
    }
    _foregroundProbeApi = api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    try {
      final sshHealthy = await _ssh?.checkHealth() ?? false;
      final disconnected =
          !sshHealthy || await foregroundTransportDisconnected(rpc);
      if (!_isCurrentSession(api, attempt, epoch, profile.id)) return;
      if (disconnected) {
        _expediteReconnect = true;
        await _handleTransportLoss(attempt, profile);
      } else if (available) {
        await _recoverSelectedTaskAfterReconnect(
          api,
          attempt: attempt,
          epoch: epoch,
          profileId: profile.id,
        );
      }
    } catch (error) {
      Diagnostics.record(
        'connection.networkRecovery.error',
        Diagnostics.errorFields(error),
      );
    } finally {
      if (_foregroundProbeApi == api) _foregroundProbeApi = null;
    }
  }

  void enterBackground() {
    unawaited(
      flushWorkspace().catchError((Object error) {
        _error = 'Could not save draft: $error';
      }),
    );
    Diagnostics.record('connection.background', {
      'phase': _connectionPhase.name,
      'attempt': _connectionAttempt,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _inBackground = true;
    _expediteReconnect = false;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (!_keepAlive.isEnabled) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
    // Keep the transport; backgrounding is not an explicit disconnect.
  }

  Future<void> _setKeepAlive(bool enabled) async {
    final attempt = _connectionAttempt;
    try {
      await _keepAlive.setEnabled(enabled, verifyNative: enabled);
      if (attempt == _connectionAttempt) _keepAliveWarning = null;
    } catch (exception) {
      if (attempt != _connectionAttempt) return;
      _keepAliveWarning = 'Background connection protection: $exception';
      Diagnostics.record('keepAlive.error', Diagnostics.errorFields(exception));
      debugPrint(_keepAliveWarning);
    }
  }

  Future<void> restoreForegroundConnection() async {
    Diagnostics.record('connection.foreground', {
      'phase': _connectionPhase.name,
      'attempt': _connectionAttempt,
      'keepAliveCached': _keepAlive.isEnabled,
    });
    _inBackground = false;
    _expediteReconnect = true;
    final profile = _profiles
        .where((profile) => profile.id == _selectedHostId)
        .firstOrNull;
    // Respect explicit disconnect, and never overlap an in-flight connection.
    if (profile == null) return;
    if (_openingAttempt case final setup?) {
      setup.checkDeadline();
      return;
    }
    if (_connectionPhase != RemoteConnectionPhase.disconnected) {
      final attempt = _connectionAttempt;
      await _setKeepAlive(true);
      if (attempt != _connectionAttempt ||
          _connectionPhase == RemoteConnectionPhase.disconnected) {
        return;
      }
    }
    if (_connectionPhase == RemoteConnectionPhase.reconnecting) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _scheduleReconnect(profile, _connectionAttempt, immediate: true);
      return;
    }
    final api = _api;
    final rpc = _rpc;
    if (!isConnected ||
        api == null ||
        rpc == null ||
        _foregroundProbeApi == api) {
      return;
    }
    _foregroundProbeApi = api;
    final attempt = _connectionAttempt;
    final epoch = _epoch;
    try {
      final sshHealthy = await _ssh?.checkHealth() ?? false;
      final disconnected =
          !sshHealthy || await foregroundTransportDisconnected(rpc);
      if (!_isCurrentSession(api, attempt, epoch, profile.id) ||
          _inBackground) {
        return;
      }
      if (disconnected) {
        await _handleTransportLoss(attempt, profile);
        return;
      }
      _expediteReconnect = false;
      _startRefreshTimer();
      unawaited(
        _recoverSelectedTaskAfterReconnect(
          api,
          attempt: attempt,
          epoch: epoch,
          profileId: profile.id,
        ),
      );
      if (_isCurrentSession(api, attempt, epoch, profile.id) &&
          !_inBackground) {
        unawaited(refreshTasks());
      }
    } catch (exception) {
      if (_isCurrentSession(api, attempt, epoch, profile.id)) {
        debugPrint('Foreground connection check failed: $exception');
        // Resume polling even if catch-up preparation failed. Only a confirmed
        // transport disconnect (above or rpc.done) may tear down this session.
        _expediteReconnect = false;
        _startRefreshTimer();
      }
    } finally {
      if (_foregroundProbeApi == api) _foregroundProbeApi = null;
    }
  }

  Future<bool> _promptForHostKey(HostKeyChallenge challenge) async {
    _hostKeyCompleter?.complete(false);
    final completer = Completer<bool>();
    _hostKeyCompleter = completer;
    _hostKeyChallenge = challenge;
    _notify();
    return completer.future;
  }

  void answerHostKey(bool accepted) {
    final completer = _hostKeyCompleter;
    _hostKeyCompleter = null;
    _hostKeyChallenge = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(accepted);
    }
    _notify();
  }

  void _cancelHostKeyPrompt() {
    final completer = _hostKeyCompleter;
    _hostKeyCompleter = null;
    _hostKeyChallenge = null;
    if (completer != null && !completer.isCompleted) completer.complete(false);
  }

  Future<void> disconnect() async {
    cancelDownload();
    Diagnostics.record('connection.userDisconnect');
    _expediteReconnect = false;
    _connectionAttempt++;
    _openingAttempt?.cancel(StateError('User disconnected'));
    final stoppingKeepAlive = _setKeepAlive(false);
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connectionPhase = RemoteConnectionPhase.disconnected;
    _loadingProjectPage = false;
    _loadingRecentPage = false;
    _loadingUnassignedPage = false;
    _projectPageGeneration++;
    _historyLoadState.clear();
    _activeTurnIds.clear();
    _messageOperations.clear();
    _inFlightQueuedMessageIds.clear();
    _subscribedThreadIds = {};
    _interactiveThreadIds.clear();
    _agentDeltaBatcher.clear();
    _epoch = _taskReducer.beginConnection(clearTasks: false);
    _approvals = const [];
    await _closeTransport(reason: 'user_disconnect');
    try {
      await _writeAutoConnectIntent(null);
    } catch (exception) {
      _error = 'Disconnected, but could not clear auto-connect: $exception';
    }
    await stoppingKeepAlive;
    _notify();
  }

  Future<void> _rememberAutoConnectHost(String profileId) async {
    try {
      await _writeAutoConnectIntent(profileId);
    } catch (exception) {
      debugPrint('Could not remember auto-connect host: $exception');
    }
  }

  Future<void> _writeAutoConnectIntent(String? profileId) {
    final operation = _autoConnectIntentWrite.then(
      (_) => _store.writeAutoConnectHostId(profileId),
    );
    _autoConnectIntentWrite = operation.catchError((Object exception) {
      debugPrint('Could not persist auto-connect intent: $exception');
    });
    return operation;
  }

  Future<void> _closeTransport({
    String reason = 'connection_replaced_or_closed',
  }) async {
    final closingPorts = portForwards.detach();
    accountUsage.bind(null);
    _userInputRequests = const [];
    Diagnostics.record('connection.closeRequested', {'closeReason': reason});
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _agentDeltaBatcher.clear();
    _approvals = const [];
    _historyLoadState.cancelPending();
    _projectDiscoveryApi = null;
    _projectSync = null;
    _projectMembershipApi = null;
    _subscribedThreadIds = {};
    _pendingThreadSubscriptions.clear();
    _serviceTierRevisions.clear();
    _loadingProjectPage = false;
    _loadingRecentPage = false;
    _loadingUnassignedPage = false;
    _projectPageGeneration++;
    final notificationSubscription = _notificationSubscription;
    final requestSubscription = _requestSubscription;
    final rpc = _rpc;
    final tunnel = _tunnel;
    final ssh = _ssh;
    _notificationSubscription = null;
    _requestSubscription = null;
    _rpc = null;
    _api = null;
    _tunnel = null;
    _ssh = null;
    await Future.wait([
      boundedConnectionCleanup('portForwards', () => closingPorts),
      if (notificationSubscription != null)
        boundedConnectionCleanup(
          'notifications',
          notificationSubscription.cancel,
        ),
      if (requestSubscription != null)
        boundedConnectionCleanup('requests', requestSubscription.cancel),
      if (rpc != null) boundedConnectionCleanup('rpc', rpc.close),
      if (tunnel != null) boundedConnectionCleanup('tunnel', tunnel.close),
      if (ssh != null)
        boundedConnectionCleanup('ssh', () => ssh.close(reason: reason)),
    ]);
  }
}
