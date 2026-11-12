import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:codex_go/infrastructure/platform/connection_lifecycle.dart';
import 'package:codex_go/l10n/strings.dart';
import 'package:codex_go/runtime/codex_runtime.dart';
import 'package:codex_go/features/workspace/workspace_shell.dart';

import 'theme.dart';

class CodexGoApp extends StatefulWidget {
  const CodexGoApp({
    required this.runtime,
    this.observeLifecycle = true,
    super.key,
  });
  final CodexRuntime runtime;
  final bool observeLifecycle;
  @override
  State<CodexGoApp> createState() => _CodexGoAppState();
}

class _CodexGoAppState extends State<CodexGoApp> {
  ConnectionLifecycle? _lifecycle;
  late final Listenable _preferences;
  @override
  void initState() {
    super.initState();
    _preferences = Listenable.merge([
      widget.runtime.languagePreference,
      widget.runtime.appearancePreference,
    ]);
    if (widget.observeLifecycle) {
      widget.runtime.observeNetwork();
      _lifecycle = ConnectionLifecycle(
        onBackground: widget.runtime.enterBackground,
        onForeground: widget.runtime.restoreForegroundConnection,
      );
      WidgetsBinding.instance.addObserver(_lifecycle!);
    }
  }

  @override
  void dispose() {
    if (_lifecycle != null) WidgetsBinding.instance.removeObserver(_lifecycle!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _preferences,
    builder: (context, _) => MaterialApp(
      title: 'Codex Go',
      builder: (context, child) {
        final colors = Theme.of(context).colorScheme;
        final overlay = Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlay.copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: colors.surfaceContainerLowest,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      debugShowCheckedModeBanner: false,
      locale: widget.runtime.languageCode == null
          ? null
          : Locale(widget.runtime.languageCode!),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: goTheme(Brightness.light),
      darkTheme: goTheme(Brightness.dark),
      themeMode: switch (widget.runtime.appearance) {
        AppAppearance.system => ThemeMode.system,
        AppAppearance.light => ThemeMode.light,
        AppAppearance.dark => ThemeMode.dark,
      },
      home: WorkspaceShell(runtime: widget.runtime),
    ),
  );
}
