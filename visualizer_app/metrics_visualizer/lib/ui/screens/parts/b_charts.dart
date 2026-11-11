// Chart widgets used by the Connectivity, Issues and Forecast screens.
//
// Every chart here is decorative from the point of view of assistive
// technology: it is always placed inside an AccessibleChartCard, which
// exposes a text summary and a data table with the same numbers. The charts
// themselves therefore focus on being readable without colour (patterns,
// dash styles, direct value labels) and on honouring reduce motion.

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../widgets/widgets.dart';

/// One series of a [StackedBarChart].
@immutable
class BarSeries {
  const BarSeries(this.label, this.values);

  final String label;

  /// One value per category (same length as the chart's categories).
  final List<double> values;
}

/// Picks "nice" axis ticks (1, 2, 2.5 or 5 x 10^n) covering 0..[max].
List<double> niceTicks(double max, {int target = 4}) {
  if (!max.isFinite || max <= 0) return const [0, 1];
  final raw = max / target;
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm <= 1
          ? 1
          : norm <= 2
              ? 2
              : norm <= 2.5
                  ? 2.5
                  : norm <= 5
                      ? 5
                      : 10) *
      mag;
  final top = (max / step).ceil() * step;
  return [for (var v = 0.0; v <= top + step / 2; v += step) v];
}

/// Vertical stacked bars, one bar per category (for example per day), with
/// a pattern per series and a separator line between stacked segments.
/// Bars grow in on first build (instantly under reduce motion).
class StackedBarChart extends StatelessWidget {
  const StackedBarChart({
    super.key,
    required this.categories,
    required this.series,
    this.formatValue,
  });

  /// Axis label per bar.
  final List<String> categories;
  final List<BarSeries> series;

  /// Formats y-axis tick values (defaults to whole numbers).
  final String Function(double value)? formatValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ChartPalette.of(context);
    final motion = Motion.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant) ??
        TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: motion.reduced ? 1 : 0, end: 1),
      duration: motion.chart,
      curve: motion.curve,
      builder: (context, t, _) => CustomPaint(
        size: Size.infinite,
        painter: _StackedBarPainter(
          categories: categories,
          series: series,
          colors: [for (var i = 0; i < series.length; i++) palette.colorAt(i)],
          patterns: [for (var i = 0; i < series.length; i++) palette.patternAt(i)],
          onColor: [for (var i = 0; i < series.length; i++) palette.onColor(palette.colorAt(i))],
          separator: palette.separator,
          gridLine: palette.gridLine,
          labelStyle: style,
          textScaler: scaler,
          textDirection: Directionality.of(context),
          formatValue: formatValue ?? (v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1),
          progress: t,
        ),
      ),
    );
  }
}

class _StackedBarPainter extends CustomPainter {
  _StackedBarPainter({
    required this.categories,
    required this.series,
    required this.colors,
    required this.patterns,
    required this.onColor,
    required this.separator,
    required this.gridLine,
    required this.labelStyle,
    required this.textScaler,
    required this.textDirection,
    required this.formatValue,
    required this.progress,
  });

  final List<String> categories;
  final List<BarSeries> series;
  final List<Color> colors;
  final List<ChartPattern> patterns;
  final List<Color> onColor;
  final Color separator;
  final Color gridLine;
  final TextStyle labelStyle;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final String Function(double) formatValue;
  final double progress;

  TextPainter _text(String s) => TextPainter(
        text: TextSpan(text: s, style: labelStyle),
        textDirection: textDirection,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || categories.isEmpty) return;
    var maxTotal = 0.0;
    for (var i = 0; i < categories.length; i++) {
      var total = 0.0;
      for (final s in series) {
        total += i < s.values.length ? s.values[i] : 0;
      }
      maxTotal = math.max(maxTotal, total);
    }
    final ticks = niceTicks(maxTotal);
    final top = ticks.last <= 0 ? 1.0 : ticks.last;
    final tickPainters = [for (final v in ticks) _text(formatValue(v))];
    final axisWidth = tickPainters.fold<double>(0, (m, p) => math.max(m, p.width)) + 8;
    final xLabelHeight = _text('Ag').height + 6;
    final plot = Rect.fromLTRB(axisWidth, tickPainters.first.height / 2, size.width,
        size.height - xLabelHeight);
    if (plot.width <= 0 || plot.height <= 0) return;

