import 'dart:math' as math;

import 'process_disclosure.dart';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 只平滑实时追加的正文；历史、回切、服务端替换和结束时立即显示完整内容。
class StreamingReply extends StatefulWidget {
  const StreamingReply({
    required this.text,
    required this.streaming,
    required this.builder,
    super.key,
  });
  final String text;
  final bool streaming;
  final Widget Function(String) builder;
  @override
  State<StreamingReply> createState() => _StreamingReplyState();
}

class _StreamingReplyState extends State<StreamingReply>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late double _shown = widget.text.length.toDouble();
  Duration _last = Duration.zero;
  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000000;
    _last = elapsed;
    final remaining = widget.text.length - _shown;
    final next = math.min(
      widget.text.length.toDouble(),
      _shown + math.max(48, remaining / .12) * dt,
    );
    if (next.floor() != _shown.floor()) {
      ConversationLayoutChange(userInitiated: false).dispatch(context);
      setState(() => _shown = next);
    } else {
      _shown = next;
    }
    if (_shown >= widget.text.length) _ticker.stop();
  }

  @override
  void didUpdateWidget(covariant StreamingReply oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled;
    if (!widget.streaming ||
        reduceMotion ||
        !widget.text.startsWith(oldWidget.text) ||
        widget.text.length - _shown > 1600) {
      _shown = widget.text.length.toDouble();
      _ticker.stop();
    } else if (_shown < widget.text.length && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var end = _shown.floor().clamp(0, widget.text.length);
    // 不切断 UTF-16 代理对，避免 emoji 在逐步显示时出现替代字符。
    if (end > 0 &&
        end < widget.text.length &&
        widget.text.codeUnitAt(end - 1) >= 0xD800 &&
        widget.text.codeUnitAt(end - 1) <= 0xDBFF) {
      end--;
    }
    return widget.builder(widget.text.substring(0, end));
  }
}
