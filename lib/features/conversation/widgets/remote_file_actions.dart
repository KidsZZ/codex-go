// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:codex_go/infrastructure/ssh/file_download.dart';
import 'package:codex_go/infrastructure/ssh/resumable_download.dart';
import 'package:codex_go/l10n/strings.dart';

class RemoteFileActions extends InheritedWidget {
  const RemoteFileActions({
    required this.download,
    this.downloadWithProgress,
    this.previewVideo,
    this.cancelDownload,
    required super.child,
    super.key,
  });
  final Future<bool> Function(String) download;
  final VoidCallback? cancelDownload;
  final Future<bool> Function(
    String, {
    void Function(DownloadProgress)? onProgress,
  })?
  downloadWithProgress;
  final Future<bool> Function(
    String, {
    void Function(DownloadProgress)? onProgress,
    VoidCallback? onReady,
  })?
  previewVideo;

  static RemoteFileActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RemoteFileActions>();

  @override
  bool updateShouldNotify(RemoteFileActions oldWidget) =>
      download != oldWidget.download ||
      downloadWithProgress != oldWidget.downloadWithProgress ||
      previewVideo != oldWidget.previewVideo ||
      cancelDownload != oldWidget.cancelDownload;
}

/// Only a tap starts an SSH transfer. Videos are streamed to bounded temporary
/// disk storage, then opened in the phone's player without a save-location step.
Future<void> showRemoteVideoPreview(BuildContext context, String path) async {
  final actions = RemoteFileActions.maybeOf(context);
  final preview = actions?.previewVideo;
  if (preview == null) return;
  final cancel = actions?.cancelDownload;
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier(const DownloadProgress(0, null));
  var finished = false;
  var ready = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  late final DialogRoute<void> route;
  void hideLoading() {
    ready = true;
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
  }

  route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(context.l10n.loadingVideo),
        content: ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final total = value.total;
            final fraction = total != null && total > 0
                ? (value.received / total).clamp(0.0, 1.0)
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: value.verifying || value.reconnecting
                      ? null
                      : fraction,
                ),
                const SizedBox(height: 12),
                Text(
                  '${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                  '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}',
                ),
                if (value.reconnecting)
                  Text(
                    context.l10n.connectionInterruptedReconnectingAndResuming,
                  ),
                if (value.verifying) Text(context.l10n.verifyingFileIntegrity),
                if (cancel != null)
                  TextButton(
                    onPressed: cancel,
                    child: Text(context.l10n.cancelLoading),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    await preview(
      path,
      onProgress: (value) {
        if (!finished && !ready) progress.value = value;
      },
      onReady: hideLoading,
    );
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error is PlatformException
              ? error.message ??
                    context.l10n.videoPlaybackFailed((error.code).toString())
              : downloadErrorMessage(error, strings: context.l10n),
        ),
      ),
    );
  } finally {
    finished = true;
    hideLoading();
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }
}

class RemoteVideoPreview extends StatelessWidget {
  const RemoteVideoPreview({required this.path, this.label, super.key});
  final String path;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final actions = RemoteFileActions.maybeOf(context);
    final playable = actions?.previewVideo != null;
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (playable)
            Material(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => unawaited(showRemoteVideoPreview(context, path)),
                child: SizedBox(
                  height: 158,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_circle_outline,
                          size: 48,
                          color: colors.primary,
                        ),
                        Text(context.l10n.playVideo),
                        if (label?.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Text(
                              label!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (actions != null)
            TextButton.icon(
              onPressed: () => unawaited(showRemoteFileDownload(context, path)),
              icon: const Icon(Icons.download_outlined),
              label: Text(context.l10n.downloadVideo),
            ),
        ],
      ),
    );
  }
}

Future<void> showRemoteFileDownload(BuildContext context, String path) async {
  final actions = RemoteFileActions.maybeOf(context);
  if (actions == null) return;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.l10n.downloadRemoteFileQuestion),
      content: SingleChildScrollView(
        child: SelectableText(
          context.l10n.downloadFileDescription((path).toString()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.download),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier(const DownloadProgress(0, null));
  var finished = false;
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(context.l10n.downloadFile),
        content: ValueListenableBuilder<DownloadProgress>(
          valueListenable: progress,
          builder: (context, value, _) {
            final total = value.total;
            final fraction = total != null && total > 0
                ? (value.received / total).clamp(0.0, 1.0)
                : null;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: value.saving || value.verifying || value.reconnecting
                      ? null
                      : fraction,
                ),
                const SizedBox(height: 12),
                Text(
                  value.saving
                      ? context.l10n.chooseALocationThenSaving
                      : '${(value.received / 1048576).toStringAsFixed(2)} MiB received'
                            '${fraction == null ? "" : " · ${(fraction * 100).toStringAsFixed(0)}%"}',
                ),
                if (value.reconnecting)
                  Text(
                    context.l10n.connectionInterruptedReconnectingAndResuming,
                  ),
                if (value.verifying) Text(context.l10n.verifyingFileIntegrity),
                if (!value.verifying &&
                    !value.reconnecting &&
                    value.bytesPerSecond != null)
                  Text(
                    '${(value.bytesPerSecond! / 1048576).toStringAsFixed(2)} MiB/s',
                  ),
                if (actions.cancelDownload != null && !value.saving)
                  TextButton(
                    onPressed: actions.cancelDownload,
                    child: Text(context.l10n.cancelDownload),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );
  unawaited(navigator.push(route));
  try {
    final saved = actions.downloadWithProgress == null
        ? await actions.download(path)
        : await actions.downloadWithProgress!(
            path,
            onProgress: (value) {
              if (!finished) progress.value = value;
            },
          );
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          saved ? context.l10n.fileSaved : context.l10n.saveCancelled,
        ),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(downloadErrorMessage(error, strings: context.l10n)),
      ),
    );
  } finally {
    finished = true;
    if (route.isActive) navigator.removeRoute(route);
    // Route widgets are disposed after removal; do not dispose their notifier
    // while ValueListenableBuilder is still listening.
    WidgetsBinding.instance.addPostFrameCallback((_) => progress.dispose());
  }
}

String downloadErrorMessage(Object error, {AppLocalizations? strings}) {
  final l10n = strings ?? lookupAppLocalizations(const Locale('en'));
  if (error is DownloadCancelled) return l10n.downloadCancelled;
  if (error is FileDownloadException) return error.message;
  if (error is TimeoutException) {
    return l10n.downloadTimedOutCheckTheConnectionAndRetry;
  }
  if (error is FileSystemException) {
    return l10n.phoneTemporaryStorageCouldNotBeWrittenCheck;
  }
  if (error is PlatformException) {
    return l10n.saveOnPhoneFailed((error.code).toString());
  }
  if (error is StateError) {
    return l10n.downloadFailedReason((error.message).toString());
  }
  return l10n.downloadFailedConnection((error.runtimeType).toString());
}
