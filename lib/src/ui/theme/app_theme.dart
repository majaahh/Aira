import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

class AppTheme {
  AppTheme._();

  static const seedColor = Color(0xFF045AED);

  static ThemeData buildTheme(
    Brightness brightness,
    ColorScheme? systemColors,
  ) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return _buildDesktopTheme(brightness);
    }
    return ThemeData(
      colorScheme:
          systemColors ??
          ColorScheme.fromSeed(
            seedColor: seedColor,
            brightness: brightness,
            dynamicSchemeVariant: DynamicSchemeVariant.expressive,
          ),
      cardTheme: const CardThemeData(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24)),
        ),
      ),
      iconButtonTheme: const IconButtonThemeData(
        variant: StyleVariant.material3Expressive,
      ),
      elevatedButtonTheme: const ElevatedButtonThemeData(
        variant: StyleVariant.material3Expressive,
      ),
    );
  }

  static ThemeData _buildDesktopTheme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.expressive,
    );

    final baseTextTheme = ThemeData(brightness: brightness).textTheme;

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      textTheme: baseTextTheme.copyWith(
        // App / screen titles
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        // List titles & main card headers
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        // Section headers (Noise control, Audio features)
        titleSmall: baseTextTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w500,
          color: colorScheme.onSurfaceVariant,
        ),
        // Buttons, Chips & Status Pills
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w500,
        ),
        labelMedium: baseTextTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w500,
        ),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(20)),
            ),
          ),
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        activeTrackColor: colorScheme.primary,
        inactiveTrackColor: colorScheme.onSurface.withValues(alpha: 0.24),
      ),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
