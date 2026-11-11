import 'package:flutter/material.dart';

import 'contrast.dart';

/// Colour-vision-friendly chart palettes the user can choose in Settings.
enum ChartPaletteKind {
  /// Okabe-Ito: distinguishable for the common colour-vision deficiencies.
  standard(
    'Standard (Okabe-Ito)',
    'Colour-blind-safe default palette suitable for most people.',
  ),
  deuteranopia(
    'Deuteranopia optimised',
    'Blue and amber contrasts for reduced green sensitivity (most common).',
  ),
  protanopia(
    'Protanopia optimised',
    'Avoids relying on red, which appears dark for reduced red sensitivity.',
  ),
  tritanopia(
    'Tritanopia optimised',
    'Red and teal contrasts for reduced blue sensitivity.',
  ),
  monochrome(
    'Monochrome with patterns',
    'Shades of grey with a distinct pattern for every series.',
  );

  const ChartPaletteKind(this.label, this.description);

  final String label;
  final String description;
}

/// Fill patterns so chart series never rely on colour alone (WCAG 1.4.1).
enum ChartPattern {
  solid('Solid'),
  diagonal('Diagonal lines'),
  dots('Dots'),
  horizontal('Horizontal lines'),
  crossHatch('Cross-hatch'),
  vertical('Vertical lines'),
  backDiagonal('Reverse diagonal lines'),
  grid('Grid');

  const ChartPattern(this.label);

  /// Name read by screen readers and shown in table/legend tooltips.
  final String label;
}

/// Resolved colours and patterns for charts in the current theme.
///
/// Get it with [ChartPalette.of]. Series `i` should be drawn with
/// [colorAt]`(i)` and [patternAt]`(i)`; both cycle after 8 series, so charts
/// should group the long tail into an "Other" category beyond 8 slices.
/// Every series colour has at least 3:1 contrast against [background]
/// (4.5:1 in high contrast mode), so marks are distinguishable from the card
/// they sit on (WCAG 1.4.11); separate adjacent pie slices / stacked bars
/// with a [separator]-coloured stroke.
@immutable
class ChartPalette {
  const ChartPalette({
    required this.kind,
    required this.colors,
    required this.patternsEnabled,
    required this.background,
    required this.separator,
    required this.good,
    required this.warning,
    required this.bad,
    required this.neutral,
    required this.gridLine,
  });

  final ChartPaletteKind kind;
  final List<Color> colors;

  /// True when patterns should be drawn (user setting, always true for
  /// [ChartPaletteKind.monochrome]).
  final bool patternsEnabled;

  /// The surface charts are drawn on.
  final Color background;

  /// Stroke between adjacent marks (same as the background).
  final Color separator;

  /// Status colours (always pair with an icon or text label).
  final Color good;
  final Color warning;
  final Color bad;
  final Color neutral;

  /// Axis and grid lines (decorative, lower contrast is acceptable).
  final Color gridLine;

  static const List<ChartPattern> _patternCycle = [
    ChartPattern.solid,
    ChartPattern.diagonal,
    ChartPattern.dots,
    ChartPattern.horizontal,
    ChartPattern.crossHatch,
    ChartPattern.vertical,
    ChartPattern.backDiagonal,
    ChartPattern.grid,
  ];

  Color colorAt(int index) => colors[index % colors.length];

  ChartPattern patternAt(int index) =>
      patternsEnabled ? _patternCycle[index % _patternCycle.length] : ChartPattern.solid;

  /// Foreground colour to draw readable text on top of [fill].
  Color onColor(Color fill) =>
      contrastRatio(const Color(0xFFFFFFFF), fill) >= contrastRatio(const Color(0xFF000000), fill)
          ? Colors.white
          : Colors.black;

