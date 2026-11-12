// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
final class RemoteProject {
  const RemoteProject({
    required this.id,
    required this.hostId,
    required this.name,
    required this.cwd,
    this.remoteId,
    this.discovered = false,
    this.updatedAt,
    this.additionalRoots = const [],
  });

  factory RemoteProject.fromJson(Map<String, dynamic> json) => RemoteProject(
    id: json['id'] as String,
    hostId: json['hostId'] as String,
    name: json['name'] as String,
    cwd: json['cwd'] as String,
    remoteId: json['remoteId'] as String?,
    discovered: json['discovered'] == true,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    additionalRoots: (json['additionalRoots'] as List<dynamic>? ?? const [])
        .cast<String>(),
  );

  final String id;
  final String hostId;
  final String name;
  final String cwd;
  final String? remoteId;
  // 由历史目录发现的工作区仅用于浏览，不隐式创建远端共享项目。
  final bool discovered;
  final DateTime? updatedAt;
  final List<String> additionalRoots;

  Iterable<String> get roots => [cwd, ...additionalRoots];

  bool containsCwd(String path) =>
      roots.any((root) => normalizeRemoteCwd(root) == normalizeRemoteCwd(path));

  RemoteProject copyWith({
    String? id,
    String? hostId,
    String? name,
    String? cwd,
    String? remoteId,
    bool? discovered,
    DateTime? updatedAt,
    List<String>? additionalRoots,
  }) => RemoteProject(
    id: id ?? this.id,
    hostId: hostId ?? this.hostId,
    name: name ?? this.name,
    cwd: cwd ?? this.cwd,
    remoteId: remoteId ?? this.remoteId,
    discovered: discovered ?? this.discovered,
    updatedAt: updatedAt ?? this.updatedAt,
    additionalRoots: additionalRoots ?? this.additionalRoots,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'hostId': hostId,
    'name': name,
    'cwd': cwd,
    if (discovered) 'discovered': true,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    if (remoteId != null) 'remoteId': remoteId,
    if (additionalRoots.isNotEmpty) 'additionalRoots': additionalRoots,
  };

  @override
  bool operator ==(Object other) =>
      other is RemoteProject &&
      other.id == id &&
      other.hostId == hostId &&
      other.name == name &&
      other.cwd == cwd &&
      other.remoteId == remoteId &&
      other.discovered == discovered &&
      other.updatedAt == updatedAt &&
      _sameRoots(other.additionalRoots, additionalRoots);

  @override
  int get hashCode => Object.hash(
    id,
    hostId,
    name,
    cwd,
    remoteId,
    discovered,
    updatedAt,
    Object.hashAll(additionalRoots),
  );
}

bool _sameRoots(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(a.length, (index) => a[index] == b[index]).every((v) => v);

List<RemoteProject> mergeRemoteProjects({
  required String hostId,
  required Iterable<RemoteProject> existing,
  required Iterable<String> discoveredCwds,
  Map<String, DateTime> activityByCwd = const {},
}) {
  final normalizedActivity = <String, DateTime>{};
  for (final entry in activityByCwd.entries) {
    final cwd = normalizeRemoteCwd(entry.key);
    if (cwd.isEmpty) continue;
    final current = normalizedActivity[cwd];
    if (current == null || entry.value.isAfter(current)) {
      normalizedActivity[cwd] = entry.value;
    }
  }
  final projectsByCwd = <String, RemoteProject>{};
  for (final project in existing) {
    if (project.hostId != hostId) continue;
    final cwd = normalizeRemoteCwd(project.cwd);
    if (cwd.isEmpty && project.remoteId == null) continue;
    projectsByCwd.putIfAbsent(
      project.remoteId == null ? cwd : 'remote:${project.remoteId}',
      () => project.copyWith(cwd: cwd),
    );
  }
  for (final rawCwd in discoveredCwds) {
    final cwd = normalizeRemoteCwd(rawCwd);
    if (cwd.isEmpty ||
        projectsByCwd.values.any((project) => project.containsCwd(cwd))) {
      continue;
    }
    projectsByCwd[cwd] = RemoteProject(
      id: _automaticProjectId(hostId, cwd),
      hostId: hostId,
      discovered: true,
      name: _automaticProjectName(cwd),
      cwd: cwd,
    );
  }
  final projects =
      projectsByCwd.values
          .map((project) {
            var latest = project.updatedAt;
            for (final root in project.roots) {
              final activity = normalizedActivity[normalizeRemoteCwd(root)];
              if (activity != null &&
                  (latest == null || activity.isAfter(latest))) {
                latest = activity;
              }
            }
            return project.copyWith(updatedAt: latest);
          })
          .toList(growable: false)
        ..sort((first, second) {
          final firstActivity = first.updatedAt;
          final secondActivity = second.updatedAt;
          if (firstActivity != null || secondActivity != null) {
            if (firstActivity == null) return 1;
            if (secondActivity == null) return -1;
            final byActivity = secondActivity.compareTo(firstActivity);
            if (byActivity != 0) return byActivity;
          }
          final byName = first.name.toLowerCase().compareTo(
            second.name.toLowerCase(),
          );
          return byName == 0 ? first.cwd.compareTo(second.cwd) : byName;
        });
  return List.unmodifiable(projects);
}

String normalizeRemoteCwd(String cwd) {
  final normalized = cwd.trim();
  if (normalized.length <= 1) return normalized;
  return normalized.replaceFirst(RegExp(r'/+$'), '');
}

String _automaticProjectId(String hostId, String cwd) =>
    'cwd:${Uri.encodeComponent(hostId)}:${Uri.encodeComponent(cwd)}';

String _automaticProjectName(String cwd) {
  final parts = cwd.split('/').where((part) => part.isNotEmpty);
  return parts.isEmpty ? cwd : parts.last;
}