    // Grid and y labels.
    final grid = Paint()
      ..color = gridLine
      ..strokeWidth = 1;
    for (var i = 0; i < ticks.length; i++) {
      final y = plot.bottom - plot.height * (ticks[i] / top);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final p = tickPainters[i];
      p.paint(canvas, Offset(plot.left - 6 - p.width, y - p.height / 2));
    }

    // Bars.
    final slot = plot.width / categories.length;
    final barWidth = math.max(1.0, math.min(slot * 0.72, 48.0));
    final sepPaint = Paint()
      ..color = separator
      ..strokeWidth = slot > 6 ? 1.5 : 0.5;
    for (var i = 0; i < categories.length; i++) {
      final cx = plot.left + slot * (i + 0.5);
      var base = plot.bottom;
      for (var s = 0; s < series.length; s++) {
        final v = i < series[s].values.length ? series[s].values[i] : 0.0;
        if (v <= 0) continue;
        final h = plot.height * (v / top) * progress;
        final rect = Rect.fromLTWH(cx - barWidth / 2, base - h, barWidth, h);
        canvas.drawRect(rect, Paint()..color = colors[s]);
        paintChartPattern(canvas, rect, patterns[s], onColor[s]);
        if (base < plot.bottom) {
          canvas.drawLine(Offset(rect.left, base), Offset(rect.right, base), sepPaint);
        }
        base -= h;
      }
    }

    // X labels, thinned so they never overlap.
    var widest = 0.0;
    final xPainters = <TextPainter>[];
    for (final c in categories) {
      final p = _text(c);
      xPainters.add(p);
      widest = math.max(widest, p.width);
    }
    final every = math.max(1, ((widest + 12) / slot).ceil());
    for (var i = 0; i < categories.length; i += every) {
      final p = xPainters[i];
      final cx = plot.left + slot * (i + 0.5);
      final x = (cx - p.width / 2).clamp(0.0, math.max(0.0, size.width - p.width)).toDouble();
      p.paint(canvas, Offset(x, plot.bottom + 6));
    }
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom),
        Paint()
          ..color = labelStyle.color ?? gridLine
          ..strokeWidth = 1);
  }

  @override
  bool shouldRepaint(_StackedBarPainter old) =>
      old.progress != progress ||
      old.categories != categories ||
      old.series != series ||
      old.textScaler != textScaler ||
      old.labelStyle != labelStyle ||
      !_listEquals(old.colors, colors) ||
      !_listEquals(old.patterns, patterns);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One row of a [LabeledBarList].
@immutable
class BarListItem {
  const BarListItem({
    required this.label,
    required this.fraction,
    required this.valueText,
    this.seriesIndex = 0,
    this.marker,
  });

  final String label;

  /// Bar length as a fraction (0-1) of the full width.
  final double fraction;

  /// Value printed after the bar (direct label, so colour is never needed).
  final String valueText;

  /// Palette index for the bar's colour and pattern.
  final int seriesIndex;

  /// Optional icon after the value (for example a warning sign); always
  /// paired with words elsewhere on the card.
  final IconData? marker;
}

/// Horizontal bars with the label and the value written next to each bar.
/// Labels wrap and rows grow with the text size; on narrow widths the label
/// moves above its bar. Scrolls when there are more rows than fit.
class LabeledBarList extends StatelessWidget {
  const LabeledBarList({super.key, required this.items});

  final List<BarListItem> items;

