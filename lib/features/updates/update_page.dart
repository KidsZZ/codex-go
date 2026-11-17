import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:codex_go/infrastructure/updates/update_controller.dart';
import 'package:codex_go/l10n/strings.dart';

/// 导航提示只显示小红点，流式对话期间不弹出更新通知。
class UpdateBadge extends StatelessWidget {
  const UpdateBadge({required this.child, super.key});
  final Widget child;
  @override
  Widget build(BuildContext context) => Badge(
    isLabelVisible: UpdateScope.of(context)?.hasUpdate ?? false,
    child: child,
  );
}

class UpdateSettingsTile extends StatelessWidget {
  const UpdateSettingsTile({super.key});
  @override
  Widget build(BuildContext context) {
    final updates = UpdateScope.of(context);
    if (updates == null || !updates.supported) return const SizedBox.shrink();
    final l = context.l10n;
    return Card(
      child: ListTile(
        leading: const UpdateBadge(child: Icon(Icons.system_update_outlined)),
        title: Text(l.updateTitle),
        subtitle: Text(
          updates.hasUpdate
              ? '${l.updateAvailable} ${updates.release!.version}'
              : updates.version.isEmpty
              ? l.updateCheck
              : '${updates.version} (${updates.build})',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const UpdatePage())),
      ),
    );
  }
}

class UpdatePage extends StatelessWidget {
  const UpdatePage({super.key});
  Future<void> _install(BuildContext context, UpdateController updates) async {
    final l = context.l10n;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.updateInstall),
        content: Text(l.updateInstallNotice),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.updateContinue),
          ),
        ],
      ),
    );
    if (accepted == true && context.mounted) await updates.install();
  }

  @override
  Widget build(BuildContext context) {
    final updates = UpdateScope.of(context)!;
    final l = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final candidate = updates.release;
    final phase = updates.phase;
    final downloading = phase == UpdatePhase.downloading;
    final verifying =
        phase == UpdatePhase.verifying || phase == UpdatePhase.installing;
    return Scaffold(
      appBar: AppBar(title: Text(l.updateTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.system_update_rounded,
                    size: 36,
                    color: colors.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    updates.channel == 'beta' ? 'Codex Go Beta' : 'Codex Go',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${l.updateCurrent}: ${updates.version.isEmpty ? '—' : '${updates.version} (${updates.build})'}',
                  ),
                  const SizedBox(height: 16),
                  if (updates.initialized && !updates.official)
                    Text(l.updatePreviewNotice)
                  else
                    FilledButton.tonalIcon(
                      onPressed: updates.busy || phase == UpdatePhase.ready
                          ? null
                          : () => updates.check(manual: true),
                      icon: phase == UpdatePhase.checking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: Text(
                        phase == UpdatePhase.checking
                            ? l.updateChecking
                            : l.updateCheck,
                      ),
                    ),
                  if (updates.upToDate && updates.error == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        (updates.channel == 'beta'
                            ? l.updateBetaLatest
                            : l.updateLatest),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (updates.official)
            Card(
              child: SwitchListTile(
                title: Text(l.updateAuto),
                subtitle: Text(l.updateAutoDescription),
                value: updates.autoCheck,
                onChanged: updates.initialized ? updates.setAutoCheck : null,
              ),
            ),
          if (updates.error != null)
            Card(
              color: colors.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error(l, updates.error!),
                  style: TextStyle(color: colors.onErrorContainer),
                ),
              ),
            ),
          if (candidate != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${l.updateAvailable} ${candidate.version}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${(candidate.size / 1024 / 1024).toStringAsFixed(1)} MB · ARM64${candidate.publishedAt == null ? '' : ' · ${DateFormat.yMMMd(Localizations.localeOf(context).toString()).format(candidate.publishedAt!.toLocal())}'}',
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      candidate.notes.isEmpty
                          ? l.updateNoNotes
                          : candidate.notes,
                    ),
                    const SizedBox(height: 20),
                    if (downloading || verifying) ...[
                      LinearProgressIndicator(
                        value: downloading
                            ? updates.received / candidate.size
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        verifying
                            ? l.updateVerifying
                            : '${l.updateDownloading} ${(updates.received * 100 / candidate.size).floor()}%',
                      ),
                      if (downloading)
                        TextButton(
                          onPressed: updates.cancelDownload,
                          child: Text(l.cancel),
                        ),
                    ] else if (phase == UpdatePhase.ready) ...[
                      Text(l.updateReady),
                      if (updates.permissionRequired)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(l.updatePermission),
                        ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: () => _install(context, updates),
                        icon: const Icon(Icons.install_mobile),
                        label: Text(l.updateInstall),
                      ),
                      TextButton(
                        onPressed: updates.download,
                        child: Text(l.updateDownloadAgain),
                      ),
                    ] else
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            onPressed:
                                updates.busy || candidate.minSdk > updates.sdk
                                ? null
                                : updates.download,
                            icon: const Icon(Icons.download_rounded),
                            label: Text(l.updateDownload),
                          ),
                          TextButton(
                            onPressed:
                                updates.busy ||
                                    updates.skipped == candidate.build
                                ? null
                                : updates.skip,
                            child: Text(
                              updates.skipped == candidate.build
                                  ? l.updateSkipped
                                  : l.updateSkip,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            l.updateSource,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              try {
                final opened = await launchUrl(
                  Uri.parse('https://github.com/KidsZZ/codex-go/releases'),
                  mode: LaunchMode.externalApplication,
                );
                if (!opened) throw StateError('No browser');
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.updateBrowserFailed)),
                  );
                }
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: Text(l.updateOpenReleases),
          ),
        ],
      ),
    );
  }

  String _error(AppLocalizations l, String code) => switch (code) {
    'metadata' => l.updateMetadataError,
    'integrity' || 'identity' => l.updateIntegrityError,
    'signature' => l.updateSignatureError,
    'unsupported' => l.updateUnsupported,
    'rateLimit' => l.updateRateLimit,
    'storage' => l.updateStorageError,
    'missing' => l.updateMissing,
    'version' => l.updateVersionError,
    'installer' => l.updateInstallerError,
    'unavailable' => l.updateUnavailable,
    'preview' => l.updatePreviewNotice,
    _ => l.updateNetworkError,
  };
}
