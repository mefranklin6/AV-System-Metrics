import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/ui/theme/app_theme.dart';
import 'package:metrics_visualizer/ui/theme/chart_palette.dart';
import 'package:metrics_visualizer/ui/theme/contrast.dart';

void main() {
  test('contrastRatio matches WCAG reference values', () {
    expect(contrastRatio(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrastRatio(Colors.white, Colors.white), closeTo(1, 0.001));
    expect(contrastRatio(const Color(0xFF767676), Colors.white), closeTo(4.54, 0.02));
    expect(contrastRatio(const Color(0x80000000), Colors.white), closeTo(3.95, 0.1));
  });

  test('ensureContrast reaches the target without changing compliant colours', () {
    const yellow = Color(0xFFF0E442);
    final fixed = ensureContrast(yellow, Colors.white, 3);
    expect(contrastRatio(fixed, Colors.white), greaterThanOrEqualTo(3));
    expect(ensureContrast(Colors.black, Colors.white, 4.5), Colors.black);
    final onDark = ensureContrast(const Color(0xFF0072B2), Colors.black, 4.5);
    expect(contrastRatio(onDark, Colors.black), greaterThanOrEqualTo(4.5));
  });

  for (final brightness in Brightness.values) {
    for (final highContrast in [false, true]) {
      final name = '${brightness.name}${highContrast ? ' high contrast' : ''}';
      group('$name theme', () {
        final cs = AppTheme.scheme(brightness, highContrast: highContrast);
        final text = highContrast ? 7.0 : 4.5;

        void pair(String label, Color fg, Color bg, double min) {
          final r = contrastRatio(fg, bg);
          expect(r, greaterThanOrEqualTo(min), reason: '$label: ${r.toStringAsFixed(2)} < $min');
        }

        test('body text pairs meet ${text == 7 ? 'AAA (7:1)' : 'AA (4.5:1)'}', () {
          for (final bg in {
            'surface': cs.surface,
            'surfaceContainerLowest': cs.surfaceContainerLowest,
            'surfaceContainerLow': cs.surfaceContainerLow,
            'surfaceContainer': cs.surfaceContainer,
            'surfaceContainerHigh': cs.surfaceContainerHigh,
            'surfaceContainerHighest': cs.surfaceContainerHighest,
          }.entries) {
            pair('onSurface on ${bg.key}', cs.onSurface, bg.value, text);
            pair('onSurfaceVariant on ${bg.key}', cs.onSurfaceVariant, bg.value, 4.5);
            pair('primary text on ${bg.key}', cs.primary, bg.value, 4.5);
            pair('error text on ${bg.key}', cs.error, bg.value, 4.5);
          }
        });

        test('container pairs meet AA', () {
          pair('onPrimary/primary', cs.onPrimary, cs.primary, 4.5);
          pair('onPrimaryContainer/primaryContainer', cs.onPrimaryContainer, cs.primaryContainer, 4.5);
          pair('onSecondaryContainer/secondaryContainer', cs.onSecondaryContainer, cs.secondaryContainer, 4.5);
          pair('onTertiaryContainer/tertiaryContainer', cs.onTertiaryContainer, cs.tertiaryContainer, 4.5);
          pair('onErrorContainer/errorContainer', cs.onErrorContainer, cs.errorContainer, 4.5);
          pair('onError/error', cs.onError, cs.error, 4.5);
          pair('onInverseSurface/inverseSurface', cs.onInverseSurface, cs.inverseSurface, 4.5);
          pair('inversePrimary/inverseSurface', cs.inversePrimary, cs.inverseSurface, 4.5);
          pair('onSurface/secondaryContainer (selected nav)', cs.onSecondaryContainer, cs.secondaryContainer, 4.5);
        });

        test('UI components and focus indicators meet 3:1', () {
          final ring = AppTheme.focusRing(cs);
          for (final bg in [cs.surface, cs.surfaceContainerLow, cs.surfaceContainer, cs.surfaceContainerHigh]) {
            pair('outline (field and button borders)', cs.outline, bg, 3);
            pair('focus ring', ring, bg, 3);
            pair('primary (switches, sliders)', cs.primary, bg, 3);
          }
          pair('error border', cs.error, cs.surface, 3);
          pair('tertiary border on surface', cs.tertiary, cs.surface, 3);
        });

        test('the two-tone focus ring reaches 3:1 against any adjacent colour', () {
          // For any colour X, max(contrast(X, ring), contrast(X, halo)) is at
          // least sqrt(contrast(ring, halo)), so 9:1 between the two tones
          // guarantees 3:1 against whatever is next to the ring.
          pair('focus ring against its halo', AppTheme.focusRing(cs), AppTheme.focusHalo(cs), 9);
        });

        test('the selected navigation indicator is outlined at 3:1', () {
          for (final bg in {
            'surfaceContainer (rail, bottom bar)': cs.surfaceContainer,
            'surfaceContainerLow (drawer)': cs.surfaceContainerLow,
          }.entries) {
            pair('indicator outline on ${bg.key}', AppTheme.indicatorOutline(cs), bg.value, 3);
          }
          final theme = AppTheme.build(cs, highContrast: highContrast);
          for (final shape in [
            theme.navigationBarTheme.indicatorShape,
            theme.navigationRailTheme.indicatorShape,
            theme.navigationDrawerTheme.indicatorShape,
          ]) {
            expect((shape! as OutlinedBorder).side.color, AppTheme.indicatorOutline(cs));
          }
        });

        test('every chart palette colour stands out from the chart background', () {
          for (final kind in ChartPaletteKind.values) {
            for (final patterns in [false, true]) {
              final p = ChartPalette.resolve(kind: kind, scheme: cs, highContrast: highContrast, patterns: patterns);
              final min = highContrast ? 4.5 : 3.0;
              for (var i = 0; i < p.colors.length; i++) {
                pair('${kind.name} colour $i', p.colors[i], p.background, min);
              }
              for (final status in [p.good, p.warning, p.bad, p.neutral]) {
                pair('${kind.name} status colour', status, p.background, min);
              }
              expect(p.colors.toSet(), hasLength(p.colors.length), reason: '${kind.name}: duplicate colours');
              if (kind == ChartPaletteKind.monochrome) {
                expect(p.patternsEnabled, isTrue);
                expect({for (var i = 0; i < 8; i++) p.patternAt(i)}, hasLength(8));
              }
              if (!patterns && kind != ChartPaletteKind.monochrome) {
                expect(p.patternAt(3), ChartPattern.solid);
              }
            }
          }
        });
      });
    }
  }

  test('patterns cycle with colours so 8 series are unique', () {
    final p = ChartPalette.resolve(
        kind: ChartPaletteKind.standard,
        scheme: AppTheme.scheme(Brightness.light),
        highContrast: false,
        patterns: true);
    final combos = {for (var i = 0; i < 8; i++) (p.colorAt(i), p.patternAt(i))};
    expect(combos, hasLength(8));
    expect(p.colorAt(8), p.colorAt(0));
    expect(p.onColor(Colors.black), Colors.white);
    expect(p.onColor(Colors.white), Colors.black);
  });
}
