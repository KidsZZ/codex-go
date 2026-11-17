/// 元数据来自实际 APK；渠道限定应用身份，实际构建号决定是否升级。
class UpdateRelease {
  const UpdateRelease({
    required this.version,
    required this.channel,
    required this.build,
    required this.size,
    required this.sha256,
    required this.minSdk,
    required this.url,
    required this.notes,
    required this.publishedAt,
  });
  final String version;
  final String channel;
  final int build;
  final int size;
  final String sha256;
  final int minSdk;
  final Uri url;
  final String notes;
  final DateTime? publishedAt;

  Map<String, Object?> toCache() => {
    'version': version,
    'channel': channel,
    'build': build,
    'size': size,
    'sha256': sha256,
    'minSdk': minSdk,
    'url': url.toString(),
    'notes': notes,
    'publishedAt': publishedAt?.toIso8601String(),
  };

  factory UpdateRelease.fromCache(Map<String, dynamic> data) => UpdateRelease(
    version: data['version'] as String,
    channel: data['channel'] as String,
    build: data['build'] as int,
    size: data['size'] as int,
    sha256: data['sha256'] as String,
    minSdk: data['minSdk'] as int,
    url: releaseAssetUri(data['url'], 'v${data['version']}'),
    notes: data['notes'] as String,
    publishedAt: DateTime.tryParse(data['publishedAt'] as String? ?? ''),
  );

  factory UpdateRelease.parse(
    Map<String, dynamic> manifest,
    Map<String, dynamic> release, {
    required String channel,
  }) {
    final version = manifest['versionName'];
    final build = manifest['versionCode'];
    final size = manifest['size'];
    final digest = manifest['sha256'];
    final minSdk = manifest['minSdk'];
    final name = manifest['file'];
    final pattern = channel == 'beta'
        ? RegExp(r'^\d+\.\d+\.\d+-beta\.[1-9]\d*$')
        : RegExp(r'^\d+\.\d+\.\d+$');
    if (!{'beta', 'release'}.contains(channel) ||
        manifest['schemaVersion'] != 1 ||
        manifest['channel'] != channel ||
        manifest['packageName'] !=
            (channel == 'beta' ? 'dev.codexgo.app.beta' : 'dev.codexgo.app') ||
        manifest['abi'] != 'arm64-v8a' ||
        version is! String ||
        !pattern.hasMatch(version) ||
        release['tag_name'] != 'v$version' ||
        build is! int ||
        build <= 0 ||
        size is! int ||
        size <= 0 ||
        size > 512 * 1024 * 1024 ||
        minSdk is! int ||
        minSdk < 24 ||
        digest is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
        name != 'codex-go-$version-arm64-v8a-$channel.apk') {
      throw const FormatException('Invalid update manifest');
    }
    final asset = (release['assets'] as List)
        .cast<Map<String, dynamic>>()
        .where((a) => a['name'] == name && a['state'] == 'uploaded')
        .single;
    if (asset['size'] != size) {
      throw const FormatException('Asset size mismatch');
    }
    return UpdateRelease(
      version: version,
      channel: channel,
      build: build,
      size: size,
      sha256: digest,
      minSdk: minSdk,
      url: releaseAssetUri(asset['browser_download_url'], release['tag_name']),
      notes: release['body'] as String? ?? '',
      publishedAt: DateTime.tryParse(release['published_at'] as String? ?? ''),
    );
  }
}

/// 初始地址只接受当前仓库的 HTTPS 附件。
Uri releaseAssetUri(Object? value, Object? tag) {
  final uri = Uri.parse(value as String);
  if (uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !uri.path.startsWith('/KidsZZ/codex-go/releases/download/$tag/')) {
    throw const FormatException('Untrusted release asset');
  }
  return uri;
}

/// 早期正式版没有更新元数据；旧版本不应触发“缺少元数据”的误报。
bool releaseIsNotNewer(String tag, String installed) {
  List<int>? parts(String v) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(v);
    return match == null
        ? null
        : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }

  final remote = parts(tag), local = parts(installed);
  if (remote == null || local == null) return false;
  for (var i = 0; i < 3; i++) {
    if (remote[i] != local[i]) return remote[i] < local[i];
  }
  return true;
}
