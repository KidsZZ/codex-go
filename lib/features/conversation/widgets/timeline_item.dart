// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';

import 'activity_presentation.dart';
import 'process_disclosure.dart';
import 'code_block.dart';
import 'streaming_reply.dart';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/domain/conversations/message_attachments.dart';
import 'package:codex_go/features/conversation/widgets/codex_directive_content.dart';
import 'package:codex_go/features/conversation/widgets/markdown_content.dart';
import 'package:codex_go/features/conversation/widgets/inline_attachment_image.dart';
import 'package:codex_go/features/conversation/widgets/remote_file_actions.dart';
import 'package:codex_go/features/conversation/widgets/task_question_panel.dart';
import 'package:codex_go/features/conversation/widgets/task_question_content.dart';
import 'package:codex_go/shared/media/preview_browser.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/shared/formatting/local_time.dart';

typedef MessageTextCopier = Future<void> Function(String text);

Future<void> copyMessageText(String text) => copyMarkdownText(text);

class TimelineItemView extends StatelessWidget {
  const TimelineItemView({
    required this.item,
    this.copyText = copyMessageText,
    this.loadImage,
    this.onAnswerQuestions,
    this.onTurnAction,
    this.showActions = true,
    this.streaming = false,
    super.key,
  });

  final bool showActions, streaming;
  final TaskItem item;
  final MessageTextCopier copyText;
  final Future<Uint8List> Function(String)? loadImage;
  final TaskQuestionSubmitter? onAnswerQuestions;
  final VoidCallback? onTurnAction;

  @override
  Widget build(BuildContext context) {
    return ImagePreviewScope(
      loadImage: loadImage,
      child: switch (item.kind) {
        TaskItemKind.user || TaskItemKind.agent => _Message(
          item: item,
          copyText: copyText,
          loadImage: loadImage,
          onAnswerQuestions: onAnswerQuestions,
          onTurnAction: onTurnAction,
          showActions: showActions,
          streaming: streaming,
        ),
        _ => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ActivityRow(item: item),
            for (final attachment in item.attachments)
              _AttachmentCard(
                attachment: attachment,
                copyText: copyText,
                loadImage: loadImage,
              ),
          ],
        ),
      },
    );
  }
}

class TimelineActivityGroup extends StatelessWidget {
  const TimelineActivityGroup({
    required this.items,
    this.loadImage,
    this.onOpenSubagent,
    super.key,
  });
  final List<TaskItem> items;
  final Future<Uint8List> Function(String)? loadImage;
  final ValueChanged<SubagentReference>? onOpenSubagent;
  @override
  Widget build(BuildContext context) {
    final targets = <String, SubagentReference>{};
    for (final item in items) {
      for (final agent in item.subagents) {
        final previous = targets[agent.threadId];
        targets[agent.threadId] = SubagentReference(
          agent.threadId,
          path: agent.path ?? previous?.path,
          status: agent.status ?? previous?.status,
        );
      }
    }
    final failed = items.any(activityFailed);
    return ImagePreviewScope(
      loadImage: loadImage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 少量动作直接显示，连续过程才分组。错误不藏在默认收起的组里。
          if (items.length < 3 || failed)
            for (final item in items)
              ActivityRow(key: ValueKey(item.id), item: item)
          else
            ProcessDisclosure(
              key: PageStorageKey('actions:${items.first.id}'),
              icon: Icons.pending_actions_rounded,
              label: context.l10n.workEvents(items.length),
              detail: activitySummary(context, items),
              trailing:
                  items.any(
                    (item) => const {
                      'inProgress',
                      'running',
                      'in_progress',
                    }.contains(item.status),
                  )
                  ? const SizedBox.square(
                      dimension: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  : null,
              child: ProcessDetailViewport(
                itemCount: items.length,
                itemBuilder: (_, index) => ActivityRow(
                  key: ValueKey(items[index].id),
                  item: items[index],
                ),
              ),
            ),
          if (targets.isNotEmpty)
            _SubagentLinks(
              agents: targets.values.toList(growable: false),
              onOpen: onOpenSubagent,
            ),
          for (final item in items)
            for (final attachment in item.attachments)
              _AttachmentCard(
                attachment: attachment,
                copyText: copyMessageText,
                loadImage: loadImage,
              ),
        ],
      ),
    );
  }
}

