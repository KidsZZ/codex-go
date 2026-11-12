// 基于 Android-SSH-Codex 的已验证实现改编；原作者版权与 MIT 许可见 LICENSE。
import 'package:flutter/material.dart';

import 'package:codex_go/infrastructure/storage/host_profile.dart';
import 'package:codex_go/infrastructure/ssh_config/ssh_config.dart';
import 'package:codex_go/infrastructure/ssh_config/ssh_environment.dart';
import 'package:codex_go/l10n/strings.dart';

final class ProfileDraft {
  const ProfileDraft(this.profile, this.secret);

  final HostProfile profile;
  final HostSecret secret;
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({required this.secret, this.profile, super.key});

  final HostProfile? profile;
  final HostSecret secret;

  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final _formKey = GlobalKey<FormState>();
  final _advancedSsh = ExpansibleController();
  late final TextEditingController _label;
  late final TextEditingController _host;
  late final TextEditingController _user;
  late final TextEditingController _port;
  late final TextEditingController _password;
  late final TextEditingController _privateKey;
  late final TextEditingController _passphrase;
  late final TextEditingController _jumpPassword;
  late final TextEditingController _jumpPrivateKey;
  late final TextEditingController _jumpPassphrase;
  late final TextEditingController _jumpHost;
  late final TextEditingController _jumpUser;
  late final TextEditingController _jumpPort;
  late final TextEditingController _connectTimeout;
  late final TextEditingController _authTimeout;
  late final TextEditingController _keepAliveInterval;
  late final TextEditingController _config;
  late final TextEditingController _alias;
  late final TextEditingController _environment;
  late final TextEditingController _customAppServerSocket;
  late HostAuthMethod _authMethod;
  late AppServerMode _appServerMode;
  late bool _useJump;
  String? _jumpIdentityHint;
  String? _importError;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _label = TextEditingController(text: profile?.label ?? '');
    _host = TextEditingController(text: profile?.hostName ?? '');
    _user = TextEditingController(text: profile?.user ?? '');
    _port = TextEditingController(text: '${profile?.port ?? 22}');
    _password = TextEditingController(text: widget.secret.password ?? '');
    _privateKey = TextEditingController(text: widget.secret.privateKey ?? '');
    _passphrase = TextEditingController(text: widget.secret.passphrase ?? '');
    _jumpPassword = TextEditingController(
      text: widget.secret.jumpPassword ?? '',
    );
    _jumpPrivateKey = TextEditingController(
      text: widget.secret.jumpPrivateKey ?? '',
    );
    _jumpPassphrase = TextEditingController(
      text: widget.secret.jumpPassphrase ?? '',
    );
    _config = TextEditingController();
    _alias = TextEditingController(text: profile?.label ?? '');
    _environment = TextEditingController(
      text: formatSshEnvironmentLines(profile?.environment ?? const {}),
    );
    _customAppServerSocket = TextEditingController(
      text: profile?.customAppServerSocket ?? '',
    );
    _authMethod = profile?.authMethod ?? HostAuthMethod.password;
    _appServerMode = profile?.appServerMode ?? AppServerMode.shared;
    final jump = profile?.proxyJump;
    _useJump = jump != null;
    _jumpIdentityHint = jump?.identityFileHint;
    _jumpHost = TextEditingController(text: jump?.hostName ?? '');
    _jumpUser = TextEditingController(text: jump?.user ?? '');
    _jumpPort = TextEditingController(text: '${jump?.port ?? 22}');
    final options = profile?.sshOptions ?? const SshConnectionOptions();
    _connectTimeout = TextEditingController(
      text: '${options.connectTimeoutSeconds}',
    );
    _authTimeout = TextEditingController(text: '${options.authTimeoutSeconds}');
    _keepAliveInterval = TextEditingController(
      text: '${options.keepAliveIntervalSeconds}',
    );
  }

  @override
  void dispose() {
    _advancedSsh.dispose();
    for (final controller in [
      _label,
      _host,
      _user,
      _port,
      _password,
      _privateKey,
      _passphrase,
      _jumpPassword,
      _jumpPrivateKey,
      _jumpPassphrase,
      _jumpHost,
      _jumpUser,
      _jumpPort,
      _connectTimeout,
      _authTimeout,
      _keepAliveInterval,
      _config,
      _alias,
      _environment,
      _customAppServerSocket,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  bool _showPassword = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 手机使用完整页面，表单宽度只在大屏收敛；键盘由 Scaffold 统一避让。
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.profile == null
              ? context.l10n.addSshHost
              : context.l10n.editSshHost,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(
              top: false,
              bottom: false,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Form(
                    key: _formKey,
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.terminal_rounded,
                                  color: scheme.onPrimaryContainer,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    context.l10n.secureConnectionHint,
                                    style: TextStyle(
                                      color: scheme.onPrimaryContainer,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: const EdgeInsets.only(bottom: 8),
                            shape: const Border(),
                            collapsedShape: const Border(),
                            leading: const Icon(
                              Icons.file_download_outlined,
                              size: 20,
                            ),
                            title: Text(context.l10n.importSshConfig),
                            children: [
                              _field(
                                _config,
                                context.l10n.sshConfigContents,
                                lines: 4,
                                maxLines: 8,
                                monospace: true,
                              ),
                              _field(_alias, context.l10n.hostAlias),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: _import,
                                  icon: const Icon(
                                    Icons.file_download_outlined,
                                  ),
                                  label: Text(context.l10n.importConfig),
                                ),
                              ),
                              if (_importError != null)
                                Text(
                                  _importError!,
                                  style: TextStyle(color: scheme.error),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _EditorSection(
                            title: context.l10n.connectionDetails,
                            icon: Icons.dns_outlined,
                            children: [
                              _field(
                                _label,
                                context.l10n.hostName,
                                hint: context.l10n.myDevelopmentMachine,
                                validator: _required,
                              ),
                              _field(
                                _host,
                                context.l10n.hostNameOrIp,
                                hint: '192.168.1.10',
                                validator: _required,
                                keyboard: TextInputType.url,
                              ),
                              _responsivePair(
                                _field(
                                  _user,
                                  context.l10n.sshUser,
                                  hint: 'developer',
                                  validator: _required,
                                ),
                                _field(
                                  _port,
                                  context.l10n.port,
                                  validator: _portValidator,
                                  keyboard: TextInputType.number,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          _EditorSection(
                            title: context.l10n.authentication,
                            icon: Icons.key_outlined,
                            children: [
                              _responsivePair(
                                _EditorChoice(
                                  title: context.l10n.password,
                                  icon: Icons.password_rounded,
                                  selected:
                                      _authMethod == HostAuthMethod.password,
                                  onTap: () => setState(
                                    () => _authMethod = HostAuthMethod.password,
                                  ),
                                ),
                                _EditorChoice(
                                  title: context.l10n.privateKey,
                                  icon: Icons.key_outlined,
                                  selected:
                                      _authMethod == HostAuthMethod.privateKey,
                                  onTap: () => setState(
                                    () =>
                                        _authMethod = HostAuthMethod.privateKey,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (_authMethod == HostAuthMethod.password)
                                TextFormField(
                                  controller: _password,
                                  obscureText: !_showPassword,
                                  enableSuggestions: false,
                                  autocorrect: false,
                                  decoration: InputDecoration(
                                    labelText: context.l10n.password,
                                    suffixIcon: IconButton(
                                      tooltip: _showPassword
                                          ? context.l10n.hidePassword
                                          : context.l10n.showPassword,
                                      onPressed: () => setState(
                                        () => _showPassword = !_showPassword,
                                      ),
                                      icon: Icon(
                                        _showPassword
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                    ),
                                  ),
                                )
                              else ...[
                                _field(
                                  _privateKey,
                                  context.l10n.opensshPrivateKey,
                                  lines: 5,
                                  maxLines: 10,
                                  monospace: true,
                                ),
                                _field(
                                  _passphrase,
                                  context.l10n.keyPassphrase,
                                  obscure: true,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 20),
                          _EditorSection(
                            title: context.l10n.codexService,
                            icon: Icons.hub_outlined,
                            children: [
                              _EditorChoice(
                                title: context.l10n.sharedMode,
                                description: context.l10n.sharedModeDescription,
                                icon: Icons.devices_outlined,
                                selected:
                                    _appServerMode == AppServerMode.shared,
                                onTap: () => setState(
                                  () => _appServerMode = AppServerMode.shared,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _EditorChoice(
                                title: context.l10n.customMode,
                                description: context.l10n.customModeDescription,
                                icon: Icons.settings_ethernet,
                                selected:
                                    _appServerMode == AppServerMode.custom,
                                onTap: () => setState(
                                  () => _appServerMode = AppServerMode.custom,
                                ),
                              ),
                              if (_appServerMode == AppServerMode.custom) ...[
                                const SizedBox(height: 16),
                                _field(
                                  _customAppServerSocket,
                                  context.l10n.appServerUnixSocket,
                                  hint: '/run/user/1000/codex.sock',
                                  monospace: true,
                                  validator: _customSocketValidator,
                                ),
                              ],
                              const SizedBox(height: 10),
                              _EditorChoice(
                                title: context.l10n.isolatedMode,
                                description:
                                    context.l10n.isolatedModeDescription,
                                icon: Icons.lock_outline,
                                selected:
                                    _appServerMode == AppServerMode.isolated,
                                onTap: () => setState(
                                  () => _appServerMode = AppServerMode.isolated,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Card(
                            child: ExpansionTile(
                              controller: _advancedSsh,
                              maintainState: true,
                              shape: const Border(),
                              collapsedShape: const Border(),
                              tilePadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              childrenPadding: const EdgeInsets.fromLTRB(
                                16,
                                4,
                                16,
                                16,
                              ),
                              leading: Icon(
                                Icons.tune_rounded,
                                color: scheme.primary,
                                size: 21,
                              ),
                              title: Text(context.l10n.advancedSsh),
                              subtitle: Text(
                                context
                                    .l10n
                                    .jumpHostTimeoutsAndEnvironmentVariables,
                              ),
                              children: [
                                SwitchListTile.adaptive(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(context.l10n.useJumpHost),
                                  subtitle: Text(
                                    context
                                        .l10n
                                        .phoneJumpHostTargetOneProxyjumpHop,
                                  ),
                                  value: _useJump,
                                  onChanged: (value) =>
                                      setState(() => _useJump = value),
                                ),
                                const SizedBox(height: 12),
                                if (_useJump) ...[
                                  _field(
                                    _jumpHost,
                                    context.l10n.jumpHostNameOrIp,
                                    validator: _required,
                                  ),
                                  _responsivePair(
                                    _field(
                                      _jumpUser,
                                      context.l10n.jumpUser,
                                      validator: _required,
                                    ),
                                    _field(
                                      _jumpPort,
                                      context.l10n.jumpPort,
                                      keyboard: TextInputType.number,
                                      validator: _portValidator,
                                    ),
                                  ),
                                  _field(
                                    _jumpPassword,
                                    context.l10n.jumpPassword,
                                    obscure: true,
                                  ),
                                  _field(
                                    _jumpPrivateKey,
                                    context.l10n.jumpOpensshPrivateKey,
                                    lines: 4,
                                    maxLines: 8,
                                    monospace: true,
                                  ),
                                  _field(
                                    _jumpPassphrase,
                                    context.l10n.jumpKeyPassphrase,
                                    obscure: true,
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 16),
                                    child: Text(
                                      context
                                          .l10n
                                          .jumpCredentialsAreIndependentLeaveUnusedFieldsEmpty,
                                    ),
                                  ),
                                ],
                                _numberField(
                                  _connectTimeout,
                                  context.l10n.connectTimeoutSeconds,
                                  1,
                                  120,
                                ),
                                _numberField(
                                  _authTimeout,
                                  context.l10n.authenticationTimeoutSeconds,
                                  1,
                                  120,
                                ),
                                _numberField(
                                  _keepAliveInterval,
                                  context.l10n.keepaliveIntervalSeconds,
                                  0,
                                  300,
                                  helper: context.l10n.keepAliveHelp,
                                ),
                                _field(
                                  _environment,
                                  context.l10n.environmentVariables,
                                  lines: 3,
                                  maxLines: 8,
                                  monospace: true,
                                  hint: 'KEY=value',
                                  validator: _environmentValidator,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.check_rounded),
                      label: Text(context.l10n.save),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    String? Function(String?)? validator,
    TextInputType? keyboard,
    int lines = 1,
    int? maxLines,
    bool monospace = false,
    bool obscure = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboard,
      minLines: lines,
      maxLines: maxLines ?? lines,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      style: monospace
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        alignLabelWithHint: lines > 1,
      ),
    ),
  );

  Widget _responsivePair(Widget first, Widget second) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      if (constraints.maxWidth < 300 * scale) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 8), second],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: first),
          const SizedBox(width: 12),
          Expanded(child: second),
        ],
      );
    },
  );

  void _import() {
    try {
      final resolved = SshConfig.parse(_config.text)
          .resolve(_alias.text.trim());
      final imported = HostProfile.fromResolved(resolved);
      setState(() {
        _label.text = imported.label;
        _host.text = imported.hostName;
        _user.text = imported.user;
        _port.text = '${imported.port}';
        _authMethod = imported.authMethod;
        final jump = imported.proxyJump;
        _useJump = jump != null;
        _jumpIdentityHint = jump?.identityFileHint;
        _jumpHost.text = jump?.hostName ?? '';
        _jumpUser.text = jump?.user ?? '';
        _jumpPort.text = '${jump?.port ?? 22}';
        _connectTimeout.text = '${imported.sshOptions.connectTimeoutSeconds}';
        _authTimeout.text = '${imported.sshOptions.authTimeoutSeconds}';
        _keepAliveInterval.text =
            '${imported.sshOptions.keepAliveIntervalSeconds}';
        _environment.text = formatSshEnvironmentLines(imported.environment);
        _importError = resolved.warnings.isEmpty
            ? null
            : resolved.warnings.join('\n');
      });
    } catch (error) {
      setState(
        () => _importError = context.l10n.importFailed(error.toString()),
      );
    }
  }

  void _save() {
    if (!_formKey.currentState!.validate()) {
      _advancedSsh.expand();
      return;
    }
    final environment = parseSshEnvironmentLines(_environment.text);
    final label = _label.text.trim();
    final safeLabel = label.toLowerCase().replaceAll(
      RegExp('[^a-z0-9._-]+'),
      '-',
    );
    final id =
        widget.profile?.id ??
        '${safeLabel.isEmpty ? 'host' : safeLabel}-'
            '${DateTime.now().microsecondsSinceEpoch}';
    Navigator.pop(
      context,
      ProfileDraft(
        HostProfile(
          id: id,
          label: label,
          hostName: _host.text.trim(),
          user: _user.text.trim(),
          port: int.parse(_port.text),
          authMethod: _authMethod,
          identityFileHint: widget.profile?.identityFileHint,
          proxyJump: _useJump
              ? JumpHostProfile(
                  hostName: _jumpHost.text.trim(),
                  user: _jumpUser.text.trim(),
                  port: int.parse(_jumpPort.text),
                  identityFileHint: _jumpIdentityHint,
                )
              : null,
          sshOptions: SshConnectionOptions(
            connectTimeoutSeconds: int.parse(_connectTimeout.text),
            authTimeoutSeconds: int.parse(_authTimeout.text),
            keepAliveIntervalSeconds: int.parse(_keepAliveInterval.text),
          ),
          environment: environment,
          appServerMode: _appServerMode,
          customAppServerSocket: _appServerMode == AppServerMode.custom
              ? _customAppServerSocket.text.trim()
              : null,
        ),
        HostSecret(
          password: _password.text,
          privateKey: _privateKey.text,
          passphrase: _passphrase.text,
          jumpPassword: _useJump ? _jumpPassword.text : null,
          jumpPrivateKey: _useJump ? _jumpPrivateKey.text : null,
          jumpPassphrase: _useJump ? _jumpPassphrase.text : null,
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? context.l10n.requiredField : null;

  Widget _numberField(
    TextEditingController controller,
    String label,
    int min,
    int max, {
    String? helper,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper ?? context.l10n.secondsRange(min, max),
      ),
      validator: (text) {
        final value = int.tryParse(text ?? '');
        return value == null || value < min || value > max
            ? context.l10n.secondsRangeError((min).toString(), (max).toString())
            : null;
      },
    ),
  );

  String? _environmentValidator(String? value) {
    try {
      parseSshEnvironmentLines(value ?? '');
      return null;
    } on SshEnvironmentException catch (error) {
      final strings = context.l10n;
      if (error.kind == SshEnvironmentErrorKind.duplicateName) {
        return strings.environmentDuplicate(
          error.variable ?? '',
          error.line ?? 1,
        );
      }
      final reason = switch (error.kind) {
        SshEnvironmentErrorKind.missingEquals =>
          strings.environmentMissingEquals,
        SshEnvironmentErrorKind.invalidName => strings.environmentInvalidName,
        SshEnvironmentErrorKind.invalidValue => strings.environmentInvalidValue,
        SshEnvironmentErrorKind.duplicateName => throw StateError(
          'Handled above',
        ),
      };
      return strings.environmentLineError(error.line ?? 1, reason);
    }
  }

  String? _portValidator(String? value) {
    final port = int.tryParse(value ?? '');
    return port == null || port < 1 || port > 65535
        ? context.l10n.invalidPort
        : null;
  }

  String? _customSocketValidator(String? value) {
    final configuredSocketPath = value ?? '';
    if (RegExp(r'[\x00-\x1F\x7F]').hasMatch(configuredSocketPath)) {
      return context.l10n.enterAnAbsoluteUnixSocketPath;
    }
    final socketPath = configuredSocketPath.trim();
    if (socketPath.isEmpty || !socketPath.startsWith('/')) {
      return context.l10n.enterAnAbsoluteUnixSocketPath;
    }
    return null;
  }
}

/// 分组标题保持独立层级，内部字段共享表面和边距。
class _EditorSection extends StatelessWidget {
  const _EditorSection({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          ...children,
        ],
      ),
    ),
  );
}

/// 选择状态同时使用边框、颜色与图标表达，不依赖颜色辨识。
class _EditorChoice extends StatelessWidget {
  const _EditorChoice({
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.description,
  });
  final String title;
  final String? description;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      child: Material(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                      if (description != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          description!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    size: 20,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
