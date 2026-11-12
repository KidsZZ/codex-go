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
    this.livePreview,
    super.key,
  });
  final IconData icon;
  final String label;
  final String? detail;
  final Color? color;
  final Widget child;
  final Widget? trailing;

  /// 运行中的单行预览独立于展开状态，不能因此打开完整详情。
  final String? livePreview;
  @override
  State<ProcessDisclosure> createState() => _ProcessDisclosureState();
}

class _ProcessDisclosureState extends State<ProcessDisclosure> {
  // 只有点击可以产生展开状态；服务端状态和内容更新不能替用户打开详情。
  bool _open = false;
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

  void _toggle() {
    ConversationLayoutChange().dispatch(context);
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)
        ?.writeState(context, _open, identifier: 'disclosure:${widget.key}');
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
        if (widget.livePreview case final preview?
            when !_open && preview.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: InkWell(
              onTap: _toggle,
              borderRadius: BorderRadius.circular(4),
              child: _LiveProcessPreview(text: preview),
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

/// 固定一行，跟随最新文字的末尾；更新只改变内容，不推动整个对话上下跳动。
class _LiveProcessPreview extends StatelessWidget {
  const _LiveProcessPreview({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    // 限制排版长度并按字素截取，长思考不会累积渲染开销，也不截断组合 emoji。
    final shown = text.characters
        .takeLast(256)
        .toString()
        .replaceAll('**', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return SizedBox(
      height: MediaQuery.textScalerOf(context).scale(12) * 1.5,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          child: ConstrainedBox(
            // 短文字从左侧开始；超过可用宽度后，仅展示最新的一行尾部。
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Text(shown, maxLines: 1, softWrap: false, style: style),
          ),
        ),
      ),
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
