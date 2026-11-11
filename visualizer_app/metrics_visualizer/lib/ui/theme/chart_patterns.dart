import 'package:flutter/material.dart';

import 'chart_palette.dart';

/// Paints [pattern] in [color] inside [area] (clipped to [clip] when given),
/// over an already-filled background. Use from CustomPainters to add
/// patterns to bars, pie slices or areas so series are distinguishable
/// without colour.
///
/// The pattern strokes use [patternColor] (normally `palette.onColor(fill)`)
/// so they stay visible on top of the fill colour.
void paintChartPattern(
  Canvas canvas,
  Rect area,
  ChartPattern pattern,
  Color patternColor, {
  Path? clip,
  double spacing = 7,
  double strokeWidth = 1.4,
}) {
  if (pattern == ChartPattern.solid || area.isEmpty) return;
  canvas.save();
  if (clip != null) {
    canvas.clipPath(clip);
  } else {
    canvas.clipRect(area);
  }
  final paint = Paint()
    ..color = patternColor
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true;
  final w = area.width, h = area.height;
  final l = area.left, t = area.top;
  void lines({required bool horizontal}) {
    if (horizontal) {
      for (var y = t + spacing / 2; y < t + h; y += spacing) {
        canvas.drawLine(Offset(l, y), Offset(l + w, y), paint);
      }
    } else {
      for (var x = l + spacing / 2; x < l + w; x += spacing) {
        canvas.drawLine(Offset(x, t), Offset(x, t + h), paint);
      }
    }
  }

  void diagonal({required bool forward}) {
    final span = w + h;
    for (var d = -h; d < span; d += spacing) {
      if (forward) {
        canvas.drawLine(Offset(l + d, t + h), Offset(l + d + h, t), paint);
      } else {
        canvas.drawLine(Offset(l + d, t), Offset(l + d + h, t + h), paint);
      }
    }
  }

  switch (pattern) {
    case ChartPattern.solid:
      break;
    case ChartPattern.diagonal:
      diagonal(forward: true);
    case ChartPattern.backDiagonal:
      diagonal(forward: false);
    case ChartPattern.horizontal:
      lines(horizontal: true);
    case ChartPattern.vertical:
      lines(horizontal: false);
    case ChartPattern.grid:
      lines(horizontal: true);
      lines(horizontal: false);
    case ChartPattern.crossHatch:
      diagonal(forward: true);
      diagonal(forward: false);
    case ChartPattern.dots:
      final dot = Paint()
        ..color = patternColor
        ..style = PaintingStyle.fill;
      var row = 0;
      for (var y = t + spacing / 2; y < t + h; y += spacing, row++) {
        final offset = row.isOdd ? spacing / 2 : 0.0;
        for (var x = l + spacing / 2 + offset; x < l + w; x += spacing) {
          canvas.drawCircle(Offset(x, y), strokeWidth * 1.1, dot);
        }
      }
  }
  canvas.restore();
}

/// A rectangle filled with [color] and overlaid with [pattern]. Use as a
/// legend swatch or as a bar inside custom layouts.
class PatternBox extends StatelessWidget {
  const PatternBox({
    super.key,
    required this.color,
    required this.pattern,
    this.width = 20,
    this.height = 20,
    this.borderRadius = 4,
    this.borderColor,
  });

  final Color color;
  final ChartPattern pattern;
  final double width;
  final double height;
  final double borderRadius;

  /// Optional outline; defaults to the theme's outline colour so the swatch
  /// boundary is visible against the card (>= 3:1).
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final outline = borderColor ?? Theme.of(context).colorScheme.outline;
    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _PatternBoxPainter(color, pattern, outline, borderRadius),
      ),
    );
  }
}

class _PatternBoxPainter extends CustomPainter {
  _PatternBoxPainter(this.color, this.pattern, this.outline, this.radius);

  final Color color;
  final ChartPattern pattern;
  final Color outline;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.drawRRect(rrect, Paint()..color = color);
    final onColor = color.computeLuminance() > 0.3 ? Colors.black : Colors.white;
    paintChartPattern(canvas, rect, pattern, onColor,
        clip: Path()..addRRect(rrect), spacing: 5, strokeWidth: 1.2);
    canvas.drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..color = outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_PatternBoxPainter old) =>
      old.color != color ||
      old.pattern != pattern ||
      old.outline != outline ||
      old.radius != radius;
}
