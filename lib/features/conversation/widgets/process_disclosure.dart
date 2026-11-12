import 'package:flutter/material.dart';

/// 展开前通知时间线保存阅读锚点，动画期间也不抢走用户的滚动位置。
class ConversationLayoutChange extends Notification {
  ConversationLayoutChange({this.userInitiated = true});
  final bool userInitiated;
}

/// 过程、工具组和回合摘要共用同一套两列结构，正文不再被大卡片分割。
class ProcessDisclosure extends StatefulWidget {
  const ProcessDisclosure({
    required this.icon,
    required this.label,
    required this.child,
    this.detail,
    this.color,
    this.trailing,
    this.initiallyExpanded = false,
    this.onChanged,
    super.key,
  });
  final IconData icon;
  final String label;
  final String? detail;
  final Color? color;
  final Widget child;
  final Widget? trailing;
  final bool initiallyExpanded;
  final ValueChanged<bool>? onChanged;
  @override
  State<ProcessDisclosure> createState() => _ProcessDisclosureState();
}

class _ProcessDisclosureState extends State<ProcessDisclosure> {
  late bool _open = widget.initiallyExpanded;
  bool _restored = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_restored) {
      final stored = PageStorage.maybeOf(context)
          ?.readState(context, identifier: 'disclosure:${widget.key}');
      if (stored is bool) _open = stored;
      _restored = true;
    }
  }

  @override
  void didUpdateWidget(covariant ProcessDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新出现的错误自动展开一次，用户之后仍能主动收起。
    if (!oldWidget.initiallyExpanded && widget.initiallyExpanded) _open = true;
  }

  void _toggle() {
    ConversationLayoutChange().dispatch(context);
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)
        ?.writeState(context, _open, identifier: 'disclosure:${widget.key}');
    widget.onChanged?.call(_open);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tone = widget.color ?? colors.onSurfaceVariant;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: tone.withValues(alpha: .09),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Icon(widget.icon, size: 15, color: tone),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: widget.label),
                            if (widget.detail case final detail?
                                when detail.isNotEmpty)
                              TextSpan(
                                text: ' · $detail',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'GoMono',
                                  fontFamilyFallback: const [
                                    'Noto Sans CJK SC',
                                    'Noto Sans',
                                    'sans-serif',
                                  ],
                                  color: colors.onSurfaceVariant.withValues(
                                    alpha: .8,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (widget.trailing != null) ...[
                      const SizedBox(width: 6),
                      widget.trailing!,
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: _open ? .5 : 0,
                      duration: duration,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                        color: colors.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: duration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(left: 11, bottom: 8),
                  padding: const EdgeInsets.fromLTRB(20, 4, 0, 8),
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .7),
                      ),
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey('details:${widget.key}'),
                    child: widget.child,
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// 限制长日志和大量过程的展开高度，收起入口始终留在可见区域。
class ProcessDetailViewport extends StatefulWidget {
  const ProcessDetailViewport({
    required this.itemCount,
    required this.itemBuilder,
    this.viewportKey = const Key('activity-viewport'),
    this.maxHeight = 360,
    super.key,
  });

  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Key viewportKey;
  final double maxHeight;

  @override
  State<ProcessDetailViewport> createState() => _ProcessDetailViewportState();
}

class _ProcessDetailViewportState extends State<ProcessDetailViewport> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final available =
        media.size.height - media.viewInsets.bottom - media.padding.vertical;
    final height = (available * 0.4).clamp(80, widget.maxHeight).toDouble();
    return ConstrainedBox(
      key: widget.viewportKey,
      constraints: BoxConstraints(maxHeight: height),
      child: NotificationListener<ScrollNotification>(
        // Internal scrolling must not change the chat's follow-latest state.
        onNotification: (_) => true,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: false,
          child: ListView.builder(
            controller: _scroll,
            primary: false,
            shrinkWrap: true,
            padding: const EdgeInsets.only(right: 8),
            itemCount: widget.itemCount,
            itemBuilder: widget.itemBuilder,
          ),
        ),
      ),
    );
  }
}
