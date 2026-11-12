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

import 'code_block.dart';

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
      fontFamily: 'GoMono',
      fontSize: 13.5,
      height: 1.6,
    );
    return MarkdownBody(
      data: text,
      selectable: selectable,
      shrinkWrap: true,
      fitContent: true,
      extensionSet: md.ExtensionSet(
        [FormulaBlockSyntax(), ...md.ExtensionSet.gitHubFlavored.blockSyntaxes],
        [
          FormulaInlineSyntax(),
          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
        ],
      ),
      builders: {
        'latex': FormulaElementBuilder(textStyle: theme.textTheme.bodyMedium),
        'pre': CodeBlockElementBuilder(copyText: copyText),
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
        p: theme.textTheme.bodyLarge?.copyWith(
          fontSize: 16,
          height: 1.65,
          letterSpacing: .1,
        ),
        h1: theme.textTheme.titleLarge?.copyWith(
          fontSize: 23,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
        h2: theme.textTheme.titleLarge?.copyWith(
          fontSize: 20,
          height: 1.4,
          fontWeight: FontWeight.w600,
        ),
        h3: theme.textTheme.titleMedium?.copyWith(
          fontSize: 17,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
        h1Padding: const EdgeInsets.only(top: 12, bottom: 4),
        h2Padding: const EdgeInsets.only(top: 8, bottom: 2),
        h3Padding: const EdgeInsets.only(top: 4),
        blockSpacing: 12,
        listIndent: 22,
        listBullet: theme.textTheme.bodyLarge?.copyWith(
          fontSize: 16,
          height: 1.65,
        ),
        code: codeTextStyle?.copyWith(
          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: .045),
        ),
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 4,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
          ),
        ),
      ),
    );
  }
}

class CodeBlockElementBuilder extends MarkdownElementBuilder {
  CodeBlockElementBuilder({required this.copyText});
  final MarkdownTextCopier copyText;
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.children
        ?.whereType<md.Element>()
        .where((e) => e.tag == 'code')
        .firstOrNull;
    final language = code?.attributes['class']?.replaceFirst('language-', '');
    return ConversationCodeBlock(
      key: const Key('markdown-code-block'),
      code: element.textContent,
      language: language,
      copyText: copyText,
    );
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
