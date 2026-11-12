import 'package:flutter/material.dart';
import 'package:codex_go/infrastructure/platform/diagnostics.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';
import 'package:codex_go/features/hosts/port_forwards_view.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.runtime, super.key});
  final CodexRuntime runtime;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _busy = false;
  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.goSavePreferenceFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await Diagnostics.export();
      if (mounted && saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.connectionDiagnosticsSaved)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.couldNotExportDiagnosticsTryAgain),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearLogs() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.clearConnectionLogsQuestion),
        content: Text(context.l10n.deleteDiagnosticLogsStoredInThisAppChats),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.clearLogs),
          ),
        ],
      ),
    );
    if (accepted == true) await _run(Diagnostics.clear);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.runtime;
    final l = context.l10n;
    final colors = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      children: [
        Text(l.navSettings, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 24),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const GoMark(size: 52),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Codex Go',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l.goTagline,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        l.goVersion,
                        style: TextStyle(color: colors.primary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        _label(l.goAppearance),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.goAppearanceHint,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (mode, label, icon) in [
                      (
                        AppAppearance.system,
                        l.goThemeSystem,
                        Icons.brightness_auto_outlined,
                      ),
                      (
                        AppAppearance.light,
                        l.goThemeLight,
                        Icons.light_mode_outlined,
                      ),
                      (
                        AppAppearance.dark,
                        l.goThemeDark,
                        Icons.dark_mode_outlined,
                      ),
                    ])
                      ChoiceChip(
                        selected: c.appearance == mode,
                        avatar: Icon(icon, size: 17),
                        label: Text(label),
                        onSelected: _busy || !c.preferencesReady
                            ? null
                            : (_) => _run(() => c.setAppearance(mode)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _label(l.goPreferences),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.language,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  l.languageDescription,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (code, label) in [
                      (null, l.languageSystem),
                      ('zh', '简体中文'),
                      ('en', 'English'),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: c.languageCode == code,
                        onSelected: _busy || !c.preferencesReady
                            ? null
                            : (_) => _run(() => c.setLanguage(code)),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        _label(l.goTools),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.settings_ethernet),
                title: Text(l.sshPorts),
                trailing: const Icon(Icons.chevron_right),
                onTap: c.selectedHostId == null
                    ? null
                    : () => showPortForwards(context, c),
              ),
              if (Diagnostics.supported) ...[
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(l.exportConnectionDiagnostics),
                  subtitle: Text(l.goDiagnosticsHint),
                  onTap: _busy ? null : _export,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: Text(l.clearConnectionLogs),
                  onTap: _busy ? null : _clearLogs,
                ),
              ],
            ],
          ),
        ),
        _label(l.goAbout),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.goAboutDescription,
                  style: const TextStyle(height: 1.65),
                ),
                const SizedBox(height: 12),
                Text(
                  l.goCredits,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                    height: 1.65,
                  ),
                ),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: 'Codex Go',
                    applicationVersion: '0.1.0',
                    applicationLegalese: '© 2026 Codex Go contributors\nIncludes MIT-licensed Android-SSH-Codex contributions.',
                  ),
                  icon: const Icon(Icons.code, size: 18),
                  label: Text(l.goLicenses),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 0, 10),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
