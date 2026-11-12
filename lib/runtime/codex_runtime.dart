// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:codex_go/infrastructure/platform/connection_keep_alive.dart';
import 'package:codex_go/infrastructure/platform/connection_network.dart';
import 'package:codex_go/infrastructure/platform/attachments.dart';
import 'package:codex_go/infrastructure/platform/diagnostics.dart';
import 'package:codex_go/infrastructure/storage/host_profile.dart';
import 'package:codex_go/infrastructure/storage/profile_store.dart';
import 'package:codex_go/domain/workspaces/remote_project.dart';
import 'package:codex_go/domain/workspaces/shared_project_sync.dart';
import 'package:codex_go/infrastructure/codex/codex_remote_api.dart';
import 'package:codex_go/infrastructure/platform/account_usage.dart';
import 'package:codex_go/infrastructure/ports/port_forward.dart';
import 'package:codex_go/infrastructure/ports/port_forward_manager.dart';
import 'package:codex_go/infrastructure/ports/port_discovery.dart';
import 'package:codex_go/infrastructure/codex/user_input_request.dart';
import 'package:codex_go/infrastructure/codex/foreground_probe.dart';
import 'package:codex_go/infrastructure/codex/json_rpc_client.dart';
import 'package:codex_go/infrastructure/codex/websocket_rpc_transport.dart';
import 'package:codex_go/domain/conversations/task_catalog.dart';
import 'package:codex_go/domain/conversations/task_draft.dart';
import 'package:codex_go/domain/conversations/turn_settings.dart';
import 'package:codex_go/domain/conversations/permission_mode.dart';
import 'package:codex_go/domain/conversations/task_event_batcher.dart';
import 'package:codex_go/domain/conversations/task_message_queue.dart';
import 'package:codex_go/domain/conversations/task_operation_lock.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/domain/conversations/task_refresh_lock.dart';
import 'package:codex_go/infrastructure/ssh/codex_daemon.dart';
import 'package:codex_go/infrastructure/ssh/connection_setup.dart';
import 'package:codex_go/infrastructure/ssh/attachment_upload.dart';
import 'package:codex_go/infrastructure/ssh/file_download.dart' as downloads;
import 'package:codex_go/infrastructure/ssh/resumable_download.dart';
import 'package:codex_go/infrastructure/ssh/ssh_connector.dart';
import 'package:codex_go/infrastructure/ssh/ssh_unix_tunnel.dart';

part 'runtime_persistence.dart';
part 'runtime_files.dart';
part 'runtime_catalog.dart';
part 'runtime_connection.dart';
part 'runtime_conversation.dart';
part 'runtime_outbox.dart';
part 'runtime_events.dart';

enum AppAppearance { system, light, dark }

enum RemoteConnectionPhase { disconnected, connecting, connected, reconnecting }

enum ConnectionStage {
  profile,
  ssh,
  remoteAppServer,
  unixTunnel,
  rpcTunnel,
  initialize,
  refresh,
}

final class QueuedTaskMessage {
  const QueuedTaskMessage({
    required this.id,
    required this.text,
    this.skill,
    this.model,
    this.effort,
    this.serviceTier,
    this.permissionMode = PermissionMode.inherit,
    this.imagePaths = const [],
  });

  final String id;
  final String text;
  final RemoteSkill? skill;
  final String? model;
  final String? effort;
  final String? serviceTier;
  final PermissionMode permissionMode;
  final List<String> imagePaths;

  String get timelineItemId => 'local-user:$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'model': model,
    'effort': effort,
    'serviceTier': serviceTier,
    'permissionMode': permissionMode.name,
    'imagePaths': imagePaths,
    if (skill case final s?)
      'skill': {'name': s.name, 'description': s.description, 'path': s.path},
  };

  factory QueuedTaskMessage.fromJson(Map value) {
    final s = value['skill'] as Map?;
    return QueuedTaskMessage(
      id: value['id'] as String,
      text: value['text'] as String,
      model: value['model'] as String?,
      effort: value['effort'] as String?,
      serviceTier: value['serviceTier'] as String?,
      permissionMode: PermissionMode.restore(value['permissionMode']),
      imagePaths: (value['imagePaths'] as List? ?? const []).cast<String>(),
      skill: s == null
          ? null
          : RemoteSkill(
              name: s['name'] as String,
              description: s['description'] as String,
              path: s['path'] as String,
            ),
    );
  }
}

