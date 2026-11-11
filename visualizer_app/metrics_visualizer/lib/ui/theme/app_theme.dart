import 'package:flutter/material.dart';

/// Line limit for helper and error text of text fields. Generous, so long
/// instructions (such as how to fix an API address or token) wrap instead
/// of being cut off with an ellipsis in narrow fields at 200% text size
/// (WCAG 1.4.4 / 3.3.1 / 3.3.3).
const int fieldTextMaxLines = 24;

/// Material 3 themes for the visualizer.
///
/// Every variant (light, dark, high-contrast light, high-contrast dark) is
/// generated from one brand-neutral deep-teal seed and then hardened for
/// accessibility:
/// * body text pairs reach at least 4.5:1 (7:1 in high contrast), verified
///   by `test/ui/theme_contrast_test.dart`;
/// * interactive components get a visible focus indicator: buttons, chips,
///   menu items, inputs, switches and checkboxes get a 3 px outline in a
///   colour with at least 3:1 contrast against the surface; every other
///   focusable control (list tiles, cards, table headers, navigation
///   destinations) gets the two-tone ring drawn by `FocusRingOverlay`
///   (WCAG 2.4.7 / 1.4.11);
/// * minimum interactive size is 48 x 48 dp (`MaterialTapTargetSize.padded`).
abstract final class AppTheme {
  /// Deep teal: brand-neutral and readable in both brightnesses.
  static const Color seed = Color(0xFF00696B);

