import 'package:flutter/material.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/shared/widgets/go_brand.dart';

/// 空白对话先说明上下文，再提供可编辑的起点；点击建议只填入草稿。
class ConversationWelcome extends StatelessWidget {
  const ConversationWelcome({
    required this.connected,
    required this.cwd,
    required this.onConnect,
    required this.onSuggestion,
    required this.onCwdChanged,
    required this.canEditCwd,
    super.key,
  });
  final bool connected, canEditCwd;
  final String cwd;
  final VoidCallback onConnect;
  final ValueChanged<String> onSuggestion, onCwdChanged;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: (constraints.maxHeight - 44).clamp(0, double.infinity),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const GoMark(size: 58),
                  const SizedBox(height: 26),
                  Text(
                    connected ? l.goStartTitle : l.goWelcomeTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    connected ? l.goStartBody : l.goWelcomeBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      height: 1.7,
                    ),
                  ),
                  const SizedBox(height: 26),
                  if (!connected)
                    FilledButton.icon(
                      onPressed: onConnect,
                      icon: const Icon(Icons.cable),
                      label: Text(l.connectHost),
                    )
                  else ...[
                    LayoutBuilder(
                      builder: (context, box) => Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: [
                          for (final (icon, label, prompt) in [
                            (
                              Icons.explore_outlined,
                              l.goIdeaUnderstand,
                              l.understandProjectPrompt,
                            ),
                            (
                              Icons.bug_report_outlined,
                              l.goIdeaDebug,
                              l.debugProjectPrompt,
                            ),
                            (
                              Icons.auto_awesome_outlined,
                              l.goIdeaBuild,
                              l.buildFeaturePrompt,
                            ),
                          ])
                            SizedBox(
                              width: box.maxWidth >= 420
                                  ? (box.maxWidth - 20) / 3
                                  : box.maxWidth,
                              child: Material(
                                color: colors.surfaceContainerLowest,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: BorderSide(
                                    color: colors.outlineVariant,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => onSuggestion(prompt),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 14,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          icon,
                                          size: 20,
                                          color: colors.primary,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            label,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w500,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    if (canEditCwd)
                      TextFormField(
                        initialValue: cwd,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l.workingDirectoryOptional,
                          hintText: l.workingDirectoryHint,
                          prefixIcon: const Icon(Icons.folder_outlined),
                        ),
                        onChanged: onCwdChanged,
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: colors.secondaryContainer.withValues(
                            alpha: .55,
                          ),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.folder_open,
                              size: 19,
                              color: colors.secondary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                cwd,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.onSurfaceVariant,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
