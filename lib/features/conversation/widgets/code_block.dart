import 'dart:async';

import 'process_disclosure.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:codex_go/l10n/strings.dart';

final _highlighter = Highlight()
  ..registerLanguages({
    'bash': langBash,
    'dart': langDart,
    'diff': langDiff,
    'python': langPython,
    'javascript': langJavascript,
    'typescript': langTypescript,
    'json': langJson,
    'yaml': langYaml,
    'css': langCss,
    'xml': langXml,
    'go': langGo,
    'rust': langRust,
    'java': langJava,
    'kotlin': langKotlin,
    'sql': langSql,
  });
final _spans = <(String, String, bool), TextSpan>{};

/// 独立代码阅读区：语言、复制和换行固定在工具栏，复制保持原文。
class ConversationCodeBlock extends StatefulWidget {
  const ConversationCodeBlock({
    required this.code,
    this.language,
    this.copyText,
    super.key,
  });
  final String code;
  final String? language;
  final Future<void> Function(String)? copyText;
  @override
  State<ConversationCodeBlock> createState() => _ConversationCodeBlockState();
}

class _ConversationCodeBlockState extends State<ConversationCodeBlock> {
  bool _wrap = false;
  bool _copied = false;
  Timer? _reset;
  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      if (widget.copyText != null) {
        await widget.copyText!(widget.code);
      } else {
        await Clipboard.setData(ClipboardData(text: widget.code));
      }
      if (!mounted) return;
      setState(() => _copied = true);
      _reset?.cancel();
      _reset = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _copied = false);
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.l10n.couldNotCopyCode)));
      }
    }
  }

  TextSpan _highlight(bool dark) {
    final language = switch (widget.language?.toLowerCase()) {
      'sh' || 'shell' || 'zsh' => 'bash',
      'js' || 'jsx' => 'javascript',
      'ts' || 'tsx' => 'typescript',
      'py' => 'python',
      'yml' => 'yaml',
      'html' => 'xml',
      final value => value ?? '',
    };
    final key = (widget.code, language, dark);
    final cached = _spans.remove(key);
    if (cached != null) return _spans[key] = cached;
    final base = TextStyle(
      fontFamily: 'GoMono',
      fontFamilyFallback: const ['Noto Sans CJK SC', 'Noto Sans', 'sans-serif'],
      fontSize: 12.5,
      height: 1.6,
      color: dark ? const Color(0xFFDDE3EE) : const Color(0xFF263144),
    );
    var span = TextSpan(text: widget.code, style: base);
    // 超长日志保持可读，避免高亮解析阻塞输入；未知语言同样展示完整原文。
    if (widget.code.length <= 24000 && language.isNotEmpty) {
      try {
        final renderer = TextSpanRenderer(base, {
          'keyword': TextStyle(
            color: dark ? const Color(0xFFB7ACFA) : const Color(0xFF6846A8),
          ),
          'string': TextStyle(
            color: dark ? const Color(0xFF9CD5BC) : const Color(0xFF247858),
          ),
          'number': TextStyle(
            color: dark ? const Color(0xFFE9BB90) : const Color(0xFFA45C26),
          ),
          'comment': TextStyle(
            color: dark ? const Color(0xFF8795AA) : const Color(0xFF738095),
          ),
          'title': TextStyle(
            color: dark ? const Color(0xFF9CCAF0) : const Color(0xFF326BAD),
          ),
          'attr': TextStyle(
            color: dark ? const Color(0xFF9CCAF0) : const Color(0xFF326BAD),
          ),
          'addition': TextStyle(
            color: dark ? const Color(0xFF9CD5BC) : const Color(0xFF247858),
          ),
          'deletion': TextStyle(
            color: dark ? const Color(0xFFFFADAD) : const Color(0xFFBA3C43),
          ),
        });
        _highlighter
            .highlight(code: widget.code, language: language)
            .render(renderer);
        span = renderer.span ?? span;
      } catch (_) {
        /* 不支持的语言仍保留可选择、可复制的原文。 */
      }
    }
    // 有界缓存避免长对话的代码文本无限驻留。
    _spans[key] = span;
    if (_spans.length > 32) _spans.remove(_spans.keys.first);
    return span;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final body = SelectableText.rich(_highlight(dark));
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF0C111C) : const Color(0xFFF0F2F7),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: colors.onSurface.withValues(alpha: .035),
            padding: const EdgeInsets.only(left: 14, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.language?.isNotEmpty == true
                        ? widget.language!
                        : context.l10n.chatCode,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'GoMono',
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.chatWrapCode,
                  isSelected: _wrap,
                  onPressed: () {
                    ConversationLayoutChange().dispatch(context);
                    setState(() => _wrap = !_wrap);
                  },
                  icon: const Icon(Icons.wrap_text_rounded, size: 16),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: context.l10n.copyCode,
                  onPressed: _copy,
                  icon: Icon(
                    _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                    size: 15,
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: _wrap
                ? body
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: body,
                  ),
          ),
        ],
      ),
    );
  }
}