String _subagentLabel(BuildContext context, SubagentReference agent) {
  final status = switch (agent.status) {
    'pendingInit' => context.l10n.starting,
    'running' => context.l10n.running,
    'completed' => context.l10n.completed,
    'interrupted' => context.l10n.interrupted,
    'errored' => context.l10n.failed,
    'shutdown' => context.l10n.closed,
    'notFound' => context.l10n.unavailable,
    final status => status,
  };
  return status == null ? agent.label : '${agent.label} · $status';
}

class _SubagentLinks extends StatelessWidget {
  const _SubagentLinks({required this.agents, this.onOpen});

  final List<SubagentReference> agents;
  final ValueChanged<SubagentReference>? onOpen;

  Widget _tile(BuildContext context, SubagentReference agent) => ListTile(
    dense: true,
    visualDensity: VisualDensity.compact,
    leading: const Icon(Icons.account_tree_outlined, size: 20),
    title: Text(
      _subagentLabel(context, agent),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    trailing: onOpen == null ? null : const Icon(Icons.chevron_right),
    onTap: onOpen == null ? null : () => onOpen!(agent),
  );

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 3),
      clipBehavior: Clip.antiAlias,
      child: agents.length <= 3
          ? Column(
              children: [for (final agent in agents) _tile(context, agent)],
            )
          : ProcessDetailViewport(
              viewportKey: const Key('subagent-viewport'),
              maxHeight: 176,
              itemCount: agents.length,
              itemBuilder: (_, index) => _tile(context, agents[index]),
            ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.item,
    required this.copyText,
    this.loadImage,
    this.onAnswerQuestions,
    this.onTurnAction,
    this.showActions = true,
    this.streaming = false,
  });
  final TaskItem item;
  final MessageTextCopier copyText;
  final Future<Uint8List> Function(String)? loadImage;
  final TaskQuestionSubmitter? onAnswerQuestions;
  final VoidCallback? onTurnAction;
  final bool showActions, streaming;

  void _menu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_copyableMessageText(item).isNotEmpty)
              ListTile(
                leading: const Icon(Icons.copy_all_outlined),
                title: Text(context.l10n.copyMessage),
                onTap: () {
                  Navigator.pop(sheet);
                  unawaited(
                    _copyMessage(context, _copyableMessageText(item), copyText),
                  );
                },
              ),
            if (_copyableMessageText(item).isNotEmpty)
              ListTile(
                leading: const Icon(Icons.text_fields_rounded),
                title: Text(context.l10n.chatSelectText),
                onTap: () {
                  Navigator.pop(sheet);
                  showDialog<void>(
                    context: context,
                    builder: (dialog) => AlertDialog(
                      title: Text(context.l10n.chatSelectText),
                      content: SizedBox(
                        width: double.maxFinite,
                        child: SingleChildScrollView(
                          child: SelectableText(_copyableMessageText(item)),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: Text(context.l10n.close),
                        ),
                      ],
                    ),
                  );
                },
              ),
            if (onTurnAction != null)
              ListTile(
                leading: const Icon(Icons.more_horiz),
                title: Text(context.l10n.turnActions),
                onTap: () {
                  Navigator.pop(sheet);
                  onTurnAction!();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = item.kind == TaskItemKind.user;
    final colors = Theme.of(context).colorScheme;
    final sending = user && item.status == 'sending';
    final time = item.messageTime;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final content = parseAttachmentMessage(item.text, item.attachments);
    final agentText = questionMessageBody(item.text, item.questions);
    final timestamp = time == null
        ? null
        : Tooltip(
            message: formatFullLocalTime(time, locale),
            child: Text(
              formatLocalTime(time, locale),
              style: TextStyle(
                fontSize: 10.5,
                height: 1.4,
                color: colors.onSurfaceVariant.withValues(alpha: .7),
              ),
            ),
          );
    final footer = Wrap(
      spacing: 8,
      runSpacing: 4,
      alignment: user ? WrapAlignment.end : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (timestamp != null) timestamp,
        if (sending)
          const SizedBox.square(
            key: Key('pending-user-progress'),
            dimension: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        if (!user && showActions) ...[
          if (_copyableMessageText(item).isNotEmpty)
            _MessageAction(
              tooltip: context.l10n.copyMessage,
              icon: Icons.copy_all_outlined,
              onPressed: () => unawaited(
                _copyMessage(context, _copyableMessageText(item), copyText),
              ),
            ),
          if (onTurnAction != null)
            _MessageAction(
              tooltip: context.l10n.turnActions,
              icon: Icons.more_horiz,
              onPressed: onTurnAction!,
            ),
        ],
      ],
    );
    if (user) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
          return Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * (scale > 1.3 ? .92 : .84),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 附件拥有自己的预览和下载操作，不挤进文字气泡。
                  for (final attachment in content.attachments)
                    _AttachmentCard(
                      attachment: attachment,
                      copyText: copyText,
                      loadImage: loadImage,
                    ),
                  if (content.text.trim().isNotEmpty)
                    Semantics(
                      onLongPress: () => _menu(context),
                      child: GestureDetector(
                        onLongPress: () => _menu(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: Color.alphaBlend(
                              colors.primary.withValues(alpha: .055),
                              colors.surfaceContainerLow,
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: SelectionContainer.disabled(
                            child: MarkdownContent(
                              text: content.text,
                              selectable: false,
                              copyText: copyText,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (time != null || sending)
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 4),
                      child: footer,
                    ),
                  // 纯附件消息也提供回合操作入口。
                  if (content.text.trim().isEmpty && onTurnAction != null)
                    _MessageAction(
                      tooltip: context.l10n.turnActions,
                      icon: Icons.more_horiz,
                      onPressed: onTurnAction!,
                    ),
                ],
              ),
            ),
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final attachment in item.attachments)
          _AttachmentCard(
            attachment: attachment,
            copyText: copyText,
            loadImage: loadImage,
          ),
        if (agentText.trim().isNotEmpty)
          StreamingReply(
            key: ValueKey('reply:${item.id}'),
            text: agentText,
            streaming: streaming,
            builder: (text) =>
                CodexDirectiveContent(text: text, copyText: copyText),
          ),
        if (item.questions.isNotEmpty)
          TaskQuestionPanel(
            key: ValueKey('questions-${item.id}'),
            questions: item.questions,
            onSubmit: onAnswerQuestions,
          ),
        if (time != null || showActions)
          Padding(padding: const EdgeInsets.only(top: 5), child: footer),
      ],
    );
  }
}

