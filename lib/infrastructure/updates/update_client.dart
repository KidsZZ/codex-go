import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'update_release.dart';

class UpdateFailure implements Exception {
  const UpdateFailure(this.code);
  final String code;
}

/// 更新网络与 SSH 完全独立；每个操作持有自己的连接，可取消且有超时。
class UpdateClient {
  UpdateClient() {
    _client.connectionTimeout = const Duration(seconds: 15);
    _client.userAgent = 'Codex-Go-Updater';
  }
  final HttpClient _client = HttpClient();
  bool _closed = false;
  void close() {
    _closed = true;
    _client.close(force: true);
  }

  Future<HttpClientResponse> _get(Uri initial) async {
    var uri = initial;
    for (var hop = 0; hop < 6; hop++) {
      if (_closed) throw const UpdateFailure('cancelled');
      final allowed = {
        'api.github.com',
        'github.com',
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      };
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !allowed.contains(uri.host)) {
        throw const UpdateFailure('metadata');
      }
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      if (uri.host == 'api.github.com') {
        request.headers.set('Accept', 'application/vnd.github+json');
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        // 不读取重定向正文，避免异常响应无限占用连接。
        await response.listen((_) {}).cancel();
        if (location == null) throw const UpdateFailure('metadata');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const UpdateFailure('network');
  }

  Future<Map<String, dynamic>?> _json(
    Uri uri, {
    bool allowMissing = false,
  }) async {
    final response = await _get(uri);
    if (allowMissing && response.statusCode == 404) {
      await response.listen((_) {}).cancel();
      return null;
    }
    if (response.statusCode != 200) {
      throw UpdateFailure(
        {403, 429}.contains(response.statusCode) ? 'rateLimit' : 'network',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.add(chunk);
      if (bytes.length > 1024 * 1024) throw const UpdateFailure('metadata');
    }
    return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  }

  Future<UpdateRelease?> latest(
    String installedVersion, {
    required String channel,
  }) async {
    if (channel == 'beta') return _latestBeta();
    final release = await _json(
      Uri.https('api.github.com', '/repos/KidsZZ/codex-go/releases/latest'),
      allowMissing: true,
    );
    if (release == null) return null;
    if (release['draft'] != false || release['prerelease'] != false) {
      throw const UpdateFailure('metadata');
    }
    final assets = (release['assets'] as List).cast<Map<String, dynamic>>();
    final manifests = assets.where(
      (a) => a['name'] == 'update.json' && a['state'] == 'uploaded',
    );
    if (manifests.isEmpty &&
        releaseIsNotNewer(release['tag_name'] as String, installedVersion)) {
      return null;
    }
    if (manifests.length != 1) throw const UpdateFailure('metadata');
    final manifest = await _json(
      releaseAssetUri(
        manifests.single['browser_download_url'],
        release['tag_name'],
      ),
    );
    return UpdateRelease.parse(manifest!, release, channel: 'release');
  }

  Future<UpdateRelease?> _latestBeta() async {
    final candidates = <Map<String, dynamic>>[];
    for (var page = 1; page <= 3; page++) {
      final response = await _get(
        Uri.https('api.github.com', '/repos/KidsZZ/codex-go/releases', {
          'per_page': '30',
          'page': '$page',
        }),
      );
      if (response.statusCode != 200) {
        throw UpdateFailure(
          {403, 429}.contains(response.statusCode) ? 'rateLimit' : 'network',
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.add(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const UpdateFailure('metadata');
        }
      }
      final releases = (jsonDecode(utf8.decode(bytes.takeBytes())) as List)
          .cast<Map<String, dynamic>>();
      candidates.addAll(
        releases.where(
          (r) =>
              r['draft'] == false &&
              r['prerelease'] == true &&
              RegExp(r'^v\d+\.\d+\.\d+-beta\.[1-9]\d*$')
                  .hasMatch(r['tag_name'] as String),
        ),
      );
      if (releases.length < 30) break;
    }
    if (candidates.isEmpty) return null;
    List<int> parts(Map<String, dynamic> r) =>
        RegExp(r'\d+')
            .allMatches(r['tag_name'] as String)
            .map((m) => int.parse(m[0]!))
            .toList();
    candidates.sort((a, b) {
      final left = parts(a), right = parts(b);
      for (var i = 0; i < left.length; i++) {
        final order = right[i].compareTo(left[i]);
        if (order != 0) return order;
      }
      return 0;
    });
    final release = candidates.first;
    final asset = (release['assets'] as List)
        .cast<Map<String, dynamic>>()
        .where((a) => a['name'] == 'update.json' && a['state'] == 'uploaded')
        .single;
    final manifest = await _json(
      releaseAssetUri(asset['browser_download_url'], release['tag_name']),
    );
    return UpdateRelease.parse(manifest!, release, channel: 'beta');
  }

  Future<void> download(
    UpdateRelease release,
    File target,
    void Function(int) progress,
  ) async {
    final response = await _get(release.url);
    if (response.statusCode != 200) throw const UpdateFailure('network');
    if (response.contentLength >= 0 && response.contentLength != release.size) {
      throw const UpdateFailure('integrity');
    }
    final output = await target.open(mode: FileMode.write);
    var received = 0;
    try {
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > release.size) throw const UpdateFailure('integrity');
        await output.writeFrom(chunk);
        progress(received);
      }
      if (received != release.size) throw const UpdateFailure('integrity');
      await output.flush();
    } finally {
      await output.close();
    }
  }
}
