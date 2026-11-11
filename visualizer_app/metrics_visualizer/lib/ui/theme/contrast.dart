import 'dart:math' as math;
import 'dart:ui' show Color;

// WCAG 2.x contrast helpers used by the themes, palettes and tests.

/// WCAG relative luminance of an opaque [c] (alpha is ignored).
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG contrast ratio between two colours, 1.0 to 21.0. Translucent
/// [foreground] colours are composited over [background] first.
double contrastRatio(Color foreground, Color background) {
  final fg = foreground.a < 1.0 ? Color.alphaBlend(foreground, background) : foreground;
  final l1 = relativeLuminance(fg);
  final l2 = relativeLuminance(background);
  final hi = l1 > l2 ? l1 : l2;
  final lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

/// Returns [color] darkened or lightened (keeping its hue as far as
/// possible) until it reaches at least [minRatio] against [background].
/// Moves toward black on light backgrounds and toward white on dark ones.
Color ensureContrast(Color color, Color background, double minRatio) {
  if (contrastRatio(color, background) >= minRatio) return color;
  final towardBlack = relativeLuminance(background) > 0.18;
  final target = towardBlack ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
  // Binary search for the smallest blend that meets the ratio.
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 20; i++) {
    final mid = (lo + hi) / 2;
    final c = Color.lerp(color, target, mid)!;
    if (contrastRatio(c, background) >= minRatio) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return Color.lerp(color, target, hi)!.withValues(alpha: 1);
}
