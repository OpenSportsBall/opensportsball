// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';

/// OpenSportsBall design system tokens and the Material themes built from
/// them. Token names match the design system (surface, ink, grass, sun...).
class BrandColors {
  const BrandColors._({
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.border,
    required this.borderStrong,
    required this.ink,
    required this.inkMuted,
    required this.grass,
    required this.grassStrong,
    required this.onGrass,
    required this.grassTint,
    required this.sun,
    required this.onSun,
    required this.sunTint,
    required this.sunText,
    required this.coral,
    required this.onCoral,
    required this.coralTint,
    required this.sky,
    required this.skyTint,
    required this.pitch,
    required this.onPitch,
  });

  final Color surface, surfaceRaised, surfaceSunken, border, borderStrong;
  final Color ink, inkMuted;
  final Color grass, grassStrong, onGrass, grassTint;
  final Color sun, onSun, sunTint, sunText;
  final Color coral, onCoral, coralTint;
  final Color sky, skyTint;
  final Color pitch, onPitch;

  /// Focus ring colour.
  Color get focus => sky;

  static const light = BrandColors._(
    surface: Color(0xFFFBF6EE),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF3EBDE),
    border: Color(0xFFE2D6C3),
    borderStrong: Color(0xFF8F7E6A),
    ink: Color(0xFF2B2119),
    inkMuted: Color(0xFF6E5F4F),
    grass: Color(0xFF2A7A46),
    grassStrong: Color(0xFF1F6237),
    onGrass: Color(0xFFFFFFFF),
    grassTint: Color(0xFFE2F1E3),
    sun: Color(0xFFF4B63A),
    onSun: Color(0xFF2B2119),
    sunTint: Color(0xFFFDF0D2),
    sunText: Color(0xFF8A5800),
    coral: Color(0xFFB33B27),
    onCoral: Color(0xFFFFFFFF),
    coralTint: Color(0xFFFBE6E1),
    sky: Color(0xFF2A6AA8),
    skyTint: Color(0xFFE2EDF8),
    pitch: Color(0xFF1D3B2A),
    onPitch: Color(0xFFFBF6EE),
  );

  static const dark = BrandColors._(
    surface: Color(0xFF18140F),
    surfaceRaised: Color(0xFF221D17),
    surfaceSunken: Color(0xFF2C261E),
    border: Color(0xFF3D352B),
    borderStrong: Color(0xFF7D6E5C),
    ink: Color(0xFFF5EEE3),
    inkMuted: Color(0xFFB9AB98),
    grass: Color(0xFF5CC27F),
    grassStrong: Color(0xFF7FD59C),
    onGrass: Color(0xFF0E2416),
    grassTint: Color(0xFF1B3324),
    sun: Color(0xFFF6C45C),
    onSun: Color(0xFF2B2119),
    sunTint: Color(0xFF3A2E14),
    sunText: Color(0xFFF6C45C),
    coral: Color(0xFFFF8F7A),
    onCoral: Color(0xFF2A0F0A),
    coralTint: Color(0xFF3D1D17),
    sky: Color(0xFF8CBCEF),
    skyTint: Color(0xFF172A3F),
    pitch: Color(0xFF2B5A3D),
    onPitch: Color(0xFFF5EEE3),
  );

  static BrandColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

class BrandFonts {
  static const display = 'Rubik';
  static const body = 'Atkinson Hyperlegible';
  static const mono = 'IBM Plex Mono';
}

/// Radius tokens.
class BrandRadius {
  static const sm = 8.0;
  static const md = 14.0;
  static const lg = 24.0;
}

ThemeData buildBrandTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? BrandColors.dark : BrandColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.grass,
    onPrimary: c.onGrass,
    primaryContainer: c.grassTint,
    onPrimaryContainer: c.ink,
    secondary: c.sun,
    onSecondary: c.onSun,
    secondaryContainer: c.sunTint,
    onSecondaryContainer: c.ink,
    tertiary: c.sky,
    onTertiary: brightness == Brightness.dark ? c.surface : Colors.white,
    tertiaryContainer: c.skyTint,
    onTertiaryContainer: c.ink,
    error: c.coral,
    onError: c.onCoral,
    errorContainer: c.coralTint,
    onErrorContainer: c.ink,
    surface: c.surface,
    onSurface: c.ink,
    onSurfaceVariant: c.inkMuted,
    surfaceContainerLowest: c.surfaceRaised,
    surfaceContainerLow: c.surfaceRaised,
    surfaceContainer: c.surfaceRaised,
    surfaceContainerHigh: c.surfaceSunken,
    surfaceContainerHighest: c.surfaceSunken,
    outline: c.borderStrong,
    outlineVariant: c.border,
    inverseSurface: c.ink,
    onInverseSurface: c.surface,
    inversePrimary: brightness == Brightness.dark ? BrandColors.light.grass : BrandColors.dark.grass,
    shadow: Colors.black,
    scrim: Colors.black,
  );

  final base = ThemeData(useMaterial3: true, colorScheme: scheme, fontFamily: BrandFonts.body);
  TextStyle? display(TextStyle? s, FontWeight w) =>
      s?.copyWith(fontFamily: BrandFonts.display, fontWeight: w, color: c.ink);
  final t = base.textTheme;
  final textTheme = t.copyWith(
    displayLarge: display(t.displayLarge, FontWeight.w700),
    displayMedium: display(t.displayMedium, FontWeight.w700),
    displaySmall: display(t.displaySmall, FontWeight.w700),
    headlineLarge: display(t.headlineLarge, FontWeight.w700),
    headlineMedium: display(t.headlineMedium, FontWeight.w700),
    headlineSmall: display(t.headlineSmall, FontWeight.w700),
    titleLarge: display(t.titleLarge, FontWeight.w600),
    titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    titleSmall: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w700),
    labelSmall: t.labelSmall?.copyWith(fontWeight: FontWeight.w700),
  );
  const buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(BrandRadius.md)));
  const minSize = Size(64, 44);

  return base.copyWith(
    scaffoldBackgroundColor: c.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: c.surface,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(BrandRadius.md)),
        side: BorderSide(color: c.border),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: buttonShape, minimumSize: minSize),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        shape: buttonShape,
        minimumSize: minSize,
        backgroundColor: c.grass,
        foregroundColor: c.onGrass,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: buttonShape,
        minimumSize: minSize,
        foregroundColor: c.ink,
        side: BorderSide(color: c.borderStrong),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.grass, minimumSize: minSize),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceRaised,
      border: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(BrandRadius.sm)),
        borderSide: BorderSide(color: c.borderStrong),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(BrandRadius.sm)),
        borderSide: BorderSide(color: c.borderStrong),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(BrandRadius.sm)),
        borderSide: BorderSide(color: c.focus, width: 2),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border),
    chipTheme: base.chipTheme.copyWith(
      shape: const StadiumBorder(),
      side: BorderSide(color: c.border),
      backgroundColor: c.surfaceSunken,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.grass, linearTrackColor: c.surfaceSunken),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.ink,
      contentTextStyle: TextStyle(color: c.surface, fontFamily: BrandFonts.body),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
