import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_color_utilities/material_color_utilities.dart' as mcu;
import 'package:material_ui/material_ui.dart';

typedef SystemColors = ({ColorScheme light, ColorScheme dark});

({mcu.CorePalette palette, Map<String, int> roles, SystemColors colors})?
_cachedSystemColors;

Future<SystemColors?> loadAndroidSystemColors() async {
  const channel = OptionalMethodChannel('io.majaahh.aira/system_colors');
  try {
    final palette = await DynamicColorPlugin.getCorePalette();
    if (palette == null) return null;
    final roles =
        await channel.invokeMapMethod<String, int>('getColorRoles') ?? {};
    final cached = _cachedSystemColors;
    if (cached != null &&
        cached.palette == palette &&
        mapEquals(cached.roles, roles)) {
      return cached.colors;
    }
    final colors = (
      light: _systemScheme(palette, roles, Brightness.light),
      dark: _systemScheme(palette, roles, Brightness.dark),
    );
    _cachedSystemColors = (palette: palette, roles: roles, colors: colors);
    return colors;
  } on PlatformException {
    return null;
  }
}

ColorScheme _systemScheme(
  mcu.CorePalette palette,
  Map<String, int> roles,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  final scheme = mcu.DynamicScheme(
    sourceColorHct: mcu.Hct.fromInt(palette.primary.get(40)),
    variant: mcu.Variant.tonalSpot,
    isDark: dark,
    primaryPalette: palette.primary,
    secondaryPalette: palette.secondary,
    tertiaryPalette: palette.tertiary,
    neutralPalette: palette.neutral,
    neutralVariantPalette: palette.neutralVariant,
    errorPalette: palette.error,
  );
  final mode = dark ? 'dark' : 'light';
  Color color(String role, int fallback) =>
      Color(roles['${role}_$mode'] ?? roles[role] ?? fallback);

  return ColorScheme(
    brightness: brightness,
    primary: color('primary', scheme.primary),
    onPrimary: color('on_primary', scheme.onPrimary),
    primaryContainer: color('primary_container', scheme.primaryContainer),
    onPrimaryContainer: color(
      'on_primary_container',
      scheme.onPrimaryContainer,
    ),
    primaryFixed: color('primary_fixed', scheme.primaryFixed),
    primaryFixedDim: color('primary_fixed_dim', scheme.primaryFixedDim),
    onPrimaryFixed: color('on_primary_fixed', scheme.onPrimaryFixed),
    onPrimaryFixedVariant: color(
      'on_primary_fixed_variant',
      scheme.onPrimaryFixedVariant,
    ),
    secondary: color('secondary', scheme.secondary),
    onSecondary: color('on_secondary', scheme.onSecondary),
    secondaryContainer: color('secondary_container', scheme.secondaryContainer),
    onSecondaryContainer: color(
      'on_secondary_container',
      scheme.onSecondaryContainer,
    ),
    secondaryFixed: color('secondary_fixed', scheme.secondaryFixed),
    secondaryFixedDim: color('secondary_fixed_dim', scheme.secondaryFixedDim),
    onSecondaryFixed: color('on_secondary_fixed', scheme.onSecondaryFixed),
    onSecondaryFixedVariant: color(
      'on_secondary_fixed_variant',
      scheme.onSecondaryFixedVariant,
    ),
    tertiary: color('tertiary', scheme.tertiary),
    onTertiary: color('on_tertiary', scheme.onTertiary),
    tertiaryContainer: color('tertiary_container', scheme.tertiaryContainer),
    onTertiaryContainer: color(
      'on_tertiary_container',
      scheme.onTertiaryContainer,
    ),
    tertiaryFixed: color('tertiary_fixed', scheme.tertiaryFixed),
    tertiaryFixedDim: color('tertiary_fixed_dim', scheme.tertiaryFixedDim),
    onTertiaryFixed: color('on_tertiary_fixed', scheme.onTertiaryFixed),
    onTertiaryFixedVariant: color(
      'on_tertiary_fixed_variant',
      scheme.onTertiaryFixedVariant,
    ),
    error: color('error', scheme.error),
    onError: color('on_error', scheme.onError),
    errorContainer: color('error_container', scheme.errorContainer),
    onErrorContainer: color('on_error_container', scheme.onErrorContainer),
    outline: color('outline', scheme.outline),
    outlineVariant: color('outline_variant', scheme.outlineVariant),
    surface: color('surface', scheme.surface),
    onSurface: color('on_surface', scheme.onSurface),
    surfaceDim: color('surface_dim', scheme.surfaceDim),
    surfaceBright: color('surface_bright', scheme.surfaceBright),
    surfaceContainerLowest: color(
      'surface_container_lowest',
      scheme.surfaceContainerLowest,
    ),
    surfaceContainerLow: color(
      'surface_container_low',
      scheme.surfaceContainerLow,
    ),
    surfaceContainer: color('surface_container', scheme.surfaceContainer),
    surfaceContainerHigh: color(
      'surface_container_high',
      scheme.surfaceContainerHigh,
    ),
    surfaceContainerHighest: color(
      'surface_container_highest',
      scheme.surfaceContainerHighest,
    ),
    onSurfaceVariant: color('on_surface_variant', scheme.onSurfaceVariant),
    inverseSurface: Color(scheme.inverseSurface),
    onInverseSurface: Color(scheme.inverseOnSurface),
    inversePrimary: Color(scheme.inversePrimary),
    shadow: color('shadow', scheme.shadow),
    scrim: color('scrim', scheme.scrim),
    surfaceTint: color('surface_tint', scheme.surfaceTint),
  );
}
