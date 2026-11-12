// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

class FormulaInlineSyntax extends md.InlineSyntax {
  FormulaInlineSyntax() : super(r'\$([^$\n]+)\$|\\\(([^\n]+?)\\\)');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final formula = match.group(1) ?? match.group(2) ?? '';
    final element = md.Element.text('latex', formula);
    element.attributes['display'] = 'false';
    parser.addNode(element);
    return true;
  }
}

class FormulaBlockSyntax extends md.BlockSyntax {
  FormulaBlockSyntax();

  @override
  RegExp get pattern =>
      RegExp(r'^(?:\$\$(.+)\$\$\s*|\$\$\s*|\\\[(.*)\\\]\s*)$');

  @override
  md.Node parse(md.BlockParser parser) {
    final first = pattern.firstMatch(parser.current.content);
    final inline = first?.group(1) ?? first?.group(2);
    if (inline != null) {
      parser.advance();
      return _formulaParagraph(inline);
    }
    parser.advance();
    final lines = <String>[];
    while (!parser.isDone &&
        !RegExp(r'^\$\$\s*$').hasMatch(parser.current.content)) {
      lines.add(parser.current.content);
      parser.advance();
    }
    if (!parser.isDone) parser.advance();
    return _formulaParagraph(lines.join('\n').trim());
  }

  md.Element _formulaParagraph(String formula) {
    final element = md.Element.text('latex', formula);
    element.attributes['display'] = 'true';
    return md.Element('p', [element]);
  }
}

class FormulaElementBuilder extends MarkdownElementBuilder {
  FormulaElementBuilder({this.textStyle});

  final TextStyle? textStyle;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final display = element.attributes['display'] == 'true';
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Container(
        padding: display
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          element.textContent,
          style: textStyle?.copyWith(
            fontFamily: 'monospace',
            fontStyle: FontStyle.italic,
          ),
        ),
      ),
    );
  }
}
