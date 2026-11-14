import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Semantic colors used for live recitation feedback.
class AppColors {
  AppColors._();

  static const Color correct = Color(0xFF4CAF50);
  static const Color correctSoft = Color(0x334CAF50);
  static const Color warning = Color(0xFFE08A00);
  static const Color warningSoft = Color(0x33E08A00);
  static const Color error = Color(0xFFE0524F);
  static const Color errorSoft = Color(0x33E0524F);

  /// Brand colors taken from the app logo (dark emerald + gold).
  static const Color gold = Color(0xFFDCB054);
  static const Color goldBright = Color(0xFFF5CF71);
  static const Color emeraldDeep = Color(0xFF082614);
}

/// Dark emerald and gold theme, matching the app icon.
/// Dark is the default; a light (cream) variant is available from the toggle.
class AppTheme {
  AppTheme._();

  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFFDCB054),
    onPrimary: Color(0xFF0A2616),
    primaryContainer: Color(0xFF16432A),
    onPrimaryContainer: Color(0xFFF5E3B3),
    secondary: Color(0xFFF5CF71),
    onSecondary: Color(0xFF0A2616),
    secondaryContainer: Color(0xFF3A3318),
    onSecondaryContainer: Color(0xFFF5E3B3),
    error: Color(0xFFE57373),
    onError: Color(0xFF3B0A0A),
    surface: Color(0xFF0A2616),
    onSurface: Color(0xFFF3EBD3),
    onSurfaceVariant: Color(0xFFC9C3A5),
    outline: Color(0xFF8A8B6A),
    outlineVariant: Color(0xFF3B5A40),
    surfaceContainer: Color(0xFF103520),
    surfaceContainerHighest: Color(0xFF174428),
  );

  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF0D3015),
    onPrimary: Color(0xFFF7F3E8),
    primaryContainer: Color(0xFFDCE9D8),
    onPrimaryContainer: Color(0xFF0D3015),
    secondary: Color(0xFFB8892B),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFF3E3B4),
    onSecondaryContainer: Color(0xFF3A2B00),
    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    surface: Color(0xFFF7F3E8),
    onSurface: Color(0xFF10200F),
    onSurfaceVariant: Color(0xFF4A5A47),
    outline: Color(0xFF7A8A74),
    outlineVariant: Color(0xFFC5CDB8),
    surfaceContainer: Color(0xFFEFE9D6),
    surfaceContainerHighest: Color(0xFFE8E1CA),
  );

  static ThemeData get light => _build(_lightScheme);

  static ThemeData get dark => _build(_darkScheme);

  static ThemeData _build(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: 'Tajawal',
      scaffoldBackgroundColor: scheme.surface,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: AppPageTransitionsBuilder(),
          TargetPlatform.iOS: AppPageTransitionsBuilder(),
          TargetPlatform.linux: AppPageTransitionsBuilder(),
          TargetPlatform.macOS: AppPageTransitionsBuilder(),
          TargetPlatform.windows: AppPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontFamily: 'AmiriQuran',
          fontSize: 26,
          color: scheme.secondary,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.secondary,
        linearTrackColor: scheme.onSurface.withValues(alpha: 0.12),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondary.withValues(alpha: 0.22),
        indicatorShape: const StadiumBorder(),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>((Set<WidgetState> states) {
          final bool on = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? scheme.secondary : scheme.onSurfaceVariant,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>((Set<WidgetState> states) {
          return IconThemeData(
            color: states.contains(WidgetState.selected) ? scheme.secondary : scheme.onSurfaceVariant,
          );
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
