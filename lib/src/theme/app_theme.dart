import 'package:flutter/material.dart';

import 'app_tokens.dart';

class AppTheme {
  AppTheme._();

  static const Color lightSeed = Color(0xFF2C1B02);
  static const Color darkSeed = Color(0xFF9C27B0);

  static ThemeData light() => _build(Brightness.light, lightSeed);
  static ThemeData dark() => _build(Brightness.dark, darkSeed);

  static WidgetStateProperty<Color?> _overlay(Color color) => WidgetStateProperty.resolveWith((s) {
    if (s.contains(WidgetState.hovered)) return color.withValues(alpha: 0.08);
    if (s.contains(WidgetState.pressed) || s.contains(WidgetState.focused)) return color.withValues(alpha: 0.12);
    return null;
  });

  static ThemeData _build(Brightness b, Color seed) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    final dark = b == Brightness.dark;
    final panel = dark
        ? Colors.black
        : Color.alphaBlend(scheme.surfaceContainerHighest.withValues(alpha: 0.475), scheme.surface);
    const shape = RoundedRectangleBorder(borderRadius: AppTokens.borderRadiusAll);
    OutlineInputBorder border(Color color, [double width = 1]) => OutlineInputBorder(
      borderRadius: AppTokens.borderRadiusAll,
      borderSide: BorderSide(color: color, width: width),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: panel,
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: dark ? scheme.surfaceContainer : scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: shape).copyWith(overlayColor: _overlay(scheme.onPrimary)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: shape,
          side: BorderSide(color: scheme.outlineVariant),
        ).copyWith(overlayColor: _overlay(scheme.primary)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: shape).copyWith(overlayColor: _overlay(scheme.primary)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(shape: shape).copyWith(overlayColor: _overlay(scheme.primary)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: border(scheme.outlineVariant),
        enabledBorder: border(scheme.outlineVariant),
        focusedBorder: border(scheme.primary, 2),
        errorBorder: border(scheme.error),
        disabledBorder: border(scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      dialogTheme: DialogThemeData(
        shape: shape,
        backgroundColor: scheme.surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.45),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: AppTokens.borderRadiusAll,
          border: Border.all(color: scheme.outlineVariant),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        textStyle: TextStyle(color: scheme.onSurface, fontSize: AppTokens.fontMD),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: panel,
        indicatorColor: scheme.secondaryContainer,
        indicatorShape: shape,
      ),
      listTileTheme: const ListTileThemeData(shape: shape),
      progressIndicatorTheme: const ProgressIndicatorThemeData(borderRadius: AppTokens.borderRadiusAll),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.6), space: 1),
    );
  }
}