  /// A chart height that fits [count] rows at the current text size
  /// (limited to [maxRows] visible rows; the rest scroll).
  static double heightFor(BuildContext context, int count, {int maxRows = 14}) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final rows = count.clamp(1, maxRows);
    return rows * (22 * scale + 14) + 8;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ChartPalette.of(context);
    final motion = Motion.of(context);
    final textStyle = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface);
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 420;
      final labelWidth = narrow ? constraints.maxWidth : math.min(220.0, constraints.maxWidth * 0.32);
      return Scrollbar(
        child: ListView.builder(
          primary: false,
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final color = palette.colorAt(item.seriesIndex);
            final bar = TweenAnimationBuilder<double>(
              tween: Tween(begin: motion.reduced ? item.fraction : 0, end: item.fraction),
              duration: motion.chart,
              curve: motion.curve,
              builder: (context, f, _) => LayoutBuilder(
                builder: (context, c) => Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SizedBox(
                    width: math.max(f.clamp(0.0, 1.0) * c.maxWidth, item.fraction > 0 ? 2.0 : 0.0),
                    height: 18,
                    child: CustomPaint(
                      painter: _BarPainter(
                        color,
                        palette.patternAt(item.seriesIndex),
                        palette.onColor(color),
                      ),
                    ),
                  ),
                ),
              ),
            );
            final value = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(item.valueText, style: textStyle?.copyWith(fontWeight: FontWeight.w600)),
                if (item.marker != null) ...[
                  const SizedBox(width: 4),
                  Icon(item.marker, size: 18, color: theme.colorScheme.onSurface),
                ],
              ],
            );
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.label, style: textStyle),
                        Row(children: [Expanded(child: bar), const SizedBox(width: 8), value]),
                      ],
                    )
                  : Row(
                      children: [
                        SizedBox(width: labelWidth, child: Text(item.label, style: textStyle)),
                        const SizedBox(width: 12),
                        Expanded(child: bar),
                        const SizedBox(width: 8),
                        value,
                      ],
                    ),
            );
          },
        ),
      );
    });
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.color, this.pattern, this.onColor);

  final Color color;
  final ChartPattern pattern;
  final Color onColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndCorners(rect,
        topRight: const Radius.circular(4), bottomRight: const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = color);
    paintChartPattern(canvas, rect, pattern, onColor, clip: Path()..addRRect(rrect));
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.color != color || old.pattern != pattern || old.onColor != onColor;
}

/// Line style for a [TrendLineChart] series.
enum LineStyleKind {
  solid('solid line'),
  dashed('dashed line'),
  dotted('dotted line'),
  dashDot('dash-dot line');

  const LineStyleKind(this.label);

  /// Words used in legends so lines are told apart without colour.
  final String label;

  List<int>? get dashArray => switch (this) {
        LineStyleKind.solid => null,
        LineStyleKind.dashed => const [10, 6],
        LineStyleKind.dotted => const [2, 4],
        LineStyleKind.dashDot => const [10, 4, 2, 4],
      };
}

/// One line of a [TrendLineChart].
@immutable
class LineSeriesSpec {
  const LineSeriesSpec({
    required this.label,
    required this.points,
    required this.color,
    this.style = LineStyleKind.solid,
    this.width = 3,
    this.showDots = false,
  });

  final String label;

  /// (x, y) points in ascending x.
  final List<Offset> points;
  final Color color;
  final LineStyleKind style;
  final double width;
  final bool showDots;
}

/// A shaded band between two series (by index), e.g. a likely range.
@immutable
class LineBand {
  const LineBand(this.fromIndex, this.toIndex, this.color);
  final int fromIndex;
  final int toIndex;
  final Color color;
}

/// A line chart (fl_chart) with dash styles per series, an optional band,
/// axis labels that scale with the text size and no hover-only content
/// (touch tooltips are disabled: values are in the table view instead,
/// which avoids hover content that cannot be dismissed, WCAG 1.4.13).
class TrendLineChart extends StatelessWidget {
  const TrendLineChart({
    super.key,
    required this.series,
    required this.formatX,
    required this.formatY,
    this.bands = const [],
    this.verticalMarkerX,
    this.horizontalMarkerY,
    this.minY = 0,
  });

  final List<LineSeriesSpec> series;
  final List<LineBand> bands;
  final String Function(double x) formatX;
  final String Function(double y) formatY;

  /// Optional vertical rule (for example "today").
  final double? verticalMarkerX;

  /// Optional horizontal rule (for example the rated life).
  final double? horizontalMarkerY;
  final double minY;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final motion = Motion.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final labelStyle = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    var minX = double.infinity, maxX = double.negativeInfinity, maxY = 0.0;
    for (final s in series) {
      for (final p in s.points) {
        minX = math.min(minX, p.dx);
        maxX = math.max(maxX, p.dx);
        maxY = math.max(maxY, p.dy);
      }
    }
    if (horizontalMarkerY != null) maxY = math.max(maxY, horizontalMarkerY!);
    if (!minX.isFinite) {
      minX = 0;
      maxX = 1;
    }
    if (maxX <= minX) maxX = minX + 1;
    final ticks = niceTicks(maxY);
    final yTop = ticks.last;
    final yInterval = ticks.length > 1 ? ticks[1] - ticks[0] : yTop;

