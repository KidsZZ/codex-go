import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:codex_go/domain/conversations/task_message_queue.dart';
import 'package:codex_go/l10n/strings.dart';

/// 阅读时只占一行；编辑和设置展开都由本地交互控制，不随服务端事件跳动。
class ConversationComposer extends StatefulWidget {
  const ConversationComposer({
    required this.controller,
    required this.focusNode,
    required this.inputEnabled,
    required this.sendEnabled,
    required this.onSend,
    required this.sendMode,
    required this.running,
    required this.connected,
    required this.onStop,
    required this.onSendOptions,
    required this.settings,
    this.completions,
    this.maxHeight,
    this.onAttach,
    this.permissionWarning = false,
    this.hasAttachments = false,
    super.key,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool inputEnabled,
      sendEnabled,
      running,
      connected,
      permissionWarning,
      hasAttachments;
  final VoidCallback onSend, onStop, onSendOptions;
  final TaskSendMode sendMode;
  final ValueChanged<bool>? onAttach;
  final Widget settings;
  final Widget? completions;
  final double? maxHeight;

  @override
  State<ConversationComposer> createState() => _ConversationComposerState();
}

class _ConversationComposerState extends State<ConversationComposer> {
  bool _settingsOpen = false;
  // 编辑框固定在同一父节点下，切换布局时保留焦点、选区和输入法连接。
  final _inputKey = GlobalKey();
  final _inputScroll = ScrollController();

  @override
  void dispose() {
    _inputScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final budget =
        widget.maxHeight ??
        math.max(
          140,
          (MediaQuery.sizeOf(context).height -
                  MediaQuery.viewInsetsOf(context).bottom) *
              .5,
        );
    final completionHeight = widget.completions == null ? 0.0 : budget * .25;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.completions != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: completionHeight),
                child: widget.completions!,
              ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                final editing =
                    MediaQuery.viewInsetsOf(context).bottom > 0 ||
                    value.text.contains('\n');
                final expanded = editing || _settingsOpen;
                final stop =
                    widget.running &&
                    value.text.trim().isEmpty &&
                    !widget.hasAttachments;
                final canSend =
                    widget.sendEnabled &&
                    (value.text.trim().isNotEmpty || widget.hasAttachments);
                final lineHeight =
                    MediaQuery.textScalerOf(context).scale(16) * 1.5;
                // 先为设置、操作按钮和安全区留空间，长输入仅在编辑框内部滚动。
                final chrome =
                    26 +
                    MediaQuery.paddingOf(context).bottom +
                    (expanded ? 44 : 0) +
                    (_settingsOpen ? 44 : 0) +
                    completionHeight;
                final visibleLines = ((budget - chrome - 20) / lineHeight)
                    .floor()
                    .clamp(1, 6);
                final field = TextField(
                  key: _inputKey,
                  controller: widget.controller,
                  scrollController: _inputScroll,
                  focusNode: widget.focusNode,
                  enabled: widget.inputEnabled,
                  minLines: 1,
                  maxLines: expanded ? visibleLines : 1,
                  style: const TextStyle(fontSize: 16, height: 1.5),
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: widget.running
                        ? context.l10n.runningComposerHint
                        : context.l10n.messagePlaceholder,
                    hintMaxLines: 1,
                    hintStyle: TextStyle(
                      fontSize: 15,
                      color: colors.onSurfaceVariant.withValues(alpha: .7),
                    ),
                    filled: false,
                    isDense: true,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: expanded ? 10 : 0,
                      vertical: 10,
                    ),
                  ),
                );
                final attach = SizedBox.square(
                  dimension: 40,
                  child: PopupMenuButton<bool>(
                    tooltip: context.l10n.addAttachment,
                    enabled: widget.onAttach != null,
                    onSelected: widget.onAttach,
                    icon: const Icon(Icons.add_rounded, size: 23),
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
                );
                final options = IconButton(
                  tooltip: context.l10n.chatOptions,
                  onPressed: () =>
                      setState(() => _settingsOpen = !_settingsOpen),
                  isSelected: _settingsOpen,
                  color: widget.permissionWarning
                      ? colors.tertiary
                      : colors.onSurfaceVariant,
                  icon: Icon(
                    widget.permissionWarning
                        ? Icons.shield_outlined
                        : Icons.tune_rounded,
                    size: 19,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 40,
                  ),
                  padding: EdgeInsets.zero,
                );
                final send = GestureDetector(
                  onLongPress: !stop && widget.sendEnabled
                      ? widget.onSendOptions
                      : null,
                  child: IconButton.filled(
                    tooltip: stop
                        ? context.l10n.stopGenerating
                        : context.l10n.sendMessage,
                    onPressed: stop
                        ? (widget.connected ? widget.onStop : null)
                        : canSend
                        ? widget.onSend
                        : null,
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(40),
                      maximumSize: const Size.square(40),
                      padding: EdgeInsets.zero,
                      backgroundColor: stop
                          ? colors.primaryContainer
                          : colors.primary,
                      foregroundColor: stop
                          ? colors.onPrimaryContainer
                          : colors.onPrimary,
                      disabledBackgroundColor: colors.onSurface.withValues(
                        alpha: .06,
                      ),
                      disabledForegroundColor: colors.onSurface.withValues(
                        alpha: .3,
                      ),
                    ),
                    icon: Icon(
                      stop
                          ? Icons.stop_rounded
                          : widget.sendMode == TaskSendMode.queue
                          ? Icons.schedule_rounded
                          : Icons.arrow_upward_rounded,
                      size: 21,
                    ),
                  ),
                );
                return Material(
                  color: colors.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(expanded ? 24 : 28),
                    side: BorderSide(
                      color: colors.outlineVariant.withValues(alpha: .65),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (!expanded) attach,
                            Expanded(
                              key: const ValueKey('editor-slot'),
                              child: Scrollbar(
                                controller: _inputScroll,
                                thumbVisibility: expanded,
                                child: field,
                              ),
                            ),
                            if (!expanded) ...[
                              options,
                              const SizedBox(width: 4),
                              send,
                            ],
                          ],
                        ),
                        if (_settingsOpen)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: SizedBox(height: 40, child: widget.settings),
                          ),
                        if (expanded)
                          Row(
                            children: [
                              attach,
                              const Spacer(),
                              options,
                              const SizedBox(width: 4),
                              send,
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
