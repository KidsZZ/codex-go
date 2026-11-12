part of 'codex_runtime.dart';

/// 附件、文件下载与端口转发职责模块；共享同一个连接代次，避免异步结果跨主机串入。
extension RuntimeFiles on CodexRuntime {
  Future<void> savePortForward(PortForwardRule rule) async {
    if (rule.hostId != _selectedHostId) {
      throw StateError('The selected SSH host changed.');
    }
    await portForwards.upsert(rule);
    await _saveWorkspace();
  }

  Future<void> removePortForward(String id) async {
    await portForwards.remove(id);
    await _saveWorkspace();
  }

  Future<List<ListeningPort>> discoverPorts(String hostId) async {
    final ssh = _ssh;
    if (!isConnected ||
        ssh == null ||
        hostId != _selectedHostId ||
        hostId != _workspaceHostId) {
      throw StateError('Connect to this SSH host to discover ports.');
    }
    final ports = await discoverListeningPorts(ssh.client);
    if (!identical(ssh, _ssh) || hostId != _selectedHostId) {
      throw StateError('SSH connection changed during port discovery.');
    }
    return ports;
  }

  Future<Uri> forwardLoopbackUrl(String hostId, Uri source) async {
    // Validate before creating/persisting any rule. Never log URL query tokens.
    mapForwardedUri(source, 1024);
    if (!isConnected ||
        hostId != _selectedHostId ||
        hostId != _workspaceHostId) {
      throw StateError(
        'Reconnect to this SSH host before opening its localhost URL.',
      );
    }
    final existing = portForwards.loopbackRule(
      hostId,
      source.port,
      source.host,
    );
    final rule =
        existing?.copyWith(enabled: true) ??
        PortForwardRule(
          id: portForwards.newId(),
          hostId: hostId,
          remoteHost: source.host,
          remotePort: source.port,
          scheme: source.scheme,
          label: 'From localhost link',
        );
    await savePortForward(rule);
    if (!isConnected || hostId != _selectedHostId) {
      throw StateError('SSH host changed while opening the forwarded URL.');
    }
    final state = portForwards.stateFor(rule.id);
    if (state.localPort == null) {
      throw StateError(state.error ?? 'Forwarding is waiting for SSH.');
    }
    return mapForwardedUri(source, state.localPort!);
  }

  Future<Uint8List> loadAttachmentImage(String path) async {
    final ssh = _ssh;
    final attempt = _connectionAttempt;
    if (ssh == null) throw StateError('SSH is disconnected');
    final bytes = await readAttachmentImage(ssh.client, path);
    if (!identical(ssh, _ssh) || attempt != _connectionAttempt) {
      throw StateError('Connection changed');
    }
    return bytes;
  }

  Future<RemoteAttachment> uploadAttachmentNow(
    LocalAttachment attachment,
    AttachmentUploadTarget target,
    AttachmentUploadCancellation cancellation, {
    void Function(int acknowledged, int total)? onProgress,
  }) async {
    final profile = selectedHost;
    if (profile == null) throw StateError('Select an SSH host first.');
    final profileId = profile.id;
    final secret = await _store.readSecret(profileId);
    final result = await uploadAttachmentResumable(
      attachment: attachment,
      target: target,
      cancellation: cancellation,
      onProgress: onProgress,
      onRetry: (retry, acknowledged, error) =>
          Diagnostics.record('attachment.uploadRetry', {
            'retry': retry,
            'acknowledgedBytes': acknowledged,
            ...Diagnostics.errorFields(error),
          }),
      connect: () async {
        cancellation.check();
        if (_selectedHostId != profileId) {
          throw StateError('Selected host changed during attachment upload.');
        }
        final connection = await _connector.connect(
          profile,
          secret,
          prompt: (_) async => false,
          diagnosticAttempt: _connectionAttempt,
          diagnosticRole: 'attachment-upload',
        );
        if (cancellation.isCancelled || _selectedHostId != profileId) {
          await connection.close(reason: 'attachment_upload_cancelled');
          cancellation.check();
          throw StateError('Selected host changed during attachment upload.');
        }
        return SftpAttachmentUploadSession.open(connection, target);
      },
    );
    if (_selectedHostId != profileId) {
      throw StateError('Selected host changed during attachment upload.');
    }
    return result;
  }

