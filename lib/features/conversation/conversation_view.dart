import 'package:codex_go/features/conversation/conversation_welcome.dart';

// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/infrastructure/platform/attachments.dart';
import 'package:codex_go/infrastructure/codex/codex_remote_api.dart';
import 'package:codex_go/domain/conversations/task_message_queue.dart';
import 'package:codex_go/domain/conversations/task_reducer.dart';
import 'package:codex_go/domain/conversations/task_draft.dart';
import 'package:codex_go/features/conversation/composer_completion.dart';
import 'package:codex_go/features/conversation/task_timeline_render_cache.dart';
import 'package:codex_go/features/conversation/timeline_entries.dart';
import 'package:codex_go/features/conversation/turn_settings_picker.dart';
import 'package:codex_go/features/conversation/widgets/timeline_item.dart';
import 'package:codex_go/features/conversation/widgets/turn_process.dart';
import 'package:codex_go/features/conversation/widgets/user_input_panel.dart';
import 'package:codex_go/features/conversation/widgets/remote_file_actions.dart';
import 'package:codex_go/features/conversation/widgets/task_question_panel.dart';
import 'package:codex_go/features/conversation/conversation_manager.dart';
import 'package:codex_go/shared/media/preview_browser.dart';
import 'package:codex_go/features/conversation/widgets/inline_attachment_image.dart';
import 'package:codex_go/features/conversation/permission_picker.dart';
import 'package:codex_go/l10n/strings.dart';

bool isTaskComposerInputEnabled({
  required TaskRecord task,
  required bool connected,
}) => true;

bool isTaskComposerSendEnabled({
  required TaskRecord task,
  required bool connected,
  required bool sending,
  bool attachmentsReady = true,
}) => !sending && attachmentsReady;

bool isTaskComposerEnabled({
  required TaskRecord task,
  required bool connected,
  required bool sending,
}) => isTaskComposerSendEnabled(
  task: task,
  connected: connected,
  sending: sending,
);

String restoreComposerDraft({
  required String currentText,
  required String submittedText,
}) => currentText.isEmpty ? submittedText : currentText;

List<QueuedTaskMessage> visibleQueuedMessages(
  List<QueuedTaskMessage> messages,
  Set<String> inFlightMessageIds,
) => messages
    .where((message) => !inFlightMessageIds.contains(message.id))
    .toList(growable: false);

class ConversationView extends StatefulWidget {
  const ConversationView({
    required this.controller,
    required this.task,
    this.newConversation = false,
    this.projectId,
    this.onOpenNavigation,
    this.onNewConversation,
    required this.onConnect,
    this.showBackButton = true,
    super.key,
  });

  final CodexRuntime controller;
  final TaskRecord task;
  final bool newConversation;
  final String? projectId;
  final VoidCallback? onOpenNavigation;
  final VoidCallback? onNewConversation;
  final VoidCallback onConnect;
  final bool showBackButton;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

final class _SectorProgressPainter extends CustomPainter {
  const _SectorProgressPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final rect = Offset.zero & size;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * progress.clamp(0.0, 1.0),
      true,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_SectorProgressPainter oldDelegate) =>
      progress != oldDelegate.progress || color != oldDelegate.color;
}

class _ConversationViewState extends State<ConversationView> {
  late TaskDraft _draft;
  TextEditingController get _composer => _draft.composer;
  final _composerFocus = FocusNode();
  final _timelineCache = TaskTimelineRenderCache<Widget>();
  bool get _sending => _draft.sending;
  set _sending(bool value) => _draft.sending = value;
  TaskSendMode get _sendMode => _draft.sendMode;
  set _sendMode(TaskSendMode value) => _draft.sendMode = value;
  String? _presentationSignature;
  var _commandBusy = false;
  var _queueActionBusy = false;
  var _lastCommandSucceeded = true;
  RemoteSkill? get _selectedSkill => _draft.skill;
  set _selectedSkill(RemoteSkill? value) => _draft.skill = value;
  TurnSettings get _turnSettings => _draft.settings;
  List<RemoteSkill>? _availableSkills;
  List<ComposerCompletion> _completions = const [];
  var _loadingSkills = false;
  bool get _pickingAttachment => _draft.picking;
  List<AttachmentTransfer> get _attachments => _draft.attachments;
  final Set<String> _answeredQuestionItemIds = {};

  @override
  void initState() {
    super.initState();
    _bindDraft();
    _requestTurnPresentation();
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _requestTurnPresentation();
    final next = widget.controller.draftForTask(widget.task.id);
    if (!identical(next, _draft)) {
      _unbindDraft();
      _bindDraft();
      _timelineCache.clear();
      _availableSkills = null;
      _completions = const [];
      _commandBusy = false;
      _queueActionBusy = false;
      _answeredQuestionItemIds.clear();
    }
  }

  void _requestTurnPresentation() {
    final items = widget.task.items;
    if (items.isEmpty ||
        !items.any((i) => i.turnId != null && i.turn == null)) {
      return;
    }
    final signature =
        '${widget.task.id}:${items.first.id}:${items.last.id}:${items.length}';
    if (_presentationSignature == signature) return;
    _presentationSignature = signature;
    unawaited(
      widget.controller.loadTurnPresentationForTask(widget.task.id, items),
    );
  }

  void _bindDraft() {
    _draft = widget.controller.draftForTask(widget.task.id);
    _composer.addListener(_updateCompletions);
    _draft.addListener(_draftChanged);
  }

