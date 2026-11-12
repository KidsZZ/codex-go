// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import 'package:codex_go/features/conversation/widgets/formula_markdown.dart';
import 'package:codex_go/features/conversation/widgets/inline_attachment_image.dart';
import 'package:codex_go/features/conversation/widgets/remote_file_actions.dart';
import 'package:codex_go/domain/conversations/message_attachments.dart';
import 'package:codex_go/infrastructure/ssh/file_download.dart';
import 'package:codex_go/infrastructure/ports/port_forward.dart';
import 'package:codex_go/shared/media/remote_port_link_scope.dart';
import 'package:codex_go/l10n/strings.dart';

typedef ExternalLinkOpener = Future<bool> Function(Uri uri);
typedef MarkdownTextCopier = Future<void> Function(String text);

Future<bool> launchExternalLink(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<void> copyMarkdownText(String text) =>
    Clipboard.setData(ClipboardData(text: text));

Uri? safeWebUri(String? value) {
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? uri : null;
}

Future<void> openWebLink(
  BuildContext context,
  String? value,
  ExternalLinkOpener opener,
) async {
  final uri = safeWebUri(value);
  if (uri == null) {
    _showLinkError(context, context.l10n.onlyHttpAndHttpsLinksCanBeOpened);
    return;
  }
  try {
    final scope = RemotePortLinkScope.maybeOf(context);
    if (scope != null && isRemoteLoopbackUri(uri)) {
      await scope.onOpen(context, uri, opener);
      return;
    }
    if (!await opener(uri) && context.mounted) {
      _showLinkError(context, context.l10n.couldNotOpenLink);
    }
  } catch (_) {
    if (context.mounted) _showLinkError(context, context.l10n.couldNotOpenLink);
  }
}

void _showLinkError(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
      ?.showSnackBar(SnackBar(content: Text(message)));
}

class MarkdownContent extends StatelessWidget {
  const MarkdownContent({
    required this.text,
    this.openExternalLink = launchExternalLink,
    this.copyText = copyMarkdownText,
    this.selectable = true,
    super.key,
  });

  final String text;
  final ExternalLinkOpener openExternalLink;
  final MarkdownTextCopier copyText;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final codeTextStyle = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'monospace',
    );
    return MarkdownBody(
      data: text,
      selectable: selectable,
      extensionSet: md.ExtensionSet(
        [FormulaBlockSyntax(), ...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
        [
          FormulaInlineSyntax(),
          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
        ],
      ),
      builders: {
        'latex': FormulaElementBuilder(textStyle: theme.textTheme.bodyMedium),
        'pre': CodeBlockElementBuilder(
          copyText: copyText,
          textStyle: codeTextStyle,
        ),
      },
      onTapLink: (_, href, __) {
        if (href != null &&
            RemoteFileActions.maybeOf(context) != null &&
            remoteFilePath(href, '/') != null) {
          if (MessageAttachment(path: remoteFilePath(href, '/')!).isVideo &&
              RemoteFileActions.maybeOf(context)?.previewVideo != null) {
            unawaited(showRemoteVideoPreview(context, href));
          } else {
            unawaited(showRemoteFileDownload(context, href));
          }
        } else {
          unawaited(openWebLink(context, href, openExternalLink));
        }
      },
      imageBuilder: (uri, title, alt) {
        final path = remoteFilePath(uri.toString(), '/');
        // Some agents use image Markdown for all media. Never read a video
        // through the bounded image decoder or offer an endless image retry.
        final attachment = MessageAttachment(path: path ?? uri.path);
        if (attachment.isVideo && path != null) {
          return RemoteVideoPreview(path: path, label: alt);
        }
        final loader = ImagePreviewScope.maybeOf(context);
        if ((path != null && loader != null) ||
            uri.toString().startsWith('data:image/')) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InlineAttachmentImage(
                key: ValueKey(uri.toString()),
                attachment: MessageAttachment(
                  path: path ?? uri.toString(),
                  name: alt ?? context.l10n.image,
                  isImage: true,
                ),
                loadImage: loader,
              ),
              if (path != null && RemoteFileActions.maybeOf(context) != null)
                TextButton.icon(
                  onPressed: () =>
                      unawaited(showRemoteFileDownload(context, path)),
                  icon: const Icon(Icons.download_outlined),
                  label: Text(context.l10n.downloadImage),
                ),
            ],
          );
        }
        if (RemoteFileActions.maybeOf(context) != null &&
            remoteFilePath(uri.toString(), '/') != null) {
          return OutlinedButton.icon(
            onPressed: () =>
                unawaited(showRemoteFileDownload(context, uri.toString())),
            icon: const Icon(Icons.download_outlined),
            label: Text(
              alt?.isNotEmpty == true ? alt! : context.l10n.downloadImage,
            ),
          );
        }
        return _BlockedImage(alt: alt);
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        code: codeTextStyle?.copyWith(
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
        ),
        codeblockDecoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class CodeBlockElementBuilder extends MarkdownElementBuilder {
  CodeBlockElementBuilder({required this.copyText, required this.textStyle});

  final MarkdownTextCopier copyText;
  final TextStyle? textStyle;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    return _CopyableCodeBlock(
      text: text.text,
      style: textStyle,
      copyText: copyText,
    );
  }
}

class _CopyableCodeBlock extends StatelessWidget {
  const _CopyableCodeBlock({
    required this.text,
    required this.style,
    required this.copyText,
  });

  final String text;
  final TextStyle? style;
  final MarkdownTextCopier copyText;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const Key('markdown-code-block'),
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                tooltip: context.l10n.copyCode,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                onPressed: () => unawaited(_copyCode(context, text, copyText)),
                icon: const Icon(Icons.copy_all_outlined),
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(text, style: style),
          ),
        ],
      ),
    );
  }
}

Future<void> _copyCode(
  BuildContext context,
  String text,
  MarkdownTextCopier copyText,
) async {
  try {
    await copyText(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.codeCopied)));
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(context.l10n.couldNotCopyCode)));
  }
}

class _BlockedImage extends StatelessWidget {
  const _BlockedImage({this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) => Semantics(
    label: alt,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_not_supported_outlined, size: 16),
            const SizedBox(width: 6),
            Text(context.l10n.externalImageBlocked),
          ],
        ),
      ),
    ),
  );
}
