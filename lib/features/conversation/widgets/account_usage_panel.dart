// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';

import 'package:codex_go/infrastructure/platform/account_usage.dart';
import 'package:codex_go/l10n/strings.dart';

class AccountUsagePanel extends StatelessWidget {
  const AccountUsagePanel({required this.controller, super.key});

  final AccountUsageController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final buckets = controller.buckets;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(context.l10n.subscriptionUsage)),
                IconButton(
                  tooltip: context.l10n.refreshUsage,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.online && !controller.loading
                      ? controller.refresh
                      : null,
                  icon: const Icon(Icons.refresh, size: 18),
                ),
              ],
            ),
            if (controller.loading) const LinearProgressIndicator(),
            if (!controller.online)
              Text(context.l10n.connectToViewTheRemoteAccountUsage)
            else ...[
              if (controller.error != null)
                Text(
                  buckets.isEmpty
                      ? controller.error!
                      : context.l10n.showingPreviousUsageRefreshFailedRetry,
                ),
              if (!controller.loading &&
                  controller.error == null &&
                  buckets.isEmpty)
                Text(context.l10n.usageUnavailableForThisServerAccount),
              for (final bucket in buckets) ...[
                Text(
                  '${bucket.name ?? bucket.id}'
                  '${bucket.plan == null ? '' : ' · ${bucket.plan}'}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                if (bucket.primary case final window?)
                  _UsageWindowView(
                    window: window,
                    fallback: context.l10n.primary,
                  ),
                if (bucket.secondary case final window?)
                  _UsageWindowView(
                    window: window,
                    fallback: context.l10n.secondary,
                  ),
                if (bucket.credits != null) Text(bucket.credits!),
                const SizedBox(height: 4),
              ],
              if (buckets.isNotEmpty)
                Text(
                  context.l10n.connectedServerAccountNotAMessageCount,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ],
        ),
      );
    },
  );
}

class _UsageWindowView extends StatelessWidget {
  const _UsageWindowView({required this.window, required this.fallback});

  final UsageWindow window;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final minutes = window.minutes;
    final label = minutes == null
        ? fallback
        : minutes % 1440 == 0
        ? '${minutes ~/ 1440}d'
        : minutes % 60 == 0
        ? '${minutes ~/ 60}h'
        : '${minutes}m';
    final reset = window.resetsAt?.toLocal();
    final localizations = MaterialLocalizations.of(context);
    final resetLabel = reset == null
        ? null
        : '${localizations.formatShortDate(reset)} '
              '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(reset), alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context))}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.usageRemaining(
              label,
              window.remainingPercent.toStringAsFixed(0),
            ),
          ),
          const SizedBox(height: 3),
          LinearProgressIndicator(value: window.remainingPercent / 100),
          if (resetLabel != null)
            Text(
              context.l10n.usageResets((resetLabel).toString()),
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}
