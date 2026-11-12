// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:codex_go/infrastructure/codex/codex_remote_api.dart';

final class TurnSettings {
  const TurnSettings({this.model, this.effort, this.serviceTier});

  final String? model;
  final String? effort;

  /// Null follows the server's thread setting, rather than forcing Standard.
  final String? serviceTier;
  bool get fast => serviceTier == 'fast' || serviceTier == 'priority';
}

/// Use the same resolved settings for presentation and submission.
TurnSettings resolveTurnSettings(
  List<RemoteModel> models,
  TurnSettings value, {
  String? model,
  String? effort,
  bool useCatalogDefault = true,
}) {
  final name =
      value.model ??
      model ??
      (useCatalogDefault
          ? models.where((candidate) => candidate.isDefault).firstOrNull?.model
          : null);
  final entry = models
      .where((candidate) => candidate.model == name)
      .firstOrNull;
  return TurnSettings(
    model: name,
    effort:
        (value.model != null ? value.effort : effort) ??
        entry?.defaultReasoningEffort,
    serviceTier: value.serviceTier,
  );
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
