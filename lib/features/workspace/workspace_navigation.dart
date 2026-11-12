import 'package:flutter/foundation.dart';

enum GoDestination { conversations, workspaces, hosts, settings }

enum ConversationFilter { all, attention, pinned }

/// 产品导航独立于远端状态；服务器事件不能替用户跳转页面。
class WorkspaceNavigation extends ChangeNotifier {
  GoDestination _destination = GoDestination.conversations;
  String? _workspaceId;
  bool _detail = false;
  GoDestination get destination => _destination;
  String? get workspaceId => _workspaceId;
  bool get detail => _detail;

  void select(GoDestination destination) {
    if (_destination == destination && !_detail) return;
    _destination = destination;
    _detail = false;
    notifyListeners();
  }

  void selectWorkspace(String? id) {
    _workspaceId = id;
    _destination = GoDestination.conversations;
    _detail = false;
    notifyListeners();
  }

  void openConversation() {
    _destination = GoDestination.conversations;
    _detail = true;
    notifyListeners();
  }

  void backToList() {
    _detail = false;
    notifyListeners();
  }

  void resetHost() {
    _workspaceId = null;
    _detail = false;
    notifyListeners();
  }
}