class _MessageAction extends StatelessWidget {
  const _MessageAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size.square(32),
      padding: const EdgeInsets.all(6),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: Icon(
      icon,
      size: 16,
      color: Theme.of(context).colorScheme.onSurfaceVariant
          .withValues(alpha: .7),
    ),
  );
}

class _AttachmentCard extends StatelessWidget {
  const _AttachmentCard({
    required this.attachment,
    required this.copyText,
    this.loadImage,
  });

  final MessageAttachment attachment;
  final MessageTextCopier copyText;
  final Future<Uint8List> Function(String)? loadImage;

  @override
  Widget build(BuildContext context) {
    final thisContext = context;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachment.isVideo && attachment.path.startsWith('/'))
            RemoteVideoPreview(path: attachment.path, label: attachment.label),
          if (attachment.isImage &&
              ((attachment.path.startsWith('/') && loadImage != null) ||
                  attachment.path.startsWith('data:image/')))
            InlineAttachmentImage(
              key: ValueKey(attachment.path),
              attachment: attachment,
              loadImage: loadImage,
            ),
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(
              attachment.isImage
                  ? Icons.image_outlined
                  : attachment.isVideo
                  ? Icons.videocam_outlined
                  : Icons.insert_drive_file_outlined,
            ),
            title: Text(
              attachment.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              attachment.isImage
                  ? context.l10n.imageAttachment
                  : attachment.isVideo
                  ? context.l10n.videoAttachment
                  : context.l10n.fileAttachment,
            ),
            trailing: const Icon(Icons.info_outline, size: 18),
            onTap: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: Text(
                  attachment.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                content: SingleChildScrollView(
                  child: SelectableText(
                    attachment.path.isEmpty
                        ? context
                              .l10n
                              .imageLocationIsNotAvailableInThisConversation
                        : attachment.path.startsWith('data:')
                        ? context.l10n.embeddedImage
                        : attachment.path,
                  ),
                ),
                actions: [
                  if (attachment.path.startsWith('/') &&
                      RemoteFileActions.maybeOf(thisContext) != null)
                    TextButton(
                      onPressed: () => unawaited(
                        showRemoteFileDownload(thisContext, attachment.path),
                      ),
                      child: Text(context.l10n.download),
                    ),
                  if (attachment.isImage &&
                      ((attachment.path.startsWith('/') && loadImage != null) ||
                          attachment.path.startsWith('data:image/')))
                    TextButton(
                      onPressed: () async {
                        final bytes = await loadAttachmentPreview(
                          attachment,
                          loadImage,
                        );
                        if (!context.mounted) return;
                        if (bytes == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                context
                                    .l10n
                                    .couldNotLoadImageReconnectAndTryAgain,
                              ),
                            ),
                          );
                          return;
                        }
                        await showImagePreview(
                          context,
                          bytes,
                          label: attachment.label,
                        );
                      },
                      child: Text(context.l10n.previewImage),
                    ),
                  if (attachment.path.isNotEmpty &&
                      !attachment.path.startsWith('data:'))
                    TextButton(
                      onPressed: () => unawaited(
                        _copyMessage(context, attachment.path, copyText),
                      ),
                      child: Text(context.l10n.copyPath),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(context.l10n.close),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _copyableMessageText(TaskItem item) {
  if (item.kind != TaskItemKind.agent) return item.text;
  final parsed = parseCodexDirectiveContent(item.text);
  return parsed.directives.isEmpty ? item.text : parsed.markdown.trimRight();
}

Future<void> _copyMessage(
  BuildContext context,
  String text,
  MessageTextCopier copyText,
) async {
  try {
    await copyText(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.messageCopied)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.l10n.couldNotCopyMessage)));
  }
}