  void _unbindDraft() {
    _composer.removeListener(_updateCompletions);
    _draft.removeListener(_draftChanged);
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _unbindDraft();
    _composerFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, viewport) {
      final size = MediaQuery.sizeOf(context);
      final task = widget.task;
      final draft = _draft;
      final approvals = widget.controller.approvals
          .where((approval) => approval.threadId == task.id)
          .toList(growable: false);
      final queuedMessages = visibleQueuedMessages(
        widget.controller.queuedMessagesForTask(task.id),
        widget.controller.inFlightQueuedMessageIdsForTask(task.id),
      );
      final timelineState = TaskTimelineRenderState(
        items: task.items,
        owner: widget.controller,
        loading: widget.controller.isTaskDetailLoading(task.id),
        error: widget.controller.taskDetailError(task.id),
        hasOlder:
            widget.controller.isConnected &&
            widget.controller.hasOlderTaskContext,
        loadingOlder: widget.controller.isLoadingOlderTaskContext,
        olderError: widget.controller.olderTaskContextError,
      );
      final timeline = _timelineCache.resolve(
        timelineState,
        () => TaskTimeline(
          loadImage: widget.controller.loadAttachmentImage,
          items: timelineState.items,
          loading: timelineState.loading,
          error: timelineState.error,
          onRetry: widget.controller.retrySelectedTaskDetails,
          hasOlder: timelineState.hasOlder,
          loadingOlder: timelineState.loadingOlder,
          olderError: timelineState.olderError,
          onLoadOlder: widget.controller.loadOlderSelectedTaskContext,
          answeredQuestionItemIds: _answeredQuestionItemIds,
          onAnswerQuestions: _answerTaskQuestions,
          onTurnAction: _turnAction,
          onOpenSubagent: (agent) {
            final hostId = widget.controller.selectedHostId;
            if (hostId != null) {
              _openSubagent(context, widget.controller, hostId, agent);
            }
          },
        ),
      );
      final content = Column(
        children: [
          _TaskHeader(
            newConversation: widget.newConversation,
            onOpenNavigation: widget.onOpenNavigation,
            showBackButton: widget.showBackButton,
            onNewConversation: widget.onNewConversation,
            controller: widget.controller,
            task: task,
            commandBusy: _commandBusy,
            onCommand: _handleCommand,
          ),
          if (!widget.controller.isConnected && !widget.newConversation)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Text(
                context.l10n.offlineCached,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          Expanded(
            child: RemoteFileActions(
              download: widget.controller.downloadFile,
              downloadWithProgress: widget.controller.downloadFile,
              previewVideo: Attachments.supported
                  ? widget.controller.previewVideo
                  : null,
              cancelDownload: widget.controller.cancelDownload,
              child: widget.newConversation ? _welcome(context) : timeline,
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.max(100, (viewport.maxHeight - 80) * .64),
            ),
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.controller.userInputRequests.any(
                    (r) => r.threadId == task.id,
                  ))
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            (MediaQuery.sizeOf(context).height -
                                MediaQuery.viewInsetsOf(context).bottom) *
                            0.4,
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final request
                                in widget.controller.userInputRequests.where(
                                  (r) => r.threadId == task.id,
                                ))
                              UserInputPanel(
                                key: ObjectKey(request),
                                request: request,
                                onAnswer: (answers) => widget.controller
                                    .answerUserInput(request, answers),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (approvals.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: size.height * .3),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final approval in approvals)
                              _ApprovalBar(
                                approval: approval,
                                enabled: widget.controller.isConnected,
                                onDecision: (decision) => widget.controller
                                    .answerApproval(approval, decision),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (queuedMessages.isNotEmpty)
                    QueuedMessagePanel(
                      messages: queuedMessages,
                      enabled:
                          widget.controller.isConnected && !_queueActionBusy,
                      onSteer: _steerQueuedMessage,
                      onRemove: _removeQueuedMessage,
                      deliveryState: widget.controller.deliveryState,
                      onRetry: _retryQueuedMessage,
                    ),
                  if (widget.controller.selectedGoal case final goal?)
                    ListTile(
                      dense: true,
                      visualDensity: const VisualDensity(vertical: -4),
                      leading: const Icon(Icons.flag_outlined, size: 18),
                      title: Text(
                        goal.objective,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${context.l10n.activityStatus(goal.status)} · ${goal.tokensUsed}'
                        '${goal.tokenBudget == null ? '' : ' / ${goal.tokenBudget}'} tokens',
                      ),
                      onTap: widget.controller.isConnected && !_commandBusy
                          ? _editGoal
                          : null,
                      trailing: goal.status != 'complete'
                          ? IconButton(
                              tooltip: goal.status == 'active'
                                  ? context.l10n.pauseGoal
                                  : context.l10n.resumeGoal,
                              icon: Icon(
                                goal.status == 'active'
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                              onPressed:
                                  widget.controller.isConnected && !_commandBusy
                                  ? () => _runCommand(
                                      () => widget.controller.setGoalPaused(
                                        goal.status == 'active',
                                      ),
                                    )
                                  : null,
                            )
                          : null,
                    ),
                  if (_selectedSkill case final skill?)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                        child: InputChip(
                          avatar: const Icon(Icons.auto_awesome, size: 18),
                          label: Text('\$${skill.name}'),
                          tooltip: skill.description.isEmpty
                              ? null
                              : skill.description,
                          onDeleted: _sending
                              ? null
                              : () => setState(() => _selectedSkill = null),
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        PermissionPicker(
                          value: draft.permissionMode,
                          compact: true,
                          enabled: !_sending,
                          onChanged: (value) {
                            draft.permissionMode = value;
                            draft.changed();
                          },
                        ),
                        Expanded(
                          child: TurnSettingsPicker(
                            accountUsage: widget.controller.accountUsage,
                            models: widget.controller.models,
                            value: resolveTurnSettings(
                              widget.controller.models,
                              _turnSettings,
                              model: task.model,
                              effort: task.reasoningEffort,
                              useCatalogDefault: widget.newConversation,
                            ),
                            useCatalogDefault: widget.newConversation,
                            inheritedServiceTier: task.serviceTier,
                            enabled: !_sending,
                            onChanged: (value) {
                              if (draft.disposed) return;
                              draft.settings = value;
                              draft.changed();
                            },
                          ),
                        ),
                        SendModePicker(
                          value: _sendMode,
                          enabled: !_sending,
                          onChanged: (mode) {
                            setState(() => _sendMode = mode);
                            _draft.changed();
                          },
                          compact: true,
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (_attachments.isNotEmpty)
                    SizedBox(
                      height: 52,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final attachment in _attachments)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _attachmentChip(attachment),
                            ),
                        ],
                      ),
                    ),
                  if (_sending || _pickingAttachment)
                    const LinearProgressIndicator(minHeight: 2),
                  _Composer(
                    running: task.status == TaskStatus.running,
                    connected: widget.controller.isConnected,
                    onStop: () => _handleCommand(TaskCommand.interrupt),
                    onSendOptions: _chooseSendAction,
                    controller: _composer,
                    focusNode: _composerFocus,
                    inputEnabled: isTaskComposerInputEnabled(
                      task: task,
                      connected: widget.controller.isConnected,
                    ),
                    sendEnabled: isTaskComposerSendEnabled(
                      task: task,
                      connected: widget.controller.isConnected,
                      sending: _sending,
                      attachmentsReady: _attachments.every(
                        (file) => file.ready,
                      ),
                    ),
                    completions: _completions,
                    loadingCompletions: _loadingSkills,
                    onCompletion: _selectCompletion,
                    onSend:
                        widget.newConversation && !widget.controller.isConnected
                        ? widget.onConnect
                        : _send,
                    sendMode: _sendMode,
                    onAttach:
                        Attachments.supported &&
                            !_sending &&
                            !_pickingAttachment
                        ? _pickAttachment
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ],
      );
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: content,
        ),
      );
    },
  );

  Widget _welcome(BuildContext context) => ConversationWelcome(
    connected: widget.controller.isConnected,
    cwd: widget.projectId == null ? _draft.cwd : widget.task.cwd,
    canEditCwd: widget.projectId == null,
    onConnect: widget.onConnect,
    onSuggestion: (prompt) {
      _composer.text = prompt;
      _composerFocus.requestFocus();
    },
    onCwdChanged: (value) {
      _draft.cwd = value;
      _draft.changed();
    },
  );

  Future<void> _chooseSendAction() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(context.l10n.sendModeTitle),
              subtitle: Text(context.l10n.queueDescription),
            ),
            if (widget.task.status == TaskStatus.running)
              ListTile(
                leading: const Icon(Icons.redo),
                title: Text(context.l10n.steerCurrentTurn),
                onTap: () => Navigator.pop(context, 'steer'),
              ),
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(context.l10n.queueNextTurn),
              onTap: () => Navigator.pop(context, 'queue'),
            ),
            if (widget.task.status == TaskStatus.running)
              ListTile(
                leading: const Icon(Icons.stop_circle_outlined),
                title: Text(context.l10n.interruptAndSend),
                onTap: () => Navigator.pop(context, 'interrupt'),
              ),
            ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(context.l10n.sendAutomatically),
              onTap: () => Navigator.pop(context, 'auto'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    setState(
      () => _sendMode = action == 'queue'
          ? TaskSendMode.queue
          : action == 'steer'
          ? TaskSendMode.steer
          : TaskSendMode.auto,
    );
    _draft.changed();
    await _send(interruptFirst: action == 'interrupt');
  }

  Future<void> _send({bool interruptFirst = false}) async {
    if (_sending || _commandBusy) return;
    final draft = _draft;
    final controller = widget.controller;
    final submittedText = _composer.text;
    final text = submittedText.trim();
    final localCommand = switch (text.toLowerCase()) {
      '/mcp' => TaskCommand.mcp,
      '/permissions' => TaskCommand.permissions,
      '/skills' => TaskCommand.skills,
      '/goal' => TaskCommand.goal,
      '/compact' => TaskCommand.compact,
      '/interrupt' => TaskCommand.interrupt,
      _ => null,
    };
    if (localCommand != null) {
      _lastCommandSucceeded = true;
      await _handleCommand(localCommand);
      if (mounted &&
          !draft.disposed &&
          identical(_draft, draft) &&
          _lastCommandSucceeded &&
          _composer.text == submittedText) {
        _composer.clear();
      }
      return;
    }
    if (text.isEmpty && _attachments.isEmpty) return;
    if (_attachments.any((attachment) => !attachment.ready)) {
      _showError(
        _attachments.any(
              (attachment) => attachment.state == AttachmentState.failed,
            )
            ? context.l10n.retryFailedAttachmentsBeforeSending
            : context.l10n.waitForAttachmentsToFinishUploading,
      );
      return;
    }
    final submittedAttachments = List<AttachmentTransfer>.of(_attachments);
    final submittedSkill = _selectedSkill;
    final settings = resolveTurnSettings(
      widget.controller.models,
      _turnSettings,
      model: widget.task.model,
      effort: widget.task.reasoningEffort,
      useCatalogDefault: widget.newConversation,
    );
    setState(() {
      _sending = true;
      _selectedSkill = null;
      _completions = const [];
      draft.attachments = [];
    });
    _composer.clear();
    try {
      if (interruptFirst) await controller.interruptTaskAndWait(widget.task.id);
      if (widget.newConversation) {
        await controller.startNewTask(
          cwd: widget.task.cwd.isNotEmpty ? widget.task.cwd : draft.cwd,
          projectId: widget.projectId,
          prompt: text,
          model: settings.model,
          effort: settings.effort,
          serviceTier: settings.serviceTier,
          permissionMode: draft.permissionMode,
          skill: submittedSkill,
          attachments: submittedAttachments
              .map((file) => file.remote!)
              .toList(),
        );
        await Attachments.releaseAll(
          submittedAttachments.map((file) => file.local),
        );
        return;
      }
      final disposition = await controller.sendPrompt(
        text,
        taskId: widget.task.id,
        mode: _sendMode,
        skill: submittedSkill,
        model: settings.model,
        effort: settings.effort,
        serviceTier: settings.serviceTier,
        permissionMode: draft.permissionMode,
        attachments: submittedAttachments.map((file) => file.remote!).toList(),
      );
      await Attachments.releaseAll(
        submittedAttachments.map((file) => file.local),
      );
      if (!mounted || !identical(_draft, draft)) return;
      if (disposition == TaskMessageDisposition.queued) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.messageQueuedForTheNextTurn)),
        );
      }
    } catch (exception) {
      await draft.restoreFailedSubmission(
        text: submittedText,
        files: submittedAttachments,
        submittedSkill: submittedSkill,
      );
      if (mounted && identical(_draft, draft)) _showError(exception);
    } finally {
      draft.sending = false;
      draft.changed();
    }
  }

  Future<void> _answerTaskQuestions(TaskItem item, List<String> answers) async {
    if (_answeredQuestionItemIds.contains(item.id)) return;
    final taskId = widget.task.id;
    final message = formatTaskQuestionAnswers(item.questions, answers);
    final settings = resolveTurnSettings(
      widget.controller.models,
      _turnSettings,
      model: widget.task.model,
      effort: widget.task.reasoningEffort,
      useCatalogDefault: widget.newConversation,
    );
    try {
      await widget.controller.sendPrompt(
        message,
        mode: TaskSendMode.auto,
        model: settings.model,
        effort: settings.effort,
        serviceTier: settings.serviceTier,
      );
      if (!mounted || widget.task.id != taskId) return;
      setState(() {
        _answeredQuestionItemIds.add(item.id);
        _timelineCache.clear();
      });
    } catch (error) {
      if (mounted && widget.task.id == taskId) _showError(error);
      rethrow;
    }
  }

  Future<void> _pickAttachment(bool image) async {
    final draft = _draft;
    if (draft.attachments.length >= Attachments.maxCount) {
      _showError(context.l10n.upTo4AttachmentsPerMessage);
      return;
    }
    draft.picking = true;
    draft.changed();
    LocalAttachment? picked;
    try {
      picked = await Attachments.pick(image: image);
      if (picked == null) return;
      draft.addAttachment(picked);
      picked = null;
      if (mounted && identical(_draft, draft)) _composerFocus.requestFocus();
    } catch (error) {
      if (picked != null) await Attachments.release(picked);
      if (mounted && identical(_draft, draft)) _showError(error);
    } finally {
      draft.picking = false;
      draft.changed();
    }
  }

  Widget _attachmentChip(AttachmentTransfer attachment) => AnimatedBuilder(
    animation: attachment,
    builder: (context, _) => _buildAttachmentChip(attachment),
  );

  Widget _buildAttachmentChip(AttachmentTransfer attachment) {
    final uploading = attachment.state == AttachmentState.uploading;
    final failed = attachment.state == AttachmentState.failed;
    final waiting = attachment.state == AttachmentState.waiting;
    final theme = Theme.of(context);
    final avatar = attachment.local.isImage
        ? Image.file(
            File(attachment.local.path),
            width: 32,
            height: 32,
            cacheWidth: 64,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
          )
        : Icon(
            attachment.local.isVideo
                ? Icons.videocam_outlined
                : Icons.insert_drive_file_outlined,
          );
    final message = waiting
        ? context.l10n.waitingForConnection
        : failed
        ? context.l10n.uploadFailedTapToResume
        : uploading
        ? context.l10n.uploadPercent(
            ((attachment.progress * 100).toStringAsFixed(0)).toString(),
          )
        : context.l10n.uploaded;
    return Tooltip(
      message: message,
      child: Material(
        elevation: uploading ? 7 : 0,
        shadowColor: theme.colorScheme.primary.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(24),
        child: InputChip(
          avatar: SizedBox.square(
            dimension: 32,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipOval(
                  child: Opacity(opacity: uploading ? 0.7 : 1, child: avatar),
                ),
                if (uploading)
                  CustomPaint(
                    painter: _SectorProgressPainter(
                      attachment.progress,
                      theme.colorScheme.primary.withValues(alpha: 0.5),
                    ),
                  ),
                if (failed)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.error.withValues(alpha: 0.82),
                    ),
                    child: Icon(
                      Icons.refresh,
                      size: 19,
                      color: theme.colorScheme.onError,
                    ),
                  ),
                if (attachment.ready)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: theme.colorScheme.primary,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 13,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          label: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Text(
              waiting
                  ? context.l10n.attachmentWaiting(
                      (attachment.local.name).toString(),
                    )
                  : attachment.local.name,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          onPressed: failed
              ? () => _retryAttachment(attachment)
              : attachment.local.isImage
              ? () => _previewAttachment(attachment.local)
              : attachment.local.isVideo
              ? () => _previewVideo(attachment.local)
              : null,
          onDeleted: () => _discardAttachment(attachment),
          deleteButtonTooltipMessage: context.l10n.removeAttachment,
        ),
      ),
    );
  }

  void _retryAttachment(AttachmentTransfer attachment) {
    unawaited(_draft.upload(attachment));
  }

  Future<void> _previewVideo(LocalAttachment attachment) async {
    try {
      await Attachments.channel.invokeMethod<bool>('playVideo', {
        'path': attachment.path,
        'name': attachment.name,
      });
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _discardAttachment(AttachmentTransfer attachment) {
    _draft.removeAttachment(attachment);
  }

  Future<void> _previewAttachment(LocalAttachment attachment) async {
    final bytes = await loadPreviewImage(
      Future.sync(() async {
        final file = File(attachment.path);
        if (await file.length() > Attachments.maxImagePreviewBytes) {
          throw StateError('Image preview is too large');
        }
        return file.readAsBytes();
      }),
    );
    if (!mounted) return;
    if (bytes == null) {
      _showError(context.l10n.cannotPreviewImageMaximum10Mib);
      return;
    }
    await showImagePreview(context, bytes, label: attachment.name);
  }

  Future<void> _steerQueuedMessage(String messageId) => _runQueueAction(
    () => widget.controller.steerQueuedMessage(widget.task.id, messageId),
  );

  Future<void> _removeQueuedMessage(String messageId) => _runQueueAction(
    () => widget.controller.removeQueuedMessage(widget.task.id, messageId),
  );

  Future<void> _retryQueuedMessage(String messageId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.sendThisMessageAgainQuestion),
        content: Text(context.l10n.checkTheLatestConversationFirstIfTheServer),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.sendAgain),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _runQueueAction(
        () => widget.controller.retryQueuedMessage(widget.task.id, messageId),
      );
    }
  }

  Future<void> _turnAction(TaskItem item) async {
    if (!widget.controller.isConnected || item.turnId == null || _commandBusy) {
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(context.l10n.answerInFork),
              onTap: () => Navigator.pop(context, 'retry'),
            ),
            if (item.kind == TaskItemKind.user)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(context.l10n.editInFork),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
            ListTile(
              leading: const Icon(Icons.fork_right),
              title: Text(context.l10n.forkThroughThisTurn),
              onTap: () => Navigator.pop(context, 'fork'),
            ),
            ListTile(
              leading: const Icon(Icons.undo),
              title: Text(context.l10n.revertFromThisTurn),
              onTap: () => Navigator.pop(context, 'revert'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'retry' || action == 'edit') {
      String? prompt;
      if (action == 'edit') {
        final editor = TextEditingController(text: item.text);
        prompt = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(context.l10n.editPrompt),
            content: SizedBox(
              width: 520,
              child: TextField(
                controller: editor,
                minLines: 3,
                maxLines: 10,
                autofocus: true,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: () {
                  if (editor.text.trim().isNotEmpty) {
                    Navigator.pop(context, editor.text.trim());
                  }
                },
                child: Text(context.l10n.forkAndSend),
              ),
            ],
          ),
        );
        // 对话框退出动画仍会读取 controller，下一帧后释放。
        WidgetsBinding.instance.addPostFrameCallback((_) => editor.dispose());
        if (prompt == null || !mounted) return;
      }
      await _runCommand(
        () => widget.controller.retryTurnInFork(item, editedPrompt: prompt),
      );
      return;
    }
    if (action == 'fork') {
      await _runCommand(
        () => widget.controller.forkSelectedTask(turnId: item.turnId),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.revertConversationQuestion),
        content: Text(context.l10n.removeThisTurnAndAllLaterTurnsFrom),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.revert),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runCommand(
        () => widget.controller.revertSelectedTask(item.turnId!),
      );
    }
  }

  Future<void> _runQueueAction(Future<void> Function() operation) async {
    if (_queueActionBusy) return;
    setState(() => _queueActionBusy = true);
    try {
      await operation();
    } catch (exception) {
      _showError(exception);
    } finally {
      if (mounted) setState(() => _queueActionBusy = false);
    }
  }

  Future<void> _handleCommand(TaskCommand command) async {
    switch (command) {
      case TaskCommand.mcp:
        await _showMcp();
      case TaskCommand.permissions:
        final value = await choosePermissionMode(
          context,
          _draft.permissionMode,
        );
        if (mounted && value != null) {
          _draft.permissionMode = value;
          _draft.changed();
        }
      case TaskCommand.skills:
        await _chooseSkill();
      case TaskCommand.goal:
        await _editGoal();
      case TaskCommand.compact:
        await _compactTask();
      case TaskCommand.interrupt:
        await _runCommand(widget.controller.interruptSelectedTask);
      case TaskCommand.rename:
        final name = await askTaskName(context, widget.task.title);
        if (name != null && mounted) {
          await _runCommand(
            () => widget.controller.renameTask(widget.task.id, name),
          );
        }
      case TaskCommand.pin:
        await _runCommand(
          () =>
              widget.controller.pinTask(widget.task.id, !widget.task.isPinned),
        );
      case TaskCommand.archive:
        if (await confirmArchive(context) && mounted) {
          await _runCommand(
            () => widget.controller.archiveTask(widget.task.id, true),
          );
        }
      case TaskCommand.fork:
        await _runCommand(() => widget.controller.forkSelectedTask());
    }
  }

  Future<void> _chooseSkill() async {
    final skills = await _runCommand(
      widget.controller.listSkillsForSelectedTask,
    );
    if (!mounted || skills == null) return;
    _availableSkills = skills;
    final selected = await showDialog<RemoteSkill>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.chooseASkill),
        content: SizedBox(
          width: 480,
          child: skills.isEmpty
              ? Text(context.l10n.noEnabledSkillsAreAvailableForThisProject)
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: skills.length,
                  itemBuilder: (context, index) {
                    final skill = skills[index];
                    return ListTile(
                      leading: const Icon(Icons.auto_awesome),
                      title: Text('\$${skill.name}'),
                      subtitle: skill.description.isEmpty
                          ? null
                          : Text(skill.description),
                      onTap: () => Navigator.pop(context, skill),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
    if (mounted && selected != null) {
      setState(() => _selectedSkill = selected);
    }
  }

  Future<void> _showMcp() async {
    final taskId = widget.task.id;
    final hostId = widget.controller.selectedHostId;
    final servers = await _runCommand(widget.controller.listMcpForSelectedTask);
    if (!mounted ||
        servers == null ||
        widget.task.id != taskId ||
        widget.controller.selectedHostId != hostId) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.mcpServersAndTools),
        content: SizedBox(
          width: 480,
          child: servers.isEmpty
              ? Text(context.l10n.noConfiguredMcpServersWereReturnedForThis)
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final server in servers)
                      ExpansionTile(
                        title: Text(server.name),
                        subtitle: Text(
                          '${server.authStatus} · ${server.tools.length} tools${server.error == null ? '' : '\n${server.error}'}',
                        ),
                        children: [
                          for (final tool in server.tools)
                            ListTile(
                              title: Text(tool),
                              trailing: const Icon(Icons.add_comment_outlined),
                              onTap: () {
                                if (!mounted ||
                                    widget.task.id != taskId ||
                                    widget.controller.selectedHostId !=
                                        hostId) {
                                  return;
                                }
                                final editor = _composer;
                                final current = editor.text.trim();
                                final prefix = current.toLowerCase() == '/mcp'
                                    ? ''
                                    : editor.text;
                                editor.text =
                                    '${prefix.isEmpty ? '' : '$prefix\n'}Use \$${server.name}, tool "$tool". ';
                                editor.selection = TextSelection.collapsed(
                                  offset: editor.text.length,
                                );
                                Navigator.pop(context);
                              },
                            ),
                        ],
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.close),
          ),
        ],
      ),
    );
  }

  void _updateCompletions() {
    if (!mounted) return;
    final cursor = _composer.selection.baseOffset;
    final completions = composerCompletions(
      _composer.text,
      cursor,
      _availableSkills ?? const [],
    );
    setState(() => _completions = completions.take(6).toList(growable: false));
    if (widget.controller.isConnected &&
        _availableSkills == null &&
        !_loadingSkills &&
        hasActiveSkillCompletion(_composer.text, cursor)) {
      _loadCompletionSkills();
    }
  }

  Future<void> _loadCompletionSkills() async {
    final taskId = widget.task.id;
    setState(() => _loadingSkills = true);
    try {
      final skills = await widget.controller.listSkillsForSelectedTask();
      if (!mounted || widget.task.id != taskId) return;
      _availableSkills = skills;
      _updateCompletions();
    } catch (exception) {
      _showError(exception);
    } finally {
      if (mounted) setState(() => _loadingSkills = false);
    }
  }

  Future<void> _selectCompletion(ComposerCompletion completion) async {
    final current =
        composerCompletions(
          _composer.text,
          _composer.selection.baseOffset,
          _availableSkills ?? const [],
        ).any(
          (candidate) =>
              candidate.kind == completion.kind &&
              candidate.value == completion.value,
        );
    if (!current) {
      setState(() => _completions = const []);
      return;
    }
    final edit = removeActiveCompletionToken(
      _composer.text,
      _composer.selection.baseOffset,
    );
    _composer.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.cursor),
    );
    setState(() => _completions = const []);
    if (completion.kind == ComposerCompletionKind.skill) {
      RemoteSkill? skill;
      for (final candidate in _availableSkills ?? const <RemoteSkill>[]) {
        if (r'$' + candidate.name == completion.value) {
          skill = candidate;
          break;
        }
      }
      if (skill != null) setState(() => _selectedSkill = skill);
      return;
    }
    final command = switch (completion.value) {
      '/goal' => TaskCommand.goal,
      '/compact' => TaskCommand.compact,
      '/skills' => TaskCommand.skills,
      '/mcp' => TaskCommand.mcp,
      '/permissions' => TaskCommand.permissions,
      '/interrupt' => TaskCommand.interrupt,
      _ => null,
    };
    if (command != null) await _handleCommand(command);
  }

  Future<void> _editGoal() async {
    final current = await _runCommand(widget.controller.readSelectedGoal);
    if (!mounted || !_lastCommandSucceeded) return;
    final objective = TextEditingController(text: current?.objective ?? '');
    final budget = TextEditingController(
      text: current?.tokenBudget?.toString() ?? '',
    );
    final action = await showDialog<_GoalAction>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.taskGoal),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: objective,
                autofocus: true,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: context.l10n.objective,
                  hintText: context.l10n.whatShouldThisTaskAccomplishQuestion,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: budget,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: context.l10n.tokenBudgetOptional,
                ),
              ),
              if (current != null) ...[
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${current.status} · ${current.tokensUsed} tokens · '
                    '${current.timeUsedSeconds}s',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (current != null)
            TextButton(
              onPressed: () => Navigator.pop(context, _GoalAction.clear),
              child: Text(context.l10n.clearGoal),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _GoalAction.save),
            child: Text(context.l10n.save),
          ),
        ],
      ),
    );
    if (!mounted || action == null) {
      objective.dispose();
      budget.dispose();
      return;
    }
    if (action == _GoalAction.clear) {
      await _runCommand(widget.controller.clearSelectedGoal);
    } else {
      final tokenBudget = budget.text.trim().isEmpty
          ? null
          : int.tryParse(budget.text.trim());
      if (budget.text.trim().isNotEmpty && tokenBudget == null) {
        _showError(context.l10n.tokenBudgetMustBeAWholeNumber);
      } else {
        await _runCommand(
          () => widget.controller.setSelectedGoal(
            objective: objective.text,
            tokenBudget: tokenBudget,
          ),
        );
      }
    }
    objective.dispose();
    budget.dispose();
  }

  Future<void> _compactTask() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.compactContextQuestion),
        content: Text(context.l10n.codexWillSummarizeOlderContextToMakeMore),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.compact),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _runCommand(widget.controller.compactSelectedTask);
    }
  }

  Future<T?> _runCommand<T>(Future<T> Function() operation) async {
    if (_commandBusy) return null;
    setState(() {
      _commandBusy = true;
      _lastCommandSucceeded = true;
    });
    try {
      return await operation();
    } catch (exception) {
      _lastCommandSucceeded = false;
      _showError(exception);
      return null;
    } finally {
      if (mounted) setState(() => _commandBusy = false);
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

enum _GoalAction { save, clear }

enum TaskCommand {
  mcp,
  permissions,
  skills,
  goal,
  compact,
  interrupt,
  rename,
  pin,
  archive,
  fork,
}

class QueuedMessagePanel extends StatelessWidget {
  const QueuedMessagePanel({
    required this.messages,
    required this.enabled,
    required this.onSteer,
    required this.onRemove,
    this.deliveryState,
    this.onRetry,
    super.key,
  });

  final List<QueuedTaskMessage> messages;
  final bool enabled;
  final Future<void> Function(String messageId) onSteer;
  final Future<void> Function(String messageId) onRemove;
  final String? Function(String id)? deliveryState;
  final Future<void> Function(String id)? onRetry;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule, size: 18),
              const SizedBox(width: 8),
              Text(
                context.l10n.queuedMessages((messages.length).toString()),
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: messages.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final message = messages[index];
                final state = deliveryState?.call(message.id);
                final needsReview = state == 'uncertain' || state == 'failed';
                final metadata = [
                  if (message.model case final model?) model,
                  if (message.effort case final effort?) effort,
                ].join(' / ');
                return Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              message.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (metadata.isNotEmpty)
                              Text(
                                metadata,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            if (needsReview)
                              Text(
                                state == 'uncertain'
                                    ? context
                                          .l10n
                                          .deliveryUnknownCheckConversationBeforeRetrying
                                    : context.l10n.notSentRetryOrRemove,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    ),
                    Tooltip(
                      message: context.l10n.steerQueuedMessage,
                      child: TextButton.icon(
                        onPressed: enabled
                            ? () async => needsReview
                                  ? onRetry?.call(message.id)
                                  : onSteer(message.id)
                            : null,
                        icon: const Icon(Icons.redo, size: 18),
                        label: Text(
                          needsReview ? context.l10n.retry : context.l10n.steer,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.removeQueuedMessage,
                      onPressed: () async => onRemove(message.id),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}

class TaskCommandMenu extends StatelessWidget {
  const TaskCommandMenu({
    required this.enabled,
    required this.onSelected,
    super.key,
  });

  final bool enabled;
  final ValueChanged<TaskCommand> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskCommand>(
    enabled: enabled,
    tooltip: context.l10n.taskCommands,
    onSelected: onSelected,
    itemBuilder: (context) => [
      PopupMenuItem(
        value: TaskCommand.mcp,
        child: Text(context.l10n.mcpServersAndTools),
      ),
      PopupMenuItem(
        value: TaskCommand.permissions,
        child: Text(context.l10n.permissionsNextNewTurn),
      ),
      PopupMenuItem(
        value: TaskCommand.rename,
        child: Text(context.l10n.rename),
      ),
      PopupMenuItem(value: TaskCommand.pin, child: Text(context.l10n.pinUnpin)),
      PopupMenuItem(
        value: TaskCommand.archive,
        child: Text(context.l10n.archive),
      ),
      PopupMenuItem(
        value: TaskCommand.fork,
        child: Text(context.l10n.forkConversation),
      ),
      PopupMenuItem(
        value: TaskCommand.skills,
        child: ListTile(
          leading: const Icon(Icons.auto_awesome),
          title: Text(context.l10n.skills),
        ),
      ),
      PopupMenuItem(
        value: TaskCommand.goal,
        child: ListTile(
          leading: const Icon(Icons.flag_outlined),
          title: Text(context.l10n.goal),
        ),
      ),
      PopupMenuItem(
        value: TaskCommand.compact,
        child: ListTile(
          leading: const Icon(Icons.compress),
          title: Text(context.l10n.compactContext),
        ),
      ),
      PopupMenuItem(
        value: TaskCommand.interrupt,
        child: ListTile(
          leading: const Icon(Icons.stop_circle_outlined),
          title: Text(context.l10n.interruptTurn),
        ),
      ),
    ],
    icon: const Icon(Icons.more_vert),
  );
}

void _openSubagent(
  BuildContext context,
  CodexRuntime controller,
  String hostId,
  SubagentReference agent,
) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (context) => _SubagentHistory(
        agent: agent,
        hostId: hostId,
        controller: controller,
      ),
    ),
  );
}

class _SubagentHistory extends StatefulWidget {
  const _SubagentHistory({
    required this.agent,
    required this.hostId,
    required this.controller,
  });

  final SubagentReference agent;
  final String hostId;
  final CodexRuntime controller;

  @override
  State<_SubagentHistory> createState() => _SubagentHistoryState();
}

class _SubagentHistoryState extends State<_SubagentHistory> {
  List<TaskItem> _items = const [];
  String? _cursor;
  String? _title;
  String? _role;
  String? _error;
  String? _olderError;
  bool _loading = true;
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool older = false}) async {
    final cursor = older ? _cursor : null;
    if (_loadingOlder || (older && (_loading || cursor == null))) return;
    setState(() {
      if (older) {
        _loadingOlder = true;
        _olderError = null;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final result = await widget.controller.readSubagentHistory(
        widget.agent.threadId,
        widget.hostId,
        cursor: cursor,
      );
      if (!mounted) return;
      setState(() {
        final page = result.page;
        if (older) {
          final existing = _items.map((item) => item.id).toSet();
          _items = [
            ...page.items.where((item) => existing.add(item.id)),
            ..._items,
          ];
        } else {
          _items = page.items;
          _title = result.details?.nickname ?? _title;
          _role = result.details?.role ?? _role;
          _olderError = null;
        }
        _cursor = page.nextCursor == cursor ? null : page.nextCursor;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        final message = context.l10n.subagentLoadFailed((error).toString());
        if (older) {
          _olderError = message;
        } else {
          _error = message;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingOlder = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: Text(_title ?? widget.agent.label),
        actions: [
          IconButton(
            tooltip: context.l10n.refreshSubagentHistory,
            onPressed: _loading || _loadingOlder ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Text(
            _role == null
                ? context.l10n.readOnlySubagent
                : context.l10n.readOnlyLabel((_role).toString()),
          ),
          Expanded(
            child: RemoteFileActions(
              download: controller.downloadFile,
              downloadWithProgress: controller.downloadFile,
              previewVideo: Attachments.supported
                  ? controller.previewVideo
                  : null,
              cancelDownload: controller.cancelDownload,
              child: TaskTimeline(
                items: _items,
                loading: _loading,
                error: _error,
                onRetry: () => _load(),
                hasOlder: _cursor != null && !_loading,
                loadingOlder: _loadingOlder,
                olderError: _olderError,
                onLoadOlder: () => _load(older: true),
                loadImage: controller.loadAttachmentImage,
                onOpenSubagent: (agent) =>
                    _openSubagent(context, controller, widget.hostId, agent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TaskTimeline extends StatefulWidget {
  const TaskTimeline({
    required this.items,
    this.loading = false,
    this.error,
    this.onRetry,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.olderError,
    this.onLoadOlder,
    this.loadImage,
    this.answeredQuestionItemIds = const {},
    this.onAnswerQuestions,
    this.onTurnAction,
    this.onOpenSubagent,
    super.key,
  });

  final List<TaskItem> items;
  final Future<void> Function(TaskItem)? onTurnAction;
  final ValueChanged<SubagentReference>? onOpenSubagent;
  final bool loading;
  final String? error;
  final VoidCallback? onRetry;
  final bool hasOlder;
  final bool loadingOlder;
  final String? olderError;
  final Future<void> Function()? onLoadOlder;
  final Future<Uint8List> Function(String)? loadImage;
  final Set<String> answeredQuestionItemIds;
  final Future<void> Function(TaskItem item, List<String> answers)?
  onAnswerQuestions;

  @override
  State<TaskTimeline> createState() => _TaskTimelineState();
}

class _TaskTimelineState extends State<TaskTimeline>
    with WidgetsBindingObserver {
  static const _followThreshold = 1.0;
  static const _olderLoadThreshold = 200.0;

  final _scrollController = ScrollController();
  var _followLatest = true;
  var _showJumpToLatest = false;
  var _requestingOlder = false;
  var _olderLoadArmed = true;
  var _olderCheckScheduled = false;
  // A long run of collapsed tool events may never fill the viewport.
  var _automaticPagesSinceGesture = 0;
  final Map<String, GlobalKey> _rowKeys = {};
  final Set<String> _expandedProcesses = {};
  int _anchorRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_handleScroll);
    _scheduleLatest(animated: false);
    _scheduleOlderCheck();
  }

  @override
  void didChangeMetrics() {
    if (_followLatest) _scheduleLatest(animated: false);
    _scheduleOlderCheck();
  }

  @override
  void didUpdateWidget(covariant TaskTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items && !_followLatest) {
      _preserveVisibleRow();
    }
    if (oldWidget.items != widget.items ||
        (oldWidget.loadingOlder && !widget.loadingOlder) ||
        oldWidget.hasOlder != widget.hasOlder) {
      _olderLoadArmed = true;
    }
    _scheduleOlderCheck();
    if (oldWidget.items != widget.items ||
        oldWidget.loading != widget.loading ||
        oldWidget.error != widget.error) {
      _scheduleLatest(animated: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _setScrollState(VoidCallback update) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(update);
      });
    } else {
      setState(update);
    }
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    _checkOlderContext();
    final awayFromLatest = _distanceFromLatest > _followThreshold;
    final showJump = awayFromLatest && !_followLatest;
    if (showJump == _showJumpToLatest) return;
    _setScrollState(() => _showJumpToLatest = showJump);
  }

  void _scheduleOlderCheck() {
    if (_olderCheckScheduled) return;
    _olderCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _olderCheckScheduled = false;
      if (mounted) _checkOlderContext();
    });
  }

  void _checkOlderContext() {
    if (!_scrollController.hasClients ||
        _requestingOlder ||
        widget.loadingOlder) {
      return;
    }
    if (_automaticPagesSinceGesture >= 10) return;
    final distanceFromOldest =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (distanceFromOldest > _olderLoadThreshold) {
      _olderLoadArmed = true;
    } else if (_olderLoadArmed) {
      _olderLoadArmed = false;
      _loadOlder();
    }
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    // Nested horizontal code-block scrolling must not affect timeline follow.
    if (notification.depth != 0) return false;
    if ((notification is ScrollStartNotification &&
            notification.dragDetails != null) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      // Pause at gesture start, before a streaming update can animate us back.
      _automaticPagesSinceGesture = 0;
      _olderLoadArmed = true;
      _setScrollState(() => _followLatest = false);
      return false;
    }
    if (notification is ScrollEndNotification) {
      final atLatest = _distanceFromLatest <= _followThreshold;
      _setScrollState(() {
        _followLatest = atLatest;
        _showJumpToLatest = !atLatest;
      });
      return false;
    }
    final userDriven =
        notification is ScrollUpdateNotification &&
        notification.dragDetails != null;
    final userOverscroll =
        notification is OverscrollNotification &&
        notification.dragDetails != null;
    if (!userDriven && !userOverscroll) return false;
    _anchorRevision++;
    const followLatest = false;
    if (followLatest == _followLatest && _showJumpToLatest == !followLatest) {
      return false;
    }
    _setScrollState(() {
      _followLatest = followLatest;
      _showJumpToLatest = !followLatest;
    });
    return false;
  }

  Future<void> _loadOlder({bool retry = false}) async {
    final load = widget.onLoadOlder;
    if (load == null ||
        _requestingOlder ||
        widget.loadingOlder ||
        !widget.hasOlder ||
        (!retry && widget.olderError != null) ||
        !_scrollController.hasClients) {
      return;
    }
    if (retry) _automaticPagesSinceGesture = 0;
    _automaticPagesSinceGesture++;
    _setScrollState(() => _requestingOlder = true);
    try {
      await load();
    } finally {
      if (mounted) _setScrollState(() => _requestingOlder = false);
      if (mounted) _scheduleOlderCheck();
    }
  }

  void _preserveVisibleRow() {
    if (!_scrollController.hasClients) return;
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final bottom = top + viewport.size.height;
    GlobalKey? anchor;
    double? before;
    for (final key in _rowKeys.values) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y + box.size.height <= top || y >= bottom) continue;
      if (before == null || (y - top).abs() < (before - top).abs()) {
        anchor = key;
        before = y;
      }
    }
    if (anchor == null || before == null) return;
    final revision = ++_anchorRevision;
    // 停止惯性动画，否则分页布局和惯性滚动会同时修改位置。
    _scrollController.jumpTo(_scrollController.offset);
    void restore(int remaining) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            revision != _anchorRevision ||
            !_scrollController.hasClients ||
            _followLatest) {
          return;
        }
        final box = anchor!.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.attached || !box.hasSize) return;
        final delta = box.localToGlobal(Offset.zero).dy - before!;
        if (delta.abs() > .1) {
          final position = _scrollController.position;
          _scrollController.jumpTo(
            (position.pixels - delta).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
        if (remaining > 1) restore(remaining - 1);
      });
    }

    restore(3);
  }

  double get _distanceFromLatest =>
      _scrollController.position.pixels -
      _scrollController.position.minScrollExtent;

  void _scheduleLatest({required bool animated}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followLatest || !_scrollController.hasClients) return;
      _scrollToLatest(animated: animated);
    });
  }

  void _scrollToLatest({bool animated = true}) {
    if (!_scrollController.hasClients) return;
    _setScrollState(() {
      _followLatest = true;
      _showJumpToLatest = false;
    });
    final latest = _scrollController.position.minScrollExtent;
    if (animated) {
      _scrollController.animateTo(
        latest,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scrollController.jumpTo(latest);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading && widget.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (widget.error != null && widget.items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 10),
              Text(widget.error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: widget.onRetry,
                child: Text(context.l10n.retry),
              ),
            ],
          ),
        ),
      );
    }
    if (widget.items.isEmpty && !widget.hasOlder) {
      return Center(child: Text(context.l10n.noTaskEventsYet));
    }
    final entries = buildTimelineEntries(widget.items);
    final openQuestionItemId = latestOpenTaskQuestionItemId(
      widget.items,
      widget.answeredQuestionItemIds,
    );
    final timeline = Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) _scheduleOlderCheck();
              return false;
            },
            child: SelectionArea(
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                itemCount: entries.length + 1,
                findChildIndexCallback: (key) {
                  final index = entries.indexWhere(
                    (entry) => ValueKey(entry.key) == key,
                  );
                  return index < 0 ? null : entries.length - index - 1;
                },
                itemBuilder: (_, index) {
                  if (index == entries.length) {
                    return _OlderContextControl(
                      loading: widget.loadingOlder || _requestingOlder,
                      error: widget.olderError,
                      hasOlder: widget.hasOlder,
                      onRetry: () => _loadOlder(retry: true),
                    );
                  }
                  final entry = entries[entries.length - index - 1];
                  return KeyedSubtree(
                    key: ValueKey(entry.key),
                    child: KeyedSubtree(
                      key: _rowKeys.putIfAbsent(entry.key, GlobalKey.new),
                      child: switch (entry) {
                        TimelineMessageEntry(:final item) => GestureDetector(
                          onLongPress:
                              item.turnId != null && widget.onTurnAction != null
                              ? () => widget.onTurnAction!(item)
                              : null,
                          child: TimelineItemView(
                            item: item,
                            loadImage: widget.loadImage,
                            onTurnAction:
                                item.turnId != null &&
                                    widget.onTurnAction != null
                                ? () => widget.onTurnAction!(item)
                                : null,
                            onAnswerQuestions:
                                item.id == openQuestionItemId &&
                                    widget.onAnswerQuestions != null
                                ? (answers) =>
                                      widget.onAnswerQuestions!(item, answers)
                                : null,
                          ),
                        ),
                        TimelineProcessEntry(:final items, :final turn) =>
                          TurnProcess(
                            items: items,
                            turn: turn,
                            expanded: _expandedProcesses.contains(entry.key),
                            onExpanded: (expanded) {
                              _followLatest = false;
                              _preserveVisibleRow();
                              _setScrollState(() {
                                if (expanded) {
                                  _expandedProcesses.add(entry.key);
                                } else {
                                  _expandedProcesses.remove(entry.key);
                                }
                              });
                            },
                            loadImage: widget.loadImage,
                          ),
                        TimelineChangesEntry(:final items) => TurnChanges(
                          items: items,
                        ),
                        TimelineActivityEntry(:final items) =>
                          TimelineActivityGroup(
                            items: items,
                            loadImage: widget.loadImage,
                            onOpenSubagent: widget.onOpenSubagent,
                          ),
                      },
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        if (_showJumpToLatest)
          Positioned(
            right: 16,
            bottom: 14,
            child: FloatingActionButton.small(
              key: const Key('jump-to-latest'),
              tooltip: context.l10n.jumpToLatest,
              onPressed: _scrollToLatest,
              child: const Icon(Icons.arrow_downward),
            ),
          ),
      ],
    );
    return Column(
      children: [
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        if (widget.error != null)
          Material(
            key: const Key('task-refresh-error'),
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.cachedContextMessage(
                        (widget.error).toString(),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onRetry,
                    child: Text(context.l10n.retry),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: timeline),
      ],
    );
  }
}

String? latestOpenTaskQuestionItemId(
  List<TaskItem> items,
  Set<String> answeredItemIds,
) {
  String? result;
  for (final item in items) {
    if (item.kind == TaskItemKind.user) {
      result = null;
    } else if (item.kind == TaskItemKind.agent &&
        item.questions.isNotEmpty &&
        !answeredItemIds.contains(item.id)) {
      result = item.id;
    }
  }
  return result;
}

class _OlderContextControl extends StatelessWidget {
  const _OlderContextControl({
    required this.loading,
    required this.error,
    required this.hasOlder,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final bool hasOlder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Center(
      child: loading
          ? const SizedBox.square(
              key: Key('older-context-progress'),
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : error != null
          ? TextButton.icon(
              key: const Key('retry-older-context'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(context.l10n.retryEarlierContext),
            )
          : !hasOlder
          ? Text(
              context.l10n.startOfTask,
              style: Theme.of(context).textTheme.bodySmall,
            )
          : TextButton(
              key: const Key('load-older-context'),
              onPressed: onRetry,
              child: Text(context.l10n.loadEarlierContext),
            ),
    ),
  );
}

class _TaskHeader extends StatelessWidget {
  const _TaskHeader({
    required this.controller,
    required this.task,
    required this.commandBusy,
    required this.onCommand,
    this.newConversation = false,
    this.onOpenNavigation,
    this.showBackButton = true,
    this.onNewConversation,
  });
  final CodexRuntime controller;
  final TaskRecord task;
  final bool commandBusy;
  final bool newConversation;
  final ValueChanged<TaskCommand> onCommand;
  final VoidCallback? onOpenNavigation;
  final bool showBackButton;
  final VoidCallback? onNewConversation;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
    child: Row(
      children: [
        if (showBackButton)
          IconButton(
            tooltip: context.l10n.goBackToList,
            onPressed: onOpenNavigation ?? controller.clearSelectedTask,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                newConversation ? context.l10n.newChat : task.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (task.cwd.isNotEmpty)
                Text(
                  task.cwd,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ),
        ),
        if (onNewConversation != null)
          IconButton(
            tooltip: context.l10n.newChat,
            onPressed: onNewConversation,
            icon: const Icon(Icons.edit_square, size: 21),
          ),
        if (!newConversation)
          TaskCommandMenu(
            enabled: controller.isConnected && !commandBusy,
            onSelected: onCommand,
          ),
      ],
    ),
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focusNode,
    required this.inputEnabled,
    required this.sendEnabled,
    required this.completions,
    required this.loadingCompletions,
    required this.onCompletion,
    required this.onSend,
    required this.sendMode,
    required this.running,
    required this.connected,
    required this.onStop,
    required this.onSendOptions,
    this.onAttach,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool inputEnabled, sendEnabled, loadingCompletions, running, connected;
  final List<ComposerCompletion> completions;
  final ValueChanged<ComposerCompletion> onCompletion;
  final VoidCallback onSend, onStop, onSendOptions;
  final TaskSendMode sendMode;
  final ValueChanged<bool>? onAttach;
  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (completions.isNotEmpty || loadingCompletions)
            _CompletionPicker(
              completions: completions,
              loading: loadingCompletions,
              onSelected: onCompletion,
            ),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              boxShadow: [
                BoxShadow(
                  color: Theme.of(context).colorScheme.primary
                      .withValues(alpha: .04),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
              borderRadius: BorderRadius.circular(22),
            ),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Column(
              children: [
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: inputEnabled,
                  minLines: 1,
                  maxLines:
                      MediaQuery.sizeOf(context).height -
                              MediaQuery.viewInsetsOf(context).bottom <
                          420
                      ? 2
                      : 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: context.l10n.messagePlaceholder,
                    // 对话输入面板已有容器边界，不继承配置表单的输入框描边。
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    filled: false,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                  ),
                ),
                Row(
                  children: [
                    if (Attachments.supported)
                      PopupMenuButton<bool>(
                        tooltip: context.l10n.addAttachment,
                        enabled: onAttach != null,
                        onSelected: onAttach,
                        icon: const Icon(Icons.add, size: 22),
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: true,
                            child: Text(context.l10n.image),
                          ),
                          PopupMenuItem(
                            value: false,
                            child: Text(context.l10n.fileOrVideo),
                          ),
                        ],
                      ),
                    Expanded(
                      child: Text(
                        running
                            ? context.l10n.runningComposerHint
                            : connected
                            ? context.l10n.remoteComposerHint
                            : context.l10n.localDraftHint,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: controller,
                      builder: (context, value, _) {
                        final stop = running && value.text.trim().isEmpty;
                        return GestureDetector(
                          onLongPress: !stop && sendEnabled
                              ? onSendOptions
                              : null,
                          child: IconButton.filled(
                            tooltip: stop
                                ? context.l10n.stopGenerating
                                : switch (sendMode) {
                                    TaskSendMode.auto =>
                                      context.l10n.sendMessage,
                                    TaskSendMode.steer =>
                                      context.l10n.steerTurnAction,
                                    TaskSendMode.queue =>
                                      context.l10n.queueMessage,
                                  },
                            onPressed: stop
                                ? (connected ? onStop : null)
                                : sendEnabled
                                ? onSend
                                : null,
                            icon: Icon(
                              stop
                                  ? Icons.stop_rounded
                                  : sendMode == TaskSendMode.queue
                                  ? Icons.schedule
                                  : Icons.arrow_upward,
                              size: 22,
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class SendModePicker extends StatelessWidget {
  const SendModePicker({
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.compact = false,
    super.key,
  });
  final bool compact;
  final TaskSendMode value;
  final bool enabled;
  final ValueChanged<TaskSendMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<TaskSendMode>(
    tooltip: context.l10n.messageDeliveryMode,
    enabled: enabled,
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => [
      PopupMenuItem(
        value: TaskSendMode.auto,
        child: Text(context.l10n.automaticModeDescription),
      ),
      PopupMenuItem(
        value: TaskSendMode.steer,
        child: Text(context.l10n.steerModeDescription),
      ),
      PopupMenuItem(
        value: TaskSendMode.queue,
        child: Text(context.l10n.queueModeDescription),
      ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(switch (value) {
            TaskSendMode.auto => context.l10n.automatic,
            TaskSendMode.steer =>
              compact ? context.l10n.steer : context.l10n.steerCurrentTurn,
            TaskSendMode.queue =>
              compact ? context.l10n.queue : context.l10n.queueNextTurn,
          }),
          const Icon(Icons.arrow_drop_down, size: 20),
        ],
      ),
    ),
  );
}

class _CompletionPicker extends StatelessWidget {
  const _CompletionPicker({
    required this.completions,
    required this.loading,
    required this.onSelected,
  });

  final List<ComposerCompletion> completions;
  final bool loading;
  final ValueChanged<ComposerCompletion> onSelected;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: loading && completions.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            )
          : ListView.builder(
              shrinkWrap: true,
              itemCount: completions.length,
              itemBuilder: (context, index) {
                final completion = completions[index];
                return ListTile(
                  dense: true,
                  leading: Icon(
                    completion.kind == ComposerCompletionKind.skill
                        ? Icons.auto_awesome
                        : Icons.keyboard_command_key,
                  ),
                  title: Text(completion.value),
                  subtitle: completion.description.isEmpty
                      ? null
                      : Text(
                          _completionDescription(context, completion),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => onSelected(completion),
                );
              },
            ),
    ),
  );
}

class _ApprovalBar extends StatelessWidget {
  const _ApprovalBar({
    required this.approval,
    required this.enabled,
    required this.onDecision,
  });

  final PendingApproval approval;
  final bool enabled;
  final ValueChanged<String> onDecision;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.secondaryContainer,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(approval.title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          if (approval.isPermissionRequest)
            // 权限范围必须可完整查看，不能沿用命令摘要的三行截断。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: SelectableText(
                  approval.detail,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            )
          else
            Text(
              approval.detail,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed:
                    enabled && approval.availableDecisions.contains('decline')
                    ? () => onDecision('decline')
                    : null,
                child: Text(context.l10n.deny),
              ),
              FilledButton(
                onPressed:
                    enabled && approval.availableDecisions.contains('accept')
                    ? () => onDecision('accept')
                    : null,
                child: Text(
                  approval.isPermissionRequest
                      ? context.l10n.allowForTurn
                      : context.l10n.allowOnce,
                ),
              ),
              if (approval.availableDecisions.contains('acceptForSession'))
                FilledButton.tonal(
                  onPressed: enabled
                      ? () => onDecision('acceptForSession')
                      : null,
                  child: Text(context.l10n.allowForSession),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

// 本地命令说明随界面语言切换；服务端技能说明保持原文。
String _completionDescription(
  BuildContext context,
  ComposerCompletion completion,
) {
  if (completion.kind != ComposerCompletionKind.command) {
    return completion.description;
  }
  return switch (completion.value) {
    '/goal' => context.l10n.commandGoal,
    '/compact' => context.l10n.commandCompact,
    '/skills' => context.l10n.commandSkills,
    '/mcp' => context.l10n.commandMcp,
    '/permissions' => context.l10n.commandPermissions,
    '/interrupt' => context.l10n.commandInterrupt,
    _ => completion.description,
  };
}
