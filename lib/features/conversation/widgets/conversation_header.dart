import 'package:flutter/material.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/l10n/strings.dart';

/// 顶栏只展示对话身份和当下状态，完整路径与主机信息按需查看。
class ConversationHeader extends StatelessWidget {
  const ConversationHeader({
    required this.task,
    required this.connected,
    required this.waiting,
    required this.title,
    required this.details,
    this.onBack,
    this.onNew,
    this.trailing,
    super.key,
  });
  final TaskRecord task;
  final bool connected, waiting;
  final String title, details;
  final VoidCallback? onBack, onNew;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final folder = task.cwd
        .split('/')
        .where((part) => part.isNotEmpty)
        .lastOrNull;
    final active =
        task.status == TaskStatus.running || task.status == TaskStatus.queued;
    final status = !connected
        ? context.l10n.offline
        : waiting
        ? context.l10n.chatAwaitingYou
        : active
        ? context.l10n.running
        : context.l10n.connected;
    final tone = !connected
        ? colors.outline
        : waiting
        ? colors.tertiary
        : active
        ? colors.primary
        : colors.secondary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              tooltip: context.l10n.goBackToList,
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
            ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(title),
                  content: SelectableText(details),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        MaterialLocalizations.of(context).closeButtonLabel,
                      ),
                    ),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Icon(Icons.circle, size: 6, color: tone),
                        const SizedBox(width: 5),
                        Text(
                          status,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.3,
                            color: tone,
                          ),
                        ),
                        if (folder != null) ...[
                          const SizedBox(width: 7),
                          Flexible(
                            child: Text(
                              folder,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onNew != null)
            IconButton(
              onPressed: onNew,
              tooltip: context.l10n.newChat,
              icon: const Icon(Icons.edit_square, size: 20),
            ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