  // Base (unadjusted) palettes. Values are adjusted per theme in [resolve].
  static const Map<ChartPaletteKind, List<Color>> _base = {
    // Okabe & Ito (2008), ordered so neighbours differ in lightness too.
    ChartPaletteKind.standard: [
      Color(0xFF0072B2), // blue
      Color(0xFFE69F00), // orange
      Color(0xFF009E73), // bluish green
      Color(0xFFCC79A7), // reddish purple
      Color(0xFF56B4E9), // sky blue
      Color(0xFFD55E00), // vermillion
      Color(0xFFF0E442), // yellow
      Color(0xFF6B6B6B), // grey (stands in for Okabe-Ito black)
    ],
    // Paul Tol "medium contrast" + extras: blue/yellow axis with lightness
    // steps, robust for deuteranopia.
    ChartPaletteKind.deuteranopia: [
      Color(0xFF004488),
      Color(0xFFDDAA33),
      Color(0xFF6699CC),
      Color(0xFF997700),
      Color(0xFFBB5566),
      Color(0xFF332288),
      Color(0xFFEECC66),
      Color(0xFF777777),
    ],
    // Blue/orange based (IBM-style) avoiding pure reds.
    ChartPaletteKind.protanopia: [
      Color(0xFF0F62FE),
      Color(0xFFFFB000),
      Color(0xFF648FFF),
      Color(0xFF785EF0),
      Color(0xFFB07A00),
      Color(0xFF002D9C),
      Color(0xFFFFD369),
      Color(0xFF6F6F6F),
    ],
    // Red/teal based, avoiding blue-versus-yellow and blue-versus-green.
    ChartPaletteKind.tritanopia: [
      Color(0xFFCC3311),
      Color(0xFF009988),
      Color(0xFF882255),
      Color(0xFF44AA99),
      Color(0xFFEE3377),
      Color(0xFF115E54),
      Color(0xFFEE99AA),
      Color(0xFF555555),
    ],
    ChartPaletteKind.monochrome: [
      Color(0xFF1F1F1F),
      Color(0xFF5E5E5E),
      Color(0xFF3A3A3A),
      Color(0xFF7A7A7A),
      Color(0xFF2C2C2C),
      Color(0xFF4C4C4C),
      Color(0xFF6A6A6A),
      Color(0xFF151515),
    ],
  };

  /// Builds the palette for a theme.
  static ChartPalette resolve({
    required ChartPaletteKind kind,
    required ColorScheme scheme,
    required bool highContrast,
    required bool patterns,
  }) {
    final bg = scheme.surfaceContainerLow;
    final min = highContrast ? 4.5 : 3.0;
    final dark = scheme.brightness == Brightness.dark;
    var base = _base[kind]!;
    if (kind == ChartPaletteKind.monochrome && dark) {
      // Light greys on dark backgrounds.
      base = [
        for (final c in base)
          Color.from(alpha: 1, red: 1 - c.r, green: 1 - c.g, blue: 1 - c.b)
      ];
    }
    final colors = [for (final c in base) ensureContrast(c, bg, min)];
    Color status(Color c) => ensureContrast(c, bg, highContrast ? 4.5 : 3.0);
    final cvdSafeStatus = switch (kind) {
      ChartPaletteKind.tritanopia => (
          const Color(0xFF009988),
          const Color(0xFFEE7733),
          const Color(0xFFCC3311)
        ),
      ChartPaletteKind.monochrome => (
          dark ? const Color(0xFFE0E0E0) : const Color(0xFF1F1F1F),
          dark ? const Color(0xFFA0A0A0) : const Color(0xFF5E5E5E),
          dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000)
        ),
      _ => (
          const Color(0xFF0072B2),
          const Color(0xFFE69F00),
          const Color(0xFFD55E00)
        ),
    };
    return ChartPalette(
      kind: kind,
      colors: List.unmodifiable(colors),
      patternsEnabled: patterns || kind == ChartPaletteKind.monochrome,
      background: bg,
      separator: bg,
      good: status(cvdSafeStatus.$1),
      warning: status(cvdSafeStatus.$2),
      bad: status(cvdSafeStatus.$3),
      neutral: status(scheme.outline),
      gridLine: scheme.outlineVariant,
    );
  }

  /// The palette for the current theme and settings. Falls back to the
  /// standard palette with patterns when no [ChartStyleScope] is present.
  static ChartPalette of(BuildContext context) {
    final scope = ChartStyleScope.maybeOf(context);
    final theme = Theme.of(context);
    return resolve(
      kind: scope?.kind ?? ChartPaletteKind.standard,
      scheme: theme.colorScheme,
      highContrast: scope?.highContrast ?? false,
      patterns: scope?.patterns ?? true,
    );
  }
}

/// Carries chart style settings down the tree (inserted by the app root).
class ChartStyleScope extends InheritedWidget {
  const ChartStyleScope({
    super.key,
    required this.kind,
    required this.patterns,
    required this.highContrast,
    required super.child,
  });

  final ChartPaletteKind kind;
  final bool patterns;
  final bool highContrast;

  static ChartStyleScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChartStyleScope>();

  @override
  bool updateShouldNotify(ChartStyleScope old) =>
      old.kind != kind || old.patterns != patterns || old.highContrast != highContrast;
}