HostProfile? resolveAutoConnectProfile(
  List<HostProfile> profiles,
  String? profileId,
) {
  if (profileId == null) return null;
  return profiles.where((profile) => profile.id == profileId).firstOrNull;
}

Future<String> resolveCodexSocketForProfile(
  SshCommandRunner run,
  HostProfile profile,
) async {
  switch (profile.appServerMode) {
    case AppServerMode.shared:
      return CodexDaemon.startShared(run, environment: profile.environment);
    case AppServerMode.custom:
      final configuredSocketPath = profile.customAppServerSocket;
      if (configuredSocketPath == null ||
          RegExp(r'[\x00-\x1F\x7F]').hasMatch(configuredSocketPath)) {
        throw const CodexBootstrapException(
          'Custom app-server socket must be an absolute Unix socket path.',
        );
      }
      final socketPath = configuredSocketPath.trim();
      if (socketPath.isEmpty || !socketPath.startsWith('/')) {
        throw const CodexBootstrapException(
          'Custom app-server socket must be an absolute Unix socket path.',
        );
      }
      return socketPath;
    case AppServerMode.isolated:
      return CodexDaemon.bootstrap(run, environment: profile.environment);
  }
}

bool hasRemoteNotificationVisibleChange({
  required TaskEvent? event,
  required bool activeTurnChanged,
}) => event != null || activeTurnChanged;

bool requiresThreadResumeForSend({required bool subscribed}) => !subscribed;

bool requiresThreadResumeForSteer({required bool subscribed}) => !subscribed;

final class CodexRuntime extends ChangeNotifier {
  CodexRuntime({required ProfileStore store})
    : _store = store,
      _connector = SshConnector(store);

  factory CodexRuntime.memory({
    List<TaskSnapshot> cachedTasks = const [],
    List<RemoteModel> cachedModels = const [],
    List<RemoteProject> cachedProjects = const [],
    List<HostProfile> cachedProfiles = const [],
    String? hostId,
    ProfileStore? store,
  }) {
    final controller = CodexRuntime(store: store ?? MemoryProfileStore());
    controller._workspaceLoaded = true;
    controller._models = cachedModels;
    controller._profiles = List.unmodifiable(cachedProfiles);
    controller._projects = List.unmodifiable(cachedProjects);
    controller._selectedHostId = hostId;
    controller._workspaceHostId = hostId;
    for (final project in cachedProjects) {
      controller._cachedProjectTaskIds[project.id] = cachedTasks
          .where((task) => project.containsCwd(task.cwd))
          .map((task) => task.id)
          .toList();
    }
    controller._taskReducer.applyRefresh(
      controller._taskReducer.beginRefresh(controller._epoch),
      cachedTasks,
      {},
    );
    controller._taskCatalog.replaceRecentPage(cachedTasks, nextCursor: null);
    return controller;
  }

  final ProfileStore _store;

