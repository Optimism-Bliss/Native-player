import 'package:material_ui/material_ui.dart';

/// Dark Material 3 look modelled on Fladder: Rubik, tonal surfaces, rounded cards.
ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6E56CF),
    brightness: Brightness.dark,
    surface: const Color(0xFF121016),
  );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Rubik',
    scaffoldBackgroundColor: scheme.surface,
  );
  return base.copyWith(
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: base.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
      waitDuration: const Duration(milliseconds: 400),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
