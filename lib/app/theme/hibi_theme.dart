import 'package:flutter/material.dart';

abstract final class HibiColors {
  static const background = Color(0xFF121B17);
  static const surface = Color(0xFF23312A);
  static const primary = Color(0xFFB5DFC1);
  static const text = Color(0xFFF2F7F1);
  static const secondaryText = Color(0xFFC1D0C3);
  static const border = Color(0xFF52685A);
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
    appBarTheme: const AppBarTheme(
      backgroundColor: HibiColors.background,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: HibiColors.surface,
      indicatorColor: Color(0xFF41634E),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: const BorderSide(color: HibiColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF1B2821),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HibiColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HibiColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: HibiColors.primary, width: 2),
      ),
    ),
    cardTheme: CardThemeData(
      color: HibiColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: HibiColors.border),
      ),
    ),
  );
}
