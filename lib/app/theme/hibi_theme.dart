import 'package:flutter/material.dart';

abstract final class HibiColors {
  static const background = Color(0xFF101512);
  static const surface = Color(0xFF19211C);
  static const primary = Color(0xFFA3BFA8);
  static const text = Color(0xFFE7EDE8);
  static const secondaryText = Color(0xFF929F96);
  static const border = Color(0xFF2D3A31);
  static const success = Color(0xFF81B896);
  static const recovered = Color(0xFFD5B579);
  static const failed = Color(0xFFD77F7F);
}

ThemeData createHibiTheme() {
  const scheme = ColorScheme.dark(
    primary: HibiColors.primary,
    onPrimary: HibiColors.background,
    surface: HibiColors.surface,
    onSurface: HibiColors.text,
    onSurfaceVariant: HibiColors.secondaryText,
    outline: HibiColors.border,
    error: HibiColors.failed,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: HibiColors.background,
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: HibiColors.surface,
      indicatorColor: HibiColors.border,
    ),
    cardTheme: CardThemeData(
      color: HibiColors.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: HibiColors.border),
      ),
    ),
  );
}
