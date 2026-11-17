import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:codex_go/infrastructure/relay/crypto/noise_ik.dart';
import 'package:codex_go/infrastructure/relay/relay_endpoint.dart';
import 'package:codex_go/infrastructure/relay/relay_rpc_transport.dart';
import 'package:codex_go/infrastructure/storage/host_profile.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';

/// 扫码只解析信任信息；用户确认服务器和电脑身份后才开始连接。
class RelayPairingPage extends StatefulWidget {
  const RelayPairingPage({required this.runtime, super.key});
  final CodexRuntime runtime;
  @override
  State<RelayPairingPage> createState() => _RelayPairingPageState();
}

class _RelayPairingPageState extends State<RelayPairingPage>
    with WidgetsBindingObserver {
  final _scanner = MobileScannerController(formats: [BarcodeFormat.qrCode]);
  final _text = TextEditingController();
  final _identity = DeviceIdentity.generate();
  RelayPairingOffer? _offer;
  RelayRpcTransport? _transport;
  bool _busy = false;
  bool _scanned = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _setCamera(bool active) async {
    try {
      if (active) {
        await _scanner.start();
      } else {
        await _scanner.stop();
      }
    } catch (_) {
      if (mounted && !_scanned) {
        setState(() => _error = context.l10n.relayCameraUnavailable);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 权限弹窗也会改变生命周期；尚未获准时交由扫码组件完成初始化。
    if (!_scanner.value.hasCameraPermission) return;
    unawaited(_setCamera(state == AppLifecycleState.resumed && !_scanned));
  }

  void _read(String value) {
    if (_busy || _scanned) return;
    try {
      final offer = RelayPairingOffer.parse(value);
      _scanned = true;
      unawaited(_setCamera(false));
      _text.clear();
      setState(() {
        _offer = offer;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = context.l10n.relayInvalidCode);
    }
  }

  Future<void> _pair() async {
    final offer = _offer;
    if (offer == null || _busy) return;
    if (!offer.expires.isAfter(DateTime.now())) {
      setState(() => _error = context.l10n.relayInvalidCode);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final transport = await RelayRpcTransport.connect(
        endpoint: offer.endpoint,
        privateKey: _identity.privateKeyBase64Url,
        pairingSecret: offer.secret,
        onCreated: (value) {
          _transport = value;
          if (!mounted) unawaited(value.close());
        },
      );
      await transport.close();
      if (!mounted) return;
      final profile = HostProfile.paired(
        id: 'relay-${offer.endpoint.hostKey}',
        label: offer.name,
        relay: offer.endpoint,
      );
      // 先验证授权，再将私钥写入现有平台安全存储；一次性配对秘密不持久化。
      if (widget.runtime.selectedHostId == profile.id) {
        await widget.runtime.disconnect();
      }
      await widget.runtime.saveProfile(
        profile,
        HostSecret(relayPrivateKey: _identity.privateKeyBase64Url),
      );
      if (mounted) Navigator.pop(context, profile);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.relayPairFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_transport?.close());
    unawaited(_scanner.dispose());
    _text.dispose();
    _identity.destroy();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final offer = _offer;
    return Scaffold(
      appBar: AppBar(title: Text(l.relayPairTitle)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(l.relayPairDescription),
          const SizedBox(height: 20),
          if (offer == null) ...[
            SizedBox(
              height: 280,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: MobileScanner(
                  controller: _scanner,
                  onDetect: (capture) {
                    if (!mounted || _scanned) return;
                    for (final barcode in capture.barcodes) {
                      final value = barcode.rawValue;
                      if (value != null) {
                        _read(value);
                        break;
                      }
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _text,
              minLines: 1,
              maxLines: 3,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l.relayPasteCode,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () => _read(_text.text),
              child: Text(l.relayReadCode),
            ),
          ] else ...[
            Text(offer.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SelectableText('${l.relayServer}: ${offer.endpoint.url}'),
            const SizedBox(height: 12),
            SelectableText(
              '${l.relayComputerFingerprint}\n${relayFingerprint(offer.endpoint.hostKey)}',
            ),
            const SizedBox(height: 16),
            SelectableText(
              '${l.relayPhoneFingerprint}\n${relayFingerprint(_identity.publicKeyBase64Url)}',
            ),
            const SizedBox(height: 16),
            Text(l.relayConfirmComputer),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _pair,
              icon: const Icon(Icons.phonelink_lock),
              label: Text(l.relayStartPairing),
            ),
            if (!_busy)
              TextButton(
                onPressed: () {
                  setState(() {
                    _offer = null;
                    _scanned = false;
                    _error = null;
                  });
                  unawaited(_setCamera(true));
                },
                child: Text(l.relayScanAgain),
              ),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(l.relayWaitingApproval),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          Text(l.relayDemoScope),
        ],
      ),
    );
  }
}
