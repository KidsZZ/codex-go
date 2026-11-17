import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'update_client.dart';
import 'update_release.dart';

export 'update_release.dart';

enum UpdatePhase { idle, checking, downloading, verifying, ready, installing }

/// 由应用持有，切换页面不打断下载；后台检查只更新状态，不主动弹窗。
class UpdateController extends ChangeNotifier with WidgetsBindingObserver {
  static const _channel = MethodChannel('codex_go/updates');
  bool _disposed = false;
  bool _initializing = false;
  bool initialized = false;
  bool official = false;
  bool autoCheck = true;
  bool upToDate = false;
  bool permissionRequired = false;
  String version = '';
  String channel = 'preview';
  int build = 0;
  int sdk = 0;
  int? skipped;
  int lastAttempt = 0;
  String? directory;
  String? error;
  UpdateRelease? release;
  UpdatePhase phase = UpdatePhase.idle;
  int received = 0;
  UpdateClient? _client;
  bool _cancelled = false;
  String? _apkPath;
  bool get busy => phase != UpdatePhase.idle && phase != UpdatePhase.ready;
  bool get hasUpdate => release != null && release!.build != skipped;
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void start() {
    if (!supported) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(initialize());
  }

  Future<void> initialize() async {
    if (_disposed || _initializing || !supported) return;
    if (initialized) {
      await checkAutomatically();
      return;
    }
    _initializing = true;
    try {
      final data = (await _channel.invokeMapMethod<String, dynamic>('info'))!;
      version = data['versionName'] as String;
      build = data['versionCode'] as int;
      sdk = data['sdk'] as int;
      official = data['official'] as bool;
      channel = data['channel'] as String;
      autoCheck = data['autoCheck'] as bool;
      lastAttempt = data['lastAttempt'] as int;
      skipped = data['skipped'] as int?;
      directory = data['directory'] as String;
      // 损坏的非关键缓存不阻断更新入口，下一次检查会重新获取。
      try {
        final cache = data['release'] as String?;
        final cached = cache == null
            ? null
            : UpdateRelease.fromCache(
                jsonDecode(cache) as Map<String, dynamic>,
              );
        release =
            cached != null && cached.channel == channel && cached.build > build
            ? cached
            : null;
      } catch (_) {
        release = null;
      }
      initialized = true;
      error = null;
    } catch (_) {
      error = 'unavailable';
    } finally {
      _initializing = false;
      _emit();
    }
    if (initialized && !_disposed) await checkAutomatically();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(initialize());
  }

  Future<void> checkAutomatically() async {
    if (!official ||
        !autoCheck ||
        busy ||
        phase == UpdatePhase.ready ||
        _disposed) {
      return;
    }
    final age = DateTime.now().millisecondsSinceEpoch - lastAttempt;
    if (age >= 0 && age < const Duration(hours: 24).inMilliseconds) return;
    await check();
  }

  Future<void> check({bool manual = false}) async {
    if (busy || _disposed) return;
    if (!initialized) {
      await initialize();
      return;
    }
    if (!official) return;
    // 已经下载的包不因重复检查丢失；安装前仍会重新校验。
    if (phase == UpdatePhase.ready) return;
    phase = UpdatePhase.checking;
    error = null;
    upToDate = false;
    permissionRequired = false;
    if (manual) skipped = null;
    lastAttempt = DateTime.now().millisecondsSinceEpoch;
    _emit();
    final client = UpdateClient();
    _client = client;
    try {
      await _save();
      final candidate = await client
          .latest(version, channel: channel)
          .timeout(const Duration(seconds: 60));
      if (_disposed) return;
      release = candidate != null && candidate.build > build ? candidate : null;
      if (release != null && release!.minSdk > sdk) error = 'unsupported';
      upToDate = release == null;
      await _save();
    } catch (e) {
      if (!_disposed) error = _errorCode(e);
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      phase = UpdatePhase.idle;
      _emit();
    }
  }

  Future<void> setAutoCheck(bool value) async {
    autoCheck = value;
    _emit();
    try {
      await _save();
    } catch (_) {
      error = 'storage';
      _emit();
    }
    if (value) await checkAutomatically();
  }

  Future<void> skip() async {
    if (busy) return;
    skipped = release?.build;
    _emit();
    try {
      await _save();
    } catch (_) {
      error = 'storage';
      _emit();
    }
  }

  Future<void> _save() => _channel.invokeMethod<void>('preferences', {
    'autoCheck': autoCheck,
    'lastAttempt': lastAttempt,
    'skipped': skipped,
    'release': release == null ? null : jsonEncode(release!.toCache()),
  });

  Future<void> download() async {
    final candidate = release;
    if (!official ||
        candidate == null ||
        busy ||
        _disposed ||
        candidate.minSdk > sdk) {
      return;
    }
    phase = UpdatePhase.downloading;
    error = null;
    received = 0;
    _cancelled = false;
    permissionRequired = false;
    _apkPath = null;
    _emit();
    final part = File('$directory/update.part');
    final apk = File('$directory/update.apk');
    final client = UpdateClient();
    _client = client;
    try {
      // 仅清理更新器自己的临时文件，不触碰会话或附件缓存。
      if (await part.exists()) await part.delete();
      if (await apk.exists()) await apk.delete();
      var lastNotice = DateTime.now();
      await client
          .download(candidate, part, (count) {
            received = count;
            final now = DateTime.now();
            if (now.difference(lastNotice).inMilliseconds >= 150 ||
                count == candidate.size) {
              lastNotice = now;
              _emit();
            }
          })
          .timeout(const Duration(minutes: 15));
      if (_cancelled || _disposed) throw const UpdateFailure('cancelled');
      phase = UpdatePhase.verifying;
      _emit();
      await part.rename(apk.path);
      await _channel.invokeMethod<void>(
        'validate',
        _arguments(candidate, apk.path),
      );
      if (_disposed) return;
      _apkPath = apk.path;
      phase = UpdatePhase.ready;
    } catch (e) {
      if (!_disposed && !_cancelled) error = _errorCode(e);
      phase = UpdatePhase.idle;
      await _removeTemporary(apk);
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
      await _removeTemporary(part);
      _emit();
    }
  }

  Future<void> _removeTemporary(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      if (!_disposed) error ??= 'storage';
    }
  }

  void cancelDownload() {
    if (phase != UpdatePhase.downloading) return;
    _cancelled = true;
    _client?.close();
  }

  Map<String, Object> _arguments(UpdateRelease candidate, String path) => {
    'path': path,
    'sha256': candidate.sha256,
    'versionCode': candidate.build,
    'versionName': candidate.version,
    'size': candidate.size,
  };

  Future<void> install() async {
    if (phase != UpdatePhase.ready ||
        _apkPath == null ||
        release == null ||
        _disposed) {
      return;
    }
    phase = UpdatePhase.installing;
    error = null;
    _emit();
    try {
      final result = await _channel.invokeMethod<String>(
        'install',
        _arguments(release!, _apkPath!),
      );
      permissionRequired = result == 'permission';
    } catch (e) {
      error = _errorCode(e);
    } finally {
      phase = UpdatePhase.ready;
      _emit();
    }
  }

  String _errorCode(Object e) => switch (e) {
    UpdateFailure(:final code) => code,
    PlatformException(:final code) => code,
    FormatException() || TypeError() || StateError() => 'metadata',
    FileSystemException() => 'storage',
    _ => 'network',
  };

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _client?.close();
    super.dispose();
  }
}

class UpdateScope extends InheritedNotifier<UpdateController> {
  const UpdateScope({
    required UpdateController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static UpdateController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}