  final SshConnector _connector;
  final ConnectionKeepAlive _keepAlive = ConnectionKeepAlive();
  late final ConnectionNetwork _network = ConnectionNetwork(_networkChanged);
  bool _networkAvailable = true;
  String? _keepAliveWarning;
  final TaskReducer _taskReducer = TaskReducer();
  late final TaskEventBatcher _agentDeltaBatcher = TaskEventBatcher(
    onFlush: _applyAgentDeltaBatch,
  );
  final TaskCatalog _taskCatalog = TaskCatalog();
  final TaskHistoryLoadState _historyLoadState = TaskHistoryLoadState();
  final Map<String, TaskMessageQueue<QueuedTaskMessage>> _outboxes = {};
  TaskMessageQueue<QueuedTaskMessage> get _messageQueue =>
      _outboxes.putIfAbsent(
        _workspaceHostId ?? _selectedHostId ?? '',
        TaskMessageQueue.new,
      );
  final Map<String, String> _deliveryStates = {};
  final Map<(String, String), Map<String, dynamic>> _savedDrafts = {};
  Timer? _draftSaveTimer;
  Future<void> _workspaceWrite = Future.value();
  bool _disposed = false;
  bool _workspaceLoaded = false;
  // 独立通知语言变化，流式消息更新时无需重新生成 MaterialApp 和配色。
  final ValueNotifier<String?> _language = ValueNotifier(null);
  ValueListenable<String?> get languagePreference => _language;
  String? get languageCode => _language.value;
  bool get preferencesReady => _workspaceLoaded;

  final Map<String, RemoteThreadGoal?> _goals = {};
  final Map<String, int> _goalRevisions = {};
  Timer? _projectSyncTimer;
  final TaskOperationLock _messageOperations = TaskOperationLock();
  final Map<String, Set<String>> _inFlightQueuedMessageIds = {};
  final TaskRefreshLock<CodexRemoteApi> _refreshOperations = TaskRefreshLock();

  List<HostProfile> _profiles = const [];
  List<RemoteProject> _projects = const [];
  List<RemoteModel> _models = const [];
  final AccountUsageController accountUsage = AccountUsageController();
  final PortForwardManager portForwards = PortForwardManager();
  bool get canDiscoverPorts =>
      isConnected && _ssh != null && _workspaceHostId == _selectedHostId;

  // 页面导航由产品层管理；运行时只关心当前会话是否真正可见。
  bool _conversationVisible = false;
  final ValueNotifier<AppAppearance> _appearance = ValueNotifier(
    AppAppearance.system,
  );
  ValueListenable<AppAppearance> get appearancePreference => _appearance;
  AppAppearance get appearance => _appearance.value;

  void _notify() => notifyListeners();

  void setConversationVisible(bool visible) {
    if (_conversationVisible == visible) return;
    _conversationVisible = visible;
    _selectionRevision++;
    if (visible) _markSelectedRead();
  }

  Future<void> setAppearance(AppAppearance value) async {
    if (!_workspaceLoaded) return;
    final previous = _appearance.value;
    _appearance.value = value;
    try {
      await _saveWorkspace();
    } catch (_) {
      _appearance.value = previous;
      rethrow;
    }
  }

  RemoteConnectionPhase _connectionPhase = RemoteConnectionPhase.disconnected;
  String? _selectedHostId;
  String? _workspaceHostId;
  final Map<String, List<String>> _cachedProjectTaskIds = {};
  String? _selectedProjectId;
  String? _selectedTaskId;
  int _selectionRevision = 0;
  final Map<String, String> _activeTurnIds = {};
  final Map<String, DateTime> _projectActivityByCwd = {};
  String? _error;
  HostKeyChallenge? _hostKeyChallenge;
  Completer<bool>? _hostKeyCompleter;
  List<PendingApproval> _approvals = const [];
  List<UserInputRequest> _userInputRequests = const [];
  List<UserInputRequest> get userInputRequests => _userInputRequests;
  final Set<String> _interactiveThreadIds = {};
  Set<String> _subscribedThreadIds = {};
  final Map<String, Future<void>> _pendingThreadSubscriptions = {};
  final Map<String, int> _serviceTierRevisions = {};
  SshConnection? _ssh;
  SshUnixTunnel? _tunnel;
  JsonRpcClient? _rpc;
  CodexRemoteApi? _api;
  CodexRemoteApi? _projectDiscoveryApi;
  CodexRemoteApi? _sharedProjectsApi;
  CodexRemoteApi? _unsupportedProjectsApi;
  CodexRemoteApi? _projectOperationApi;
  SharedProjectSync? _projectSync;
  CodexRemoteApi? _projectMembershipApi;
  Future<void> _projectOperation = Future.value();
  StreamSubscription<RpcNotification>? _notificationSubscription;
  StreamSubscription<RpcServerRequest>? _requestSubscription;
  Timer? _refreshTimer;
  Timer? _reconnectTimer;
  bool _inBackground = false;
  bool _expediteReconnect = false;
  ConnectionSetup? _openingAttempt;
  CodexRemoteApi? _foregroundProbeApi;
  var _epoch = 0;
  var _connectionAttempt = 0;
  var _reconnectAttempt = 0;
  var _loadingProjectPage = false;
  var _loadingRecentPage = false;
  var _loadingUnassignedPage = false;
  var _projectPageGeneration = 0;
  var _nextQueuedMessageId = 0;
  Future<void> _autoConnectIntentWrite = Future.value();

