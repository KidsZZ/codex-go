import 'package:flutter/material.dart';

/// 使用中性纸白与墨蓝建立层级，靛蓝只承担操作、选择和品牌表达。
ThemeData goTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors =
      ColorScheme.fromSeed(
        seedColor: const Color(0xFF4D5DE4),
        brightness: brightness,
      ).copyWith(
        primary: dark ? const Color(0xFFACB7FF) : const Color(0xFF4556D8),
        onPrimary: dark ? const Color(0xFF182158) : Colors.white,
        primaryContainer: dark
            ? const Color(0xFF28335F)
            : const Color(0xFFEEF0FF),
        onPrimaryContainer: dark
            ? const Color(0xFFDBE1FF)
            : const Color(0xFF3344B4),
        secondary: dark ? const Color(0xFF7DD8BC) : const Color(0xFF157D68),
        secondaryContainer: dark
            ? const Color(0xFF193C35)
            : const Color(0xFFE4F5ED),
        onSecondaryContainer: dark
            ? const Color(0xFFC3F5E3)
            : const Color(0xFF175643),
        tertiary: dark ? const Color(0xFFFFC78D) : const Color(0xFFAA651B),
        surface: dark ? const Color(0xFF101522) : const Color(0xFFF7F8FC),
        surfaceContainerLowest: dark ? const Color(0xFF141C2C) : Colors.white,
        surfaceContainerLow: dark
            ? const Color(0xFF192234)
            : const Color(0xFFF0F2F8),
        surfaceContainer: dark
            ? const Color(0xFF202B3E)
            : const Color(0xFFECEFF6),
        surfaceContainerHigh: dark
            ? const Color(0xFF29364B)
            : const Color(0xFFE6EAF3),
        surfaceContainerHighest: dark
            ? const Color(0xFF344159)
            : const Color(0xFFDCE2EF),
        onSurface: dark ? const Color(0xFFEDF1FA) : const Color(0xFF202A40),
        onSurfaceVariant: dark
            ? const Color(0xFFAEBBD0)
            : const Color(0xFF64718A),
        outline: dark ? const Color(0xFF65748E) : const Color(0xFF8691A8),
        outlineVariant: dark
            ? const Color(0xFF2C3950)
            : const Color(0xFFE0E5F0),
        surfaceTint: Colors.transparent,
      );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide(color: colors.outlineVariant),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    fontFamilyFallback: const ['Noto Sans CJK SC', 'Noto Sans', 'sans-serif'],
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      foregroundColor: colors.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: colors.onSurface,
        fontFamilyFallback: const [
          'Noto Sans CJK SC',
          'Noto Sans',
          'sans-serif',
        ],
        fontSize: 19,
        fontWeight: FontWeight.w700,
      ),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.2,
      ),
      headlineMedium: TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w700,
        letterSpacing: -.8,
      ),
      headlineSmall: TextStyle(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyLarge: TextStyle(fontSize: 16, height: 1.55),
      bodyMedium: TextStyle(fontSize: 14, height: 1.45),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    dividerColor: colors.outlineVariant,
    cardTheme: CardThemeData(
      color: colors.surfaceContainerLowest,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .7)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: colors.primary, width: 1.6),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      labelStyle: TextStyle(color: colors.onSurfaceVariant),
      hintStyle: TextStyle(
        color: colors.onSurfaceVariant.withValues(alpha: .8),
      ),
      helperMaxLines: 4,
      errorMaxLines: 4,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 46),
        side: BorderSide(color: colors.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: colors.surfaceContainerLow,
      selectedColor: colors.primaryContainer,
      secondaryLabelStyle: TextStyle(color: colors.primary),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surfaceContainerLowest,
      showDragHandle: true,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      indicatorColor: colors.primaryContainer,
      selectedIconTheme: IconThemeData(color: colors.primary),
      selectedLabelTextStyle: TextStyle(
        color: colors.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
      backgroundColor: colors.surfaceContainerLowest,
      indicatorColor: colors.primaryContainer,
      elevation: 0,
      height: 72,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