  void cancelDownload() {
    final cancellation = _downloadCancellation;
    if (cancellation == null || cancellation.isCancelled) return;
    Diagnostics.record('download.cancelRequested');
    cancellation.cancel();
  }

  Future<bool> downloadFile(
    String link, {
    void Function(downloads.DownloadProgress)? onProgress,
  }) => _receiveRemoteFile(
    link,
    onProgress: onProgress,
    openFile: (file, name) async {
      final size = await file.length();
      onProgress?.call(downloads.DownloadProgress(size, size, saving: true));
      return await Attachments.channel.invokeMethod<bool>('saveDownload', {
            'path': file.path,
            'name': name,
          }) ??
          false;
    },
  );

  Future<bool> previewVideo(
    String link, {
    void Function(downloads.DownloadProgress)? onProgress,
    VoidCallback? onReady,
  }) => _receiveRemoteFile(
    link,
    onProgress: onProgress,
    purpose: 'video-preview',
    openFile: (file, name) async {
      onReady?.call();
      return await Attachments.channel.invokeMethod<bool>('playVideo', {
            'path': file.path,
            'name': name,
          }) ??
          false;
    },
  );

  Future<bool> _receiveRemoteFile(
    String link, {
    required Future<bool> Function(File file, String name) openFile,
    String purpose = 'download',
    void Function(downloads.DownloadProgress)? onProgress,
  }) async {
    if (_downloadingFile) throw StateError('A download is already active');
    if (!Attachments.supported) throw UnsupportedError('Android download only');
    final ssh = _ssh;
    final profile = selectedHost;
    final path = downloads.remoteFilePath(link, selectedTask?.cwd ?? '');
    if (ssh == null || profile == null || path == null) {
      throw StateError('Remote file unavailable');
    }
    _downloadingFile = true;
    final cancellation = DownloadCancellation();
    _downloadCancellation = cancellation;
    Directory? temporary;
    var stage = 'temporary_storage';
    try {
      final cache = await Attachments.channel.invokeMethod<String>(
        'downloadDirectory',
      );
      if (cache == null) throw StateError('No download directory');
      temporary = await Directory(cache).createTemp('codex-download-');
      final file = File('${temporary.path}/payload.bin');
      stage = 'ssh_transfer';
      final secret = await _store.readSecret(profile.id);
      await downloadResumableFile(
        destination: file,
        cancellation: cancellation,
        connect: () async {
          cancellation.check();
          final connection = await _connector.connect(
            profile,
            secret,
            prompt: (_) async => false,
            diagnosticRole: purpose,
          );
          if (cancellation.isCancelled) {
            await connection.close(reason: 'download_cancelled');
            throw DownloadCancelled();
          }
          return SftpDownloadSource.open(connection, path);
        },
        onProgress: onProgress,
        onRetry: (retry, received, error) =>
            Diagnostics.record('download.retry', {
              'purpose': purpose,
              'retry': retry,
              'receivedBytes': received,
              ...Diagnostics.errorFields(error),
            }),
      );
      cancellation.check();
      stage = purpose == 'video-preview' ? 'phone_preview' : 'phone_save';
      // The player owns the file until it closes. Do not delete the temporary
      // payload while the native decoder might still seek within it.
      return await openFile(file, path.split('/').last);
    } catch (error) {
      Diagnostics.record('download.failed', {
        'purpose': purpose,
        'stage': stage,
        if (error is downloads.FileDownloadException) ...{
          'transferStage': error.stage,
          'receivedBytes': error.received,
          'exitCode': error.exitCode,
        },
        ...Diagnostics.errorFields(
          error is downloads.FileDownloadException
              ? error.cause ?? error
              : error,
        ),
      });
      rethrow;
    } finally {
      try {
        await temporary?.delete(recursive: true);
      } finally {
        _downloadingFile = false;
        _downloadCancellation = null;
      }
    }
  }
}