  static ColorScheme scheme(Brightness brightness, {bool highContrast = false}) {
    final base = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      contrastLevel: highContrast ? 1.0 : 0.0,
    );
    if (!highContrast) return base;
    // High contrast: pure black/white surfaces for maximum text contrast.
    final dark = brightness == Brightness.dark;
    return base.copyWith(
      surface: dark ? Colors.black : Colors.white,
      onSurface: dark ? Colors.white : Colors.black,
      surfaceContainerLowest: dark ? Colors.black : Colors.white,
      surfaceContainerLow: dark ? const Color(0xFF0A0A0A) : Colors.white,
      outline: dark ? const Color(0xFFE0E0E0) : const Color(0xFF1F1F1F),
    );
  }

  static ThemeData light({bool highContrast = false, bool reduceMotion = false}) =>
      build(scheme(Brightness.light, highContrast: highContrast),
          highContrast: highContrast, reduceMotion: reduceMotion);

  static ThemeData dark({bool highContrast = false, bool reduceMotion = false}) =>
      build(scheme(Brightness.dark, highContrast: highContrast),
          highContrast: highContrast, reduceMotion: reduceMotion);

  /// The colour of keyboard focus outlines in [cs].
  static Color focusRing(ColorScheme cs) => cs.brightness == Brightness.dark
      ? const Color(0xFFFFD54F) // amber, >= 10:1 on dark surfaces
      : cs.onSurface;

  /// Outline of the selected navigation indicator: at least 3:1 against the
  /// navigation backgrounds (surfaceContainer, surfaceContainerLow).
  static Color indicatorOutline(ColorScheme cs) => cs.onSurfaceVariant;

  /// The halo drawn on both sides of the app-wide focus ring (see
  /// `FocusRingOverlay`): the contrasting surface colour, so the two-tone
  /// ring reaches 3:1 against any adjacent colour.
  static Color focusHalo(ColorScheme cs) =>
      cs.brightness == Brightness.dark ? Colors.black : Colors.white;

  static ThemeData build(ColorScheme cs,
      {bool highContrast = false, bool reduceMotion = false}) {
    final ring = focusRing(cs);
    final focusSide = BorderSide(color: ring, width: 3);
    final borderWidth = highContrast ? 2.0 : 1.0;

    WidgetStateProperty<BorderSide?> sideWith(BorderSide? normal) =>
        WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return focusSide;
          return normal;
        });

    final buttonBase = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
      side: sideWith(null),
      tapTargetSize: MaterialTapTargetSize.padded,
    );

    // The selected navigation pill (secondaryContainer) is close in tone to
    // the navigation background in the standard themes, so it gets an
    // outline with at least 3:1 contrast (WCAG 1.4.11). High contrast
    // themes already reach 7:1 with the fill alone.
    final indicatorShape = StadiumBorder(
      side: BorderSide(color: indicatorOutline(cs), width: highContrast ? 2 : 1.5),
    );

    final roundedInput = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.outline, width: borderWidth),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: cs.surface,
      splashFactory: reduceMotion ? NoSplash.splashFactory : InkSparkle.splashFactory,
      focusColor: cs.primary.withValues(alpha: 0.16),
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 2,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: cs.surfaceContainerLow,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: highContrast ? cs.outline : cs.outlineVariant,
            width: borderWidth,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(style: buttonBase),
      elevatedButtonTheme: ElevatedButtonThemeData(style: buttonBase),
      textButtonTheme: TextButtonThemeData(style: buttonBase),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: buttonBase.copyWith(
          side: sideWith(BorderSide(color: cs.outline, width: borderWidth)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          side: sideWith(null),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          tapTargetSize: MaterialTapTargetSize.padded,
          side: sideWith(BorderSide(color: cs.outline, width: borderWidth)),
        ),
      ),
      chipTheme: ChipThemeData(
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return focusSide;
          if (states.contains(WidgetState.selected)) {
            return BorderSide(color: cs.primary, width: borderWidth);
          }
          return BorderSide(color: cs.outline, width: borderWidth);
        }),
        labelStyle: TextStyle(color: cs.onSurface),
        secondaryLabelStyle: TextStyle(color: cs.onSecondaryContainer),
        checkmarkColor: cs.onSecondaryContainer,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: roundedInput,
        enabledBorder: roundedInput,
        focusedBorder: roundedInput.copyWith(
            borderSide: BorderSide(color: ring, width: 3)),
        errorBorder: roundedInput.copyWith(
            borderSide: BorderSide(color: cs.error, width: 2)),
        focusedErrorBorder: roundedInput.copyWith(
            borderSide: BorderSide(color: cs.error, width: 3)),
        helperMaxLines: fieldTextMaxLines,
        errorMaxLines: fieldTextMaxLines,
        labelStyle: TextStyle(color: cs.onSurfaceVariant),
        floatingLabelStyle: TextStyle(color: cs.onSurface),
        helperStyle: TextStyle(color: cs.onSurfaceVariant),
        hintStyle: TextStyle(color: cs.onSurfaceVariant),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return ring;
          if (states.contains(WidgetState.selected)) return Colors.transparent;
          return cs.outline;
        }),
        trackOutlineWidth: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.focused) ? 3 : 2),
      ),
      checkboxTheme: CheckboxThemeData(
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.focused)) {
            return BorderSide(color: ring, width: 3);
          }
          if (states.contains(WidgetState.selected)) return null;
          return BorderSide(color: cs.onSurfaceVariant, width: 2);
        }),
      ),
      menuButtonTheme: MenuButtonThemeData(
        style: ButtonStyle(
          side: sideWith(null),
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        minTileHeight: 56,
        iconColor: cs.onSurfaceVariant,
        selectedColor: cs.onSecondaryContainer,
        selectedTileColor: cs.secondaryContainer,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cs.surfaceContainer,
        indicatorColor: cs.secondaryContainer,
        indicatorShape: indicatorShape,
        selectedIconTheme: IconThemeData(color: cs.onSecondaryContainer),
        unselectedIconTheme: IconThemeData(color: cs.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
            color: cs.onSurface, fontWeight: FontWeight.w600),
        unselectedLabelTextStyle: TextStyle(color: cs.onSurfaceVariant),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: cs.surfaceContainer,
        indicatorColor: cs.secondaryContainer,
        indicatorShape: indicatorShape,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? cs.onSurface
                  : cs.onSurfaceVariant,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
              fontSize: 12,
            )),
      ),
      navigationDrawerTheme: NavigationDrawerThemeData(
        backgroundColor: cs.surfaceContainerLow,
        indicatorColor: cs.secondaryContainer,
        indicatorShape: indicatorShape,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? cs.onSecondaryContainer
                  : cs.onSurfaceVariant,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
            )),
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
            color: cs.onSurface, fontWeight: FontWeight.w700),
        dataTextStyle: TextStyle(color: cs.onSurface),
        dividerThickness: 1,
        headingRowColor: WidgetStatePropertyAll(cs.surfaceContainerHigh),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        contentTextStyle: TextStyle(color: cs.onInverseSurface),
        actionTextColor: cs.inversePrimary,
        showCloseIcon: true,
        closeIconColor: cs.onInverseSurface,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        textStyle: TextStyle(color: cs.onInverseSurface, fontSize: 14),
        decoration: BoxDecoration(
          color: cs.inverseSurface,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1),
      sliderTheme: SliderThemeData(
        showValueIndicator: ShowValueIndicator.onDrag,
        overlayColor: cs.primary.withValues(alpha: 0.2),
      ),
      pageTransitionsTheme: reduceMotion
          ? const PageTransitionsTheme(builders: {
              TargetPlatform.android: _NoTransitionsBuilder(),
              TargetPlatform.iOS: _NoTransitionsBuilder(),
              TargetPlatform.linux: _NoTransitionsBuilder(),
              TargetPlatform.macOS: _NoTransitionsBuilder(),
              TargetPlatform.windows: _NoTransitionsBuilder(),
              TargetPlatform.fuchsia: _NoTransitionsBuilder(),
            })
          : const PageTransitionsTheme(builders: {
              TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
              TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
            }),
    );
  }
}

/// Route transition that shows the new page immediately (reduce motion).
class _NoTransitionsBuilder extends PageTransitionsBuilder {
  const _NoTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
