import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:codex_go/domain/workspaces/remote_project.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';

class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({
    required this.runtime,
    required this.onOpen,
    required this.onHosts,
    super.key,
  });
  final CodexRuntime runtime;
  final ValueChanged<String?> onOpen;
  final VoidCallback onHosts;
  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  String _query = '';
  bool _refreshing = false;
  Future<void> _refresh() async {
    if (_refreshing || !widget.runtime.isConnected) return;
    setState(() => _refreshing = true);
    try {
      await widget.runtime.refreshTasks(resetPages: true);
    } catch (e) {
      if (mounted) _error(e);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _error(Object e) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  Future<void> _edit([RemoteProject? project]) async {
    final draft = await showDialog<({String name, String cwd})>(
      context: context,
      builder: (_) => _WorkspaceEditor(project: project),
    );
    if (draft == null) return;
    try {
      await widget.runtime.saveProject(
        projectId: project?.id,
        name: draft.name,
        cwd: draft.cwd,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.goWorkspaceUpdated)),
        );
      }
    } catch (e) {
      if (mounted) _error(e);
    }
  }

  Future<void> _remove(RemoteProject project) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.goConfirmRemoveWorkspace),
        content: Text(
          project.remoteId == null
              ? context.l10n.removeLocalProject(project.name)
              : context.l10n.removeSharedProject(project.name),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.remove),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await widget.runtime.deleteProject(project.id);
    } catch (e) {
      if (mounted) _error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l = context.l10n;
    final projects = widget.runtime.projects
        .where((p) => '${p.name} ${p.cwd}'.toLowerCase().contains(_query))
        .toList();
    return LayoutBuilder(
      builder: (context, viewport) {
        final compact = viewport.maxHeight < 450;
        return Column(
          children: [
            if (!compact)
              GoSectionHeading(
                l.navWorkspaces,
                subtitle: l.goWorkspaceHint,
                trailing: IconButton.filled(
                  tooltip: l.addProject,
                  onPressed: widget.runtime.isConnected ? _edit : null,
                  icon: const Icon(Icons.add),
                ),
              ),
            Padding(
              key: const ValueKey('workspace-search-field'),
              padding: EdgeInsets.fromLTRB(24, compact ? 12 : 0, 24, 16),
              child: TextField(
                decoration: InputDecoration(
                  hintText: l.searchWorkspace,
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Icon(
                    Icons.sort_rounded,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l.sortRecentModification,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l.refreshTasks,
                    onPressed: widget.runtime.isConnected && !_refreshing
                        ? _refresh
                        : null,
                    icon: _refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: projects.isEmpty
                  ? GoEmptyState(
                      icon: Icons.folder_copy_outlined,
                      title: _query.isNotEmpty
                          ? l.goNoWorkspacesMatch
                          : l.goNoWorkspaces,
                      description: _query.isNotEmpty
                          ? l.goNoWorkspacesMatchHint
                          : l.goNoWorkspacesHint,
                      action: widget.runtime.isConnected
                          ? null
                          : FilledButton.icon(
                              onPressed: widget.onHosts,
                              icon: const Icon(Icons.cable),
                              label: Text(l.connectHost),
                            ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: LayoutBuilder(
                        builder: (context, constraints) =>
                            SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                              child: Wrap(
                                spacing: 14,
                                runSpacing: 14,
                                children: [
                                  for (final project in projects)
                                    SizedBox(
                                      width: constraints.maxWidth >= 780
                                          ? (constraints.maxWidth - 62) / 2
                                          : constraints.maxWidth - 48,
                                      child: _WorkspaceCard(
                                        project: project,
                                        onOpen: () => widget.onOpen(project.id),
                                        onEdit: widget.runtime.isConnected
                                            ? () => _edit(project)
                                            : null,
                                        onRemove:
                                            widget.runtime.isConnected &&
                                                !project.discovered
                                            ? () => _remove(project)
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _WorkspaceCard extends StatelessWidget {
  const _WorkspaceCard({
    required this.project,
    required this.onOpen,
    this.onEdit,
    this.onRemove,
  });
  final RemoteProject project;
  final VoidCallback onOpen;
  final VoidCallback? onEdit, onRemove;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(11),
                    decoration: BoxDecoration(
                      color: colors.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.folder_open_rounded,
                      color: colors.primary,
                      size: 24,
                    ),
                  ),
                  const Spacer(),
                  if (onEdit != null)
                    PopupMenuButton<String>(
                      tooltip: context.l10n.workspaceActions,
                      onSelected: (value) =>
                          value == 'edit' ? onEdit?.call() : onRemove?.call(),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'edit',
                          child: Text(
                            project.discovered
                                ? context.l10n.saveAsSharedProject
                                : context.l10n.editProject,
                          ),
                        ),
                        if (onRemove != null)
                          PopupMenuItem(
                            value: 'remove',
                            child: Text(context.l10n.remove),
                          ),
                      ],
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                project.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                project.cwd,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: colors.onSurfaceVariant,
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      project.updatedAt == null
                          ? context.l10n.goNoActivity
                          : DateFormat.MMMd(
                              Localizations.localeOf(context).toLanguageTag(),
                            ).add_Hm().format(project.updatedAt!.toLocal()),
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    size: 18,
                    color: colors.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceEditor extends StatefulWidget {
  const _WorkspaceEditor({this.project});
  final RemoteProject? project;
  @override
  State<_WorkspaceEditor> createState() => _WorkspaceEditorState();
}

class _WorkspaceEditorState extends State<_WorkspaceEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.project?.name);
  late final _path = TextEditingController(text: widget.project?.cwd);
  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.project == null
          ? context.l10n.addProject
          : context.l10n.editProject,
    ),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: context.l10n.goWorkspaceName,
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? context.l10n.requiredField
                    : null,
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _path,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: context.l10n.goWorkspacePath,
                  hintText: '/home/user/project',
                ),
                validator: (value) =>
                    value == null ||
                        !value.trim().startsWith('/') ||
                        RegExp(r'[\x00-\x1f]').hasMatch(value)
                    ? context.l10n.goAbsolutePath
                    : null,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, (
              name: _name.text.trim(),
              cwd: _path.text.trim(),
            ));
          }
        },
        child: Text(context.l10n.save),
      ),
    ],
  );
}