/// 每个动作只占一行；展开后能选择、复制完整命令和输出。
class ActivityRow extends StatelessWidget {
  const ActivityRow({required this.item, super.key});
  final TaskItem item;
  @override
  Widget build(BuildContext context) {
    final failed = activityFailed(item);
    final running = const {
      'inProgress',
      'running',
      'in_progress',
    }.contains(item.status);
    final time = item.messageTime;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final pieces = <String>[
      if (item.title?.trim().isNotEmpty == true) item.title!,
      if (item.text.trim().isNotEmpty && item.text != item.title) item.text,
      if (item.detail?.trim().isNotEmpty == true && item.detail != item.text)
        item.detail!,
    ];
    final body = pieces.join('\n\n');
    return ProcessDisclosure(
      key: PageStorageKey('action:${item.id}'),
      icon: activityIcon(item),
      label: activityLabel(context, item),
      detail: activityDetail(item),
      color: activityColor(context, item),
      initiallyExpanded: failed,
      trailing: failed
          ? Tooltip(
              message: context.l10n.activityStatus(item.status!),
              child: Icon(
                Icons.error_outline,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              ),
            )
          : running
          ? const SizedBox.square(
              dimension: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (time != null || item.status != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                [
                  if (time != null) formatFullLocalTime(time, locale),
                  if (item.status != null)
                    context.l10n.activityStatus(item.status!),
                ].join(' · '),
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (body.isNotEmpty)
            ProcessDetailViewport(
              itemCount: 1,
              itemBuilder: (_, index) =>
                  item.kind == TaskItemKind.reasoning ||
                      item.activityKind == TaskActivityKind.plan
                  ? MarkdownContent(text: body)
                  : ConversationCodeBlock(
                      code: body,
                      language: item.kind == TaskItemKind.file ? 'diff' : null,
                    ),
            ),
        ],
      ),
    );
  }
}
