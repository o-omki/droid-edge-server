import "package:flutter/material.dart";

class AppTheme {
  const AppTheme._();

  static const Color _fallbackSeed = Color(0xFF006A6A);

  static ThemeData light({ColorScheme? dynamicScheme}) {
    final colorScheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: _fallbackSeed,
          brightness: Brightness.light,
        );
    return _buildTheme(colorScheme);
  }

  static ThemeData dark({ColorScheme? dynamicScheme}) {
    final colorScheme =
        dynamicScheme ??
        ColorScheme.fromSeed(
          seedColor: _fallbackSeed,
          brightness: Brightness.dark,
        );
    return _buildTheme(colorScheme);
  }

  static ThemeData _buildTheme(ColorScheme colorScheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