  List<HostProfile> get profiles => _profiles;
  List<RemoteProject> get projects => _projects;
  List<RemoteModel> get models => _models;
  RemoteConnectionPhase get connectionPhase => _connectionPhase;
  final Map<(String, String), TaskDraft> _drafts = {};

  final Map<(String, String), DateTime> _readActivity = {};
  final Map<String, DateTime> _attentionBaseline = {};

  String? deliveryState(String id) => _deliveryStates[id];
  RemoteThreadGoal? get selectedGoal => _goals[_selectedTaskId];

  String? get selectedHostId => _selectedHostId;
  String? get selectedProjectId => _selectedProjectId;
  String? get selectedTaskId => _selectedTaskId;
  String? get error => _error ?? _keepAliveWarning;
  HostKeyChallenge? get hostKeyChallenge => _hostKeyChallenge;
  List<PendingApproval> get approvals => _approvals;
  TaskState get taskState => _taskReducer.state;
  bool get unassignedExpanded => _taskCatalog.unassignedExpanded;
  bool get hasMoreProjectTasks => _taskCatalog.projectNextCursor != null;
  bool get hasMoreRecentTasks => _taskCatalog.recentNextCursor != null;
  bool get hasMoreUnassignedTasks => _taskCatalog.unassignedNextCursor != null;
  bool get isLoadingProjectPage => _loadingProjectPage;
  bool get isLoadingRecentTasks => _loadingRecentPage;
  bool get isLoadingUnassignedPage => _loadingUnassignedPage;
  bool get hasOlderTaskContext =>
      _historyLoadState.taskId == _selectedTaskId && _historyLoadState.hasOlder;
  bool get isLoadingOlderTaskContext =>
      _historyLoadState.taskId == _selectedTaskId &&
      _historyLoadState.isLoadingOlder;
  String? get olderTaskContextError =>
      _historyLoadState.taskId == _selectedTaskId
      ? _historyLoadState.olderError
      : null;

  HostProfile? get selectedHost =>
      _profiles.where((profile) => profile.id == _selectedHostId).firstOrNull;

  RemoteProject? get selectedProject => _selectedProjectId == null
      ? null
      : _projects
            .where((project) => project.id == _selectedProjectId)
            .firstOrNull;

  List<TaskRecord> get projectTasks =>
      _tasksForIds(_taskCatalog.projectTaskIds);

  Set<String> _sidebarPinnedIds = {};
  final Map<String, TaskSnapshot> _sidebarPinned = {};
  CodexRemoteApi? _pinScanApi;
  List<TaskRecord> get sidebarTasks =>
      _tasksForIds({..._sidebarPinnedIds, ..._taskCatalog.recentTaskIds});

  List<TaskRecord> get sidebarProjectTasks {
    final project = selectedProject;
    if (project == null) return const [];
    return _tasksForIds({
      ..._taskCatalog.projectTaskIds,
      for (final task in _sidebarPinned.values)
        if (project.remoteId != null
            ? task.projectId == project.remoteId
            : project.containsCwd(task.cwd))
          task.id,
    });
  }