    return LayoutBuilder(builder: (context, constraints) {
      final labelCount = math.max(2, (constraints.maxWidth / (110 * scale)).floor());
      final xInterval = (maxX - minX) / labelCount;
      return LineChart(
        LineChartData(
          minX: minX,
          maxX: maxX,
          minY: minY,
          maxY: yTop,
          lineTouchData: const LineTouchData(enabled: false),
          clipData: const FlClipData.all(),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: yInterval,
            getDrawingHorizontalLine: (_) => FlLine(color: palette.gridLine, strokeWidth: 1),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(bottom: BorderSide(color: cs.outline), left: BorderSide(color: cs.outline)),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: yInterval,
                reservedSize: 56 * scale,
                getTitlesWidget: (v, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(formatY(v), style: labelStyle, maxLines: 1),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: xInterval <= 0 ? 1 : xInterval,
                reservedSize: 30 * scale,
                getTitlesWidget: (v, meta) {
                  // Skip the automatic min/max labels when they would
                  // collide with an interval label.
                  if ((v == meta.min || v == meta.max) &&
                      v != minX &&
                      (v - minX) % (xInterval <= 0 ? 1 : xInterval) > 1e-6) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                    child: Text(formatX(v), style: labelStyle, maxLines: 1),
                  );
                },
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(
            verticalLines: [
              if (verticalMarkerX != null)
                VerticalLine(
                  x: verticalMarkerX!,
                  color: cs.onSurfaceVariant,
                  strokeWidth: 1.5,
                  dashArray: const [4, 4],
                ),
            ],
            horizontalLines: [
              if (horizontalMarkerY != null)
                HorizontalLine(
                  y: horizontalMarkerY!,
                  color: palette.bad,
                  strokeWidth: 2,
                  dashArray: const [8, 4],
                ),
            ],
          ),
          betweenBarsData: [
            for (final b in bands) BetweenBarsData(fromIndex: b.fromIndex, toIndex: b.toIndex, color: b.color),
          ],
          lineBarsData: [
            for (final s in series)
              LineChartBarData(
                spots: [for (final p in s.points) FlSpot(p.dx, p.dy)],
                color: s.color,
                barWidth: s.width,
                dashArray: s.style.dashArray,
                isStrokeCapRound: true,
                dotData: FlDotData(
                  show: s.showDots,
                  getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                    radius: 3,
                    color: s.color,
                    strokeWidth: 1,
                    strokeColor: palette.background,
                  ),
                ),
              ),
          ],
        ),
        duration: motion.chart,
        curve: motion.curve,
      );
    });
  }
}

/// A legend swatch for a line: a short line drawn in the series' dash style,
/// with the style named in words for screen readers.
class LineLegend extends StatelessWidget {
  const LineLegend({super.key, required this.entries});

  /// (label, color, style).
  final List<(String, Color, LineStyleKind)> entries;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'Legend',
      explicitChildNodes: true,
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          for (final (label, color, style) in entries)
            Semantics(
              label: '$label, ${style.label}',
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 32,
                    height: 14,
                    child: CustomPaint(painter: _LineSwatchPainter(color, style)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('$label (${style.label})',
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LineSwatchPainter extends CustomPainter {
  _LineSwatchPainter(this.color, this.style);

  final Color color;
  final LineStyleKind style;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final dashes = style.dashArray;
    if (dashes == null) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
      return;
    }
    var x = 0.0;
    var i = 0;
    while (x < size.width) {
      final len = dashes[i % dashes.length].toDouble();
      if (i.isEven) {
        canvas.drawLine(Offset(x, y), Offset(math.min(size.width, x + len), y), paint);
      }
      x += len;
      i++;
    }
  }

  @override
  bool shouldRepaint(_LineSwatchPainter old) => old.color != color || old.style != style;
}
