import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';

/// 搜索拥有自己的请求代次，切换主机、工作区或关键字后丢弃过期响应。
class ConversationSearch extends ChangeNotifier {
  ConversationSearch(this.runtime);
  final CodexRuntime runtime;
  Timer? _debounce;
  int _generation = 0;
  bool _disposed = false;
  String _query = '';
  String? _workspaceId;
  List<TaskSnapshot> _results = const [];
  String? _cursor;
  String? _error;
  bool _loading = false;
  String get query => _query;
  List<TaskSnapshot> get results => _results;
  bool get loading => _loading;
  bool get hasMore => _cursor != null;
  String? get error => _error;

  void search(String query, String? workspaceId) {
    _query = query.trim();
    _workspaceId = workspaceId;
    _debounce?.cancel();
    _generation++;
    _results = const [];
    _cursor = null;
    _error = null;
    _loading = _query.isNotEmpty && runtime.isConnected;
    notifyListeners();
    if (_loading) {
      _debounce = Timer(const Duration(milliseconds: 320), () => _load());
    }
  }

  Future<void> more() => _load(more: true);
  Future<void> retry() => _load();

  Future<void> _load({bool more = false}) async {
    if (_disposed ||
        !runtime.isConnected ||
        _query.isEmpty ||
        (more && (_loading || _cursor == null))) {
      return;
    }
    final generation = ++_generation;
    final host = runtime.selectedHostId;
    final project = runtime.projects
        .where((p) => p.id == _workspaceId)
        .firstOrNull;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final page = await runtime.findTasks(
        query: _query,
        cursor: more ? _cursor : null,
        projectId: project?.remoteId,
        cwd: project?.remoteId == null ? project?.cwd : null,
      );
      if (_disposed ||
          generation != _generation ||
          host != runtime.selectedHostId) {
        return;
      }
      // 服务端分页可能在消息更新时重叠，列表按会话 ID 去重。
      _results = {
        for (final task in [
          ...(more ? _results : <TaskSnapshot>[]),
          ...page.tasks,
        ])
          task.id: task,
      }.values.toList();
      if (more && page.nextCursor == _cursor) {
        _cursor = null;
      } else {
        _cursor = page.nextCursor;
      }
    } catch (error) {
      if (!_disposed && generation == _generation) _error = '$error';
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _debounce?.cancel();
    super.dispose();
  }
}