  List<TaskRecord> get recentTasks => _tasksForIds(_taskCatalog.recentTaskIds);

  List<TaskRecord> get unassignedTasks =>
      _tasksForIds(_taskCatalog.unassignedTaskIds);

  TaskRecord? get selectedTask => _selectedTaskId == null
      ? null
      : _taskReducer.state.tasks[_selectedTaskId];

  bool get isConnected => _connectionPhase == RemoteConnectionPhase.connected;

  bool isTaskDetailLoading(String taskId) =>
      _historyLoadState.taskId == taskId && _historyLoadState.isInitialLoading;

  String? taskDetailError(String taskId) => _historyLoadState.taskId == taskId
      ? _historyLoadState.initialError
      : null;

  List<QueuedTaskMessage> queuedMessagesForTask(String taskId) =>
      _messageQueue.values(taskId);

  Set<String> inFlightQueuedMessageIdsForTask(String taskId) =>
      Set.unmodifiable(_inFlightQueuedMessageIds[taskId] ?? const <String>{});

  bool _downloadingFile = false;
  DownloadCancellation? _downloadCancellation;

  List<TaskRecord> _tasksForIds(Iterable<String> ids) =>
      (ids
            .map((id) => _taskReducer.state.tasks[id])
            .whereType<TaskRecord>()
            .toList(growable: false))
        ..sort(
          (a, b) => a.isPinned == b.isPinned
              ? b.updatedAt.compareTo(a.updatedAt)
              : a.isPinned
              ? -1
              : 1,
        );

  void clearError() {
    _error = null;
    _keepAliveWarning = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _draftSaveTimer?.cancel();
    _projectSyncTimer?.cancel();
    unawaited(
      flushWorkspace().catchError((Object error) {
        debugPrint('Could not save workspace on close: $error');
      }),
    );
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _drafts.clear();
    cancelDownload();
    _network.dispose();
    _connectionAttempt++;
    _openingAttempt?.cancel(StateError('Controller disposed'));
    _cancelHostKeyPrompt();
    _reconnectTimer?.cancel();
    _refreshTimer?.cancel();
    _agentDeltaBatcher.dispose();
    unawaited(_closeTransport(reason: 'controller_disposed'));
    _language.dispose();
    _appearance.dispose();
    accountUsage.dispose();
    portForwards.dispose();
    unawaited(_setKeepAlive(false));
    super.dispose();
  }
}

bool _isUncertainSubmissionFailure(Object exception) =>
    exception is RpcTimeoutException || exception is RpcDisconnectedException;

String _friendlyError(Object exception) {
  if (exception is RpcRemoteException) return exception.message;
  final text = exception.toString();
  return text.replaceFirst(
    RegExp(r'^(Exception|StateError|ArgumentError):\s*'),
    '',
  );
}

String describeConnectionFailure(
  ConnectionStage stage,
  Object exception,
  HostProfile profile,
) {
  final detail = _friendlyError(exception);
  final target = profile.proxyJump;
  final endpoint = target == null
      ? '${profile.hostName}:${profile.port}'
      : '${target.hostName}:${target.port}';
  return switch (stage) {
    ConnectionStage.profile => 'Could not read the SSH profile: $detail',
    ConnectionStage.ssh => 'SSH connection to $endpoint failed: $detail',
    ConnectionStage.remoteAppServer =>
      'SSH connected successfully, but the remote Codex app-server failed: '
          '$detail',
    ConnectionStage.unixTunnel =>
      'SSH connected successfully, but the remote Codex socket could not be '
          'forwarded: $detail',
    ConnectionStage.rpcTunnel =>
      'SSH connected successfully, but the Codex tunnel refused the local RPC '
          'connection: $detail',
    ConnectionStage.initialize =>
      'The Codex tunnel connected, but RPC initialization failed: $detail',
    ConnectionStage.refresh =>
      'Codex connected, but its task list could not be loaded: $detail',
  };
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
