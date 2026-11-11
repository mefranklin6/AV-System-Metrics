// Accessible chart primitives for the Overview, Inputs, Devices, System
// usage and Rooms screens.
//
// Every chart here:
// * draws series with the user's palette AND pattern, so nothing depends on
//   colour alone (WCAG 1.4.1);
// * sizes its text with the app's text scaler (WCAG 1.4.4);
// * takes its entrance animation from `Motion`, so "reduce motion" shows the
//   final state immediately;
// * is decorative to assistive technology: it is placed inside an
//   `AccessibleChartCard`, which exposes a plain-language summary and a data
//   table instead. The heat map is the exception: each cell has its own
//   semantic label (see [HeatmapGrid]).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../widgets/widgets.dart';

// ------------------------------------------------------------------ helpers

/// Height of one line of [style] at the current text scale.
double textLineHeight(BuildContext context, TextStyle? style) {
  final tp = TextPainter(
    text: TextSpan(text: 'Ag', style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final h = tp.height;
  tp.dispose();
  return h;
}

/// Width of [text] in [style] at the current text scale.
double textWidth(BuildContext context, String text, TextStyle? style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

/// Smallest "nice" number (1, 2, 2.5, 5 x 10^n) that is >= [value].
double niceCeiling(double value) {
  if (value <= 0 || !value.isFinite) return 1;
  final exp = math.pow(10, (math.log(value) / math.ln10).floor()).toDouble();
  for (final m in const [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (m * exp >= value - 1e-9) return m * exp;
  }
  return 10 * exp;
}

/// Plays a chart's entrance once per [dataKey]. [builder] receives the
/// progress 0..1; under reduce motion it is always 1.
class ChartEntrance extends StatelessWidget {
  const ChartEntrance({super.key, required this.dataKey, required this.builder});

  /// Changing this restarts the entrance (use a hash of the plotted values).
  final Object dataKey;
  final Widget Function(BuildContext context, double progress) builder;

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context);
    if (motion.reduced) return builder(context, 1);
    return TweenAnimationBuilder<double>(
      key: ValueKey(dataKey),
      tween: Tween(begin: 0, end: 1),
      duration: motion.chart,
      curve: motion.curve,
      builder: (context, t, _) => builder(context, t),
    );
  }
}

TextPainter _painter(String text, TextStyle style, TextScaler scaler, {double? maxWidth}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
    ellipsis: maxWidth == null ? null : '…',
  )..layout(maxWidth: maxWidth ?? double.infinity);
  return tp;
}

void _paintBar(
  Canvas canvas,
  RRect r,
  Color color,
  ChartPattern pattern,
  ChartPalette palette, {
  bool partial = false,
}) {
  if (r.width <= 0 || r.height <= 0) return;
  final path = Path()..addRRect(r);
  canvas.drawRRect(r, Paint()..color = partial ? color.withValues(alpha: 0.45) : color);
  final effective = partial && pattern == ChartPattern.solid ? ChartPattern.diagonal : pattern;
  paintChartPattern(canvas, r.outerRect, effective, palette.onColor(color), clip: path, spacing: 6);
  if (partial) {
    canvas.drawRRect(
      r.deflate(0.75),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }
}

// -------------------------------------------------------------------- donut

/// One slice of a [DonutChart].
@immutable
class DonutSlice {
  const DonutSlice({required this.label, required this.value, required this.color, this.pattern = ChartPattern.solid});

  final String label;
  final double value;
  final Color color;
  final ChartPattern pattern;
}

/// A donut chart with patterned slices, separators between slices and the
/// percentage written on every slice large enough to hold it. Put the
/// legend (with values) next to it so every slice is labelled directly.
class DonutChart extends StatelessWidget {
  const DonutChart({super.key, required this.slices, this.centerValue, this.centerLabel});

  final List<DonutSlice> slices;
  final String? centerValue;
  final String? centerLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final key = Object.hashAll([for (final s in slices) s.value]);
    return LayoutBuilder(
      builder: (context, constraints) {
        final d = math.min(constraints.maxWidth, constraints.maxHeight);
        final inner = d * (1 - _DonutPainter.thicknessFraction) * 0.68;
        return Center(
          child: SizedBox.square(
            dimension: d,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: ChartEntrance(
                    dataKey: key,
                    builder: (context, t) => CustomPaint(
                      painter: _DonutPainter(
                        slices: slices,
                        progress: t,
                        palette: palette,
                        labelBackground: cs.surfaceContainerLow,
                        labelStyle: theme.textTheme.labelMedium!.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                        scaler: scaler,
                      ),
                    ),
                  ),
                ),
                if (centerValue != null && inner > 24)
                  SizedBox.square(
                    dimension: inner,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            centerValue!,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                            ),
                          ),
                          if (centerLabel != null)
                            Text(centerLabel!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.slices,
    required this.progress,
    required this.palette,
    required this.labelBackground,
    required this.labelStyle,
    required this.scaler,
  });

  static const double thicknessFraction = 0.42;

  final List<DonutSlice> slices;
  final double progress;
  final ChartPalette palette;
  final Color labelBackground;
  final TextStyle labelStyle;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    final total = slices.fold<double>(0, (a, s) => a + math.max(0, s.value));
    final center = size.center(Offset.zero);
    final rOut = math.min(size.width, size.height) / 2 - 2;
    if (rOut <= 4) return;
    final rIn = rOut * (1 - thicknessFraction);
    final outerRect = Rect.fromCircle(center: center, radius: rOut);
    final innerRect = Rect.fromCircle(center: center, radius: rIn);
    if (total <= 0) {
      canvas.drawCircle(
        center,
        (rOut + rIn) / 2,
        Paint()
          ..color = palette.gridLine
          ..style = PaintingStyle.stroke
          ..strokeWidth = rOut - rIn,
      );
      return;
    }
    var start = -math.pi / 2;
    final separator = Paint()
      ..color = palette.separator
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final labels = <(double, String)>[];
    for (final s in slices) {
      if (s.value <= 0) continue;
      final share = s.value / total;
      final sweep = math.min(share * 2 * math.pi * progress, 2 * math.pi - 1e-4);
      if (sweep <= 0) continue;
      final path = Path()
        ..arcTo(outerRect, start, sweep, true)
        ..arcTo(innerRect, start + sweep, -sweep, false)
        ..close();
      canvas.drawPath(path, Paint()..color = s.color);
      paintChartPattern(canvas, path.getBounds(), s.pattern, palette.onColor(s.color), clip: path);
      if (slices.length > 1) canvas.drawPath(path, separator);
      if (share >= 0.06) labels.add((start + sweep / 2, '${(share * 100).round()}%'));
      start += sweep;
    }
    if (progress < 1) return;
    final mid = (rOut + rIn) / 2;
    for (final (angle, text) in labels) {
      final tp = _painter(text, labelStyle, scaler);
      final c = center + Offset(math.cos(angle) * mid, math.sin(angle) * mid);
      final box = Rect.fromCenter(center: c, width: tp.width + 8, height: tp.height + 2);
      canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(4)), Paint()..color = labelBackground);
      tp.paint(canvas, Offset(box.left + 4, box.top + 1));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_DonutPainter old) =>
      old.slices != slices ||
      old.progress != progress ||
      old.palette.kind != palette.kind ||
      old.palette.background != palette.background ||
      old.palette.patternsEnabled != palette.patternsEnabled ||
      old.scaler != scaler ||
      old.labelStyle != labelStyle;
}

// ----------------------------------------------------------- ranked bars

/// One row of a [RankedBarChart].
@immutable
class BarDatum {
  const BarDatum({
    required this.label,
    required this.value,
    required this.valueLabel,
    required this.color,
    this.pattern = ChartPattern.solid,
  });

  final String label;
  final double value;

  /// Formatted value written at the end of the row (direct label).
  final String valueLabel;
  final Color color;
  final ChartPattern pattern;
}

/// Horizontal bars, one labelled row per item, value written next to every
/// bar. Rows are Flutter text, so they follow the text-size setting.
///
/// Use [RankedBarChart.layoutFor] to get the height for an
/// `AccessibleChartCard`: below [stackWidth] the label sits above its bar,
/// and when a label and its value do not fit on one line they get a line
/// each, so nothing overflows at 200% text.
class RankedBarChart extends StatelessWidget {
  const RankedBarChart({super.key, required this.items, required this.stacked, this.maxValue});

  final List<BarDatum> items;

  /// Label above the bar (narrow) instead of beside it.
  final bool stacked;
  final double? maxValue;

  static const double barThickness = 18;

  /// Chart widths below this stack the label above the bar.
  static const double stackWidth = 520;

  /// Whether rows stack at [width] for the current text size.
  static bool stackedFor(BuildContext context, double width) {
    final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
    return width < stackWidth * math.max(1, scale * 0.8);
  }

  static TextStyle? _labelStyle(BuildContext context) => Theme.of(context).textTheme.bodyMedium;
  static TextStyle? _valueStyle(BuildContext context) =>
      Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700);

  /// Whether [b]'s label and value need separate lines at [width].
  static bool _twoLines(BuildContext context, BarDatum b, double width) =>
      textWidth(context, b.label, _labelStyle(context)) + 12 + textWidth(context, b.valueLabel, _valueStyle(context)) >
      width;

  /// Height of each row at chart [width].
  static List<double> rowHeights(BuildContext context, List<BarDatum> items, double width, bool stacked) {
    final line = textLineHeight(context, _labelStyle(context)) + 2;
    if (!stacked) {
      final h = math.max(line, barThickness) + 14;
      return [for (final _ in items) h];
    }
    return [for (final b in items) (_twoLines(context, b, width) ? 2 * line : line) + 4 + barThickness + 12];
  }

  /// (stacked, chart height) for [items] in a card [cardWidth] wide.
  static (bool, double) layoutFor(BuildContext context, double cardWidth, List<BarDatum> items) {
    // AccessibleChartCard pads the chart by 20 on each side.
    final width = cardWidth - 40;
    final stacked = stackedFor(context, width);
    final heights = rowHeights(context, items, width, stacked);
    return (stacked, math.max(1.0, heights.fold<double>(0, (s, h) => s + h)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final style = _labelStyle(context)?.copyWith(color: cs.onSurface);
    final valueStyle = _valueStyle(context)?.copyWith(color: cs.onSurface);
    final max = maxValue ?? items.fold<double>(0, (m, b) => b.value > m ? b.value : m);
    final key = Object.hashAll([for (final b in items) b.value]);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final heights = rowHeights(context, items, width, stacked);
        double valueW = 0;
        for (final b in items) {
          valueW = math.max(valueW, textWidth(context, b.valueLabel, valueStyle));
        }
        valueW = math.min(valueW + 4, width * 0.35);
        final labelW = math.min(width * 0.32, 240.0);
        Widget label(BarDatum b) => Text(b.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
        Widget value(BarDatum b, {TextAlign align = TextAlign.start}) =>
            Text(b.valueLabel, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: valueStyle);
        Widget row(BarDatum b, double t) {
          final bar = SizedBox(
            height: barThickness,
            child: _Bar(b: b, fraction: max <= 0 ? 0 : b.value / max * t, palette: palette),
          );
          if (!stacked) {
            return Row(
              children: [
                SizedBox(width: labelW, child: label(b)),
                const SizedBox(width: 12),
                Expanded(child: bar),
                const SizedBox(width: 12),
                SizedBox(
                  width: valueW,
                  child: value(b, align: TextAlign.end),
                ),
              ],
            );
          }
          final twoLines = _twoLines(context, b, width);
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (twoLines) ...[
                label(b),
                value(b),
              ] else
                Row(
                  children: [
                    Expanded(child: label(b)),
                    const SizedBox(width: 12),
                    value(b),
                  ],
                ),
              const SizedBox(height: 4),
              bar,
            ],
          );
        }

        return ChartEntrance(
          dataKey: key,
          builder: (context, t) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (var i = 0; i < items.length; i++) SizedBox(height: heights[i], child: row(items[i], t))],
          ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.b, required this.fraction, required this.palette});

  final BarDatum b;
  final double fraction;
  final ChartPalette palette;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(painter: _BarPainter(b.color, b.pattern, fraction.clamp(0.0, 1.0), palette), size: Size.infinite);
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.color, this.pattern, this.fraction, this.palette);

  final Color color;
  final ChartPattern pattern;
  final double fraction;
  final ChartPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline so a zero value is visibly "zero", not missing.
    canvas.drawLine(
      Offset(0.5, 0),
      Offset(0.5, size.height),
      Paint()
        ..color = palette.neutral
        ..strokeWidth = 1,
    );
    final w = size.width * fraction;
    if (w < 0.5) return;
    final r = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, math.max(w, 2), size.height),
      topRight: const Radius.circular(4),
      bottomRight: const Radius.circular(4),
    );
    _paintBar(canvas, r, color, pattern, palette);
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.color != color ||
      old.pattern != pattern ||
      old.fraction != fraction ||
      old.palette.background != palette.background;
}

// ------------------------------------------------------------------ columns

/// One column of a [ColumnChart].
@immutable
class ColumnDatum {
  const ColumnDatum({required this.label, required this.value, this.valueLabel, this.partial = false});

  /// X-axis label.
  final String label;
  final double value;

  /// Written above the column when there is room.
  final String? valueLabel;

  /// Incomplete period: drawn lighter, hatched and outlined.
  final bool partial;
}

/// Vertical columns with a labelled y axis (histograms, hourly counts).
class ColumnChart extends StatelessWidget {
  const ColumnChart({
    super.key,
    required this.data,
    required this.yFormat,
    this.color,
    this.pattern = ChartPattern.solid,
    this.showValues = true,
  });

  final List<ColumnDatum> data;
  final String Function(double value) yFormat;

  /// Defaults to the first palette colour.
  final Color? color;
  final ChartPattern pattern;

  /// Write each column's value above it when every label fits.
  final bool showValues;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return ChartEntrance(
      dataKey: Object.hashAll([for (final d in data) d.value]),
      builder: (context, t) => CustomPaint(
        size: Size.infinite,
        painter: _ColumnPainter(
          data: data,
          progress: t,
          color: color ?? palette.colorAt(0),
          pattern: pattern,
          palette: palette,
          axisStyle: theme.textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
          valueStyle: theme.textTheme.labelSmall!.copyWith(color: cs.onSurface, fontWeight: FontWeight.w700),
          scaler: scaler,
          yFormat: yFormat,
          showValues: showValues,
        ),
      ),
    );
  }
}

class _ColumnPainter extends CustomPainter {
  _ColumnPainter({
    required this.data,
    required this.progress,
    required this.color,
    required this.pattern,
    required this.palette,
    required this.axisStyle,
    required this.valueStyle,
    required this.scaler,
    required this.yFormat,
    required this.showValues,
  });

  final List<ColumnDatum> data;
  final double progress;
  final Color color;
  final ChartPattern pattern;
  final ChartPalette palette;
  final TextStyle axisStyle;
  final TextStyle valueStyle;
  final TextScaler scaler;
  final String Function(double) yFormat;
  final bool showValues;

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty || size.width <= 0 || size.height <= 0) return;
    final maxV = data.fold<double>(0, (m, d) => math.max(m, d.value));
    final top = niceCeiling(maxV);
    final ticks = [0.0, top / 2, top];
    final tickPainters = [for (final v in ticks) _painter(yFormat(v), axisStyle, scaler)];
    final left = tickPainters.fold<double>(0, (m, p) => math.max(m, p.width)) + 8;
    final xPainters = [for (final d in data) _painter(d.label, axisStyle, scaler)];
    final xH = xPainters.fold<double>(0, (m, p) => math.max(m, p.height));
    final valuePainters = showValues
        ? [for (final d in data) _painter(d.valueLabel ?? yFormat(d.value), valueStyle, scaler)]
        : const <TextPainter>[];
    final vH = valuePainters.fold<double>(0, (m, p) => math.max(m, p.height));
    final topPad = math.max(tickPainters.last.height / 2, vH + 4);
    final plot = Rect.fromLTRB(left, topPad, size.width - 4, size.height - xH - 6);
    if (plot.width <= 0 || plot.height <= 4) {
      _dispose([...tickPainters, ...xPainters, ...valuePainters]);
      return;
    }

    final grid = Paint()
      ..color = palette.gridLine
      ..strokeWidth = 1;
    for (var i = 0; i < ticks.length; i++) {
      final y = plot.bottom - plot.height * (ticks[i] / top);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final tp = tickPainters[i];
      tp.paint(canvas, Offset(left - 8 - tp.width, y - tp.height / 2));
    }

    final slot = plot.width / data.length;
    final barW = math.max(1.0, slot * 0.72);
    final widestValue = valuePainters.fold<double>(0, (m, p) => math.max(m, p.width));
    final drawValues = showValues && widestValue + 2 <= slot;
    for (var i = 0; i < data.length; i++) {
      final d = data[i];
      final h = plot.height * (d.value / top) * progress;
      final x = plot.left + slot * i + (slot - barW) / 2;
      final r = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, plot.bottom - h, barW, h),
        topLeft: const Radius.circular(3),
        topRight: const Radius.circular(3),
      );
      _paintBar(canvas, r, color, pattern, palette, partial: d.partial);
      if (drawValues && progress >= 1 && d.value > 0) {
        final tp = valuePainters[i];
        tp.paint(canvas, Offset(x + barW / 2 - tp.width / 2, plot.bottom - h - tp.height - 2));
      }
    }
    // Baseline.
    canvas.drawLine(
      Offset(plot.left, plot.bottom),
      Offset(plot.right, plot.bottom),
      Paint()
        ..color = palette.neutral
        ..strokeWidth = 1,
    );

    // X labels: as many as fit without overlapping.
    final widest = xPainters.fold<double>(0, (m, p) => math.max(m, p.width)) + 8;
    final step = math.max(1, (widest / slot).ceil());
    for (var i = 0; i < data.length; i += step) {
      final tp = xPainters[i];
      var x = plot.left + slot * i + slot / 2 - tp.width / 2;
      x = x.clamp(0, size.width - tp.width).toDouble();
      tp.paint(canvas, Offset(x, plot.bottom + 4));
    }
    _dispose([...tickPainters, ...xPainters, ...valuePainters]);
  }

  static void _dispose(List<TextPainter> ps) {
    for (final p in ps) {
      p.dispose();
    }
  }

  @override
  bool shouldRepaint(_ColumnPainter old) =>
      old.data != data ||
      old.progress != progress ||
      old.color != color ||
      old.pattern != pattern ||
      old.scaler != scaler ||
      old.axisStyle != axisStyle ||
      old.palette.background != palette.background;
}

// --------------------------------------------------------------------- lines

/// Marker shapes, so line series differ by shape as well as colour.
enum MarkerShape { circle, square, triangle, diamond }

/// One line of a [TrendLineChart].
@immutable
class TrendSeries {
  const TrendSeries({
    required this.label,
    required this.values,
    required this.color,
    required this.marker,
    this.partial = const [],
  });

  final String label;
  final List<double> values;

  /// Same length as [values] (or empty): true marks an incomplete period,
  /// drawn with a hollow marker and a dashed connecting segment.
  final List<bool> partial;
  final Color color;
  final MarkerShape marker;

  bool isPartial(int i) => i < partial.length && partial[i];
}

/// Marker shape for series [index].
MarkerShape markerAt(int index) => MarkerShape.values[index % MarkerShape.values.length];

/// A line chart over evenly spaced periods (days or weeks).
class TrendLineChart extends StatelessWidget {
  const TrendLineChart({super.key, required this.series, required this.xLabels, required this.yFormat});

  final List<TrendSeries> series;
  final List<String> xLabels;
  final String Function(double value) yFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    return ChartEntrance(
      dataKey: Object.hashAll([for (final s in series) Object.hashAll(s.values)]),
      builder: (context, t) => CustomPaint(
        size: Size.infinite,
        painter: _LinePainter(
          series: series,
          xLabels: xLabels,
          progress: t,
          palette: palette,
          axisStyle: theme.textTheme.bodySmall!.copyWith(color: cs.onSurfaceVariant),
          scaler: MediaQuery.textScalerOf(context),
          yFormat: yFormat,
        ),
      ),
    );
  }
}

/// Draws [shape] centred on [c].
void paintMarker(
  Canvas canvas,
  Offset c,
  MarkerShape shape,
  Color color,
  Color background, {
  double size = 5,
  bool hollow = false,
}) {
  final path = switch (shape) {
    MarkerShape.circle => Path()..addOval(Rect.fromCircle(center: c, radius: size)),
    MarkerShape.square => Path()..addRect(Rect.fromCenter(center: c, width: size * 1.8, height: size * 1.8)),
    MarkerShape.triangle =>
      Path()
        ..moveTo(c.dx, c.dy - size * 1.15)
        ..lineTo(c.dx + size * 1.1, c.dy + size * 0.85)
        ..lineTo(c.dx - size * 1.1, c.dy + size * 0.85)
        ..close(),
    MarkerShape.diamond =>
      Path()
        ..moveTo(c.dx, c.dy - size * 1.25)
        ..lineTo(c.dx + size * 1.25, c.dy)
        ..lineTo(c.dx, c.dy + size * 1.25)
        ..lineTo(c.dx - size * 1.25, c.dy)
        ..close(),
  };
  canvas.drawPath(path, Paint()..color = hollow ? background : color);
  canvas.drawPath(
    path,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2,
  );
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.series,
    required this.xLabels,
    required this.progress,
    required this.palette,
    required this.axisStyle,
    required this.scaler,
    required this.yFormat,
  });

  final List<TrendSeries> series;
  final List<String> xLabels;
  final double progress;
  final ChartPalette palette;
  final TextStyle axisStyle;
  final TextScaler scaler;
  final String Function(double) yFormat;

  @override
  void paint(Canvas canvas, Size size) {
    final n = xLabels.length;
    if (n == 0 || series.isEmpty || size.width <= 0) return;
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        maxV = math.max(maxV, v);
      }
    }
    final top = niceCeiling(maxV);
    final ticks = [0.0, top / 2, top];
    final tickPainters = [for (final v in ticks) _painter(yFormat(v), axisStyle, scaler)];
    final left = tickPainters.fold<double>(0, (m, p) => math.max(m, p.width)) + 10;
    final xPainters = [for (final l in xLabels) _painter(l, axisStyle, scaler)];
    final xH = xPainters.fold<double>(0, (m, p) => math.max(m, p.height));
    final plot = Rect.fromLTRB(left + 6, tickPainters.last.height / 2 + 8, size.width - 10, size.height - xH - 8);
    if (plot.width <= 0 || plot.height <= 4) {
      for (final p in [...tickPainters, ...xPainters]) {
        p.dispose();
      }
      return;
    }
    final grid = Paint()
      ..color = palette.gridLine
      ..strokeWidth = 1;
    for (var i = 0; i < ticks.length; i++) {
      final y = plot.bottom - plot.height * (ticks[i] / top);
      canvas.drawLine(Offset(plot.left - 6, y), Offset(plot.right, y), grid);
      final tp = tickPainters[i];
      tp.paint(canvas, Offset(left - 6 - tp.width, y - tp.height / 2));
    }
    double xAt(int i) => n == 1 ? plot.center.dx : plot.left + plot.width * i / (n - 1);
    double yAt(double v) => plot.bottom - plot.height * (v / top);

    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, 0, plot.left + (plot.width + 12) * progress, size.height));
    for (final s in series) {
      final line = Paint()
        ..color = s.color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      for (var i = 1; i < s.values.length && i < n; i++) {
        final a = Offset(xAt(i - 1), yAt(s.values[i - 1]));
        final b = Offset(xAt(i), yAt(s.values[i]));
        if (s.isPartial(i) || s.isPartial(i - 1)) {
          _dashed(canvas, a, b, line);
        } else {
          canvas.drawLine(a, b, line);
        }
      }
      for (var i = 0; i < s.values.length && i < n; i++) {
        paintMarker(
          canvas,
          Offset(xAt(i), yAt(s.values[i])),
          s.marker,
          s.color,
          palette.background,
          hollow: s.isPartial(i),
        );
      }
    }
    canvas.restore();

    final widest = xPainters.fold<double>(0, (m, p) => math.max(m, p.width)) + 12;
    final slot = n == 1 ? plot.width : plot.width / (n - 1);
    final step = math.max(1, (widest / slot).ceil());
    for (var i = 0; i < n; i += step) {
      final tp = xPainters[i];
      final x = (xAt(i) - tp.width / 2).clamp(0, size.width - tp.width).toDouble();
      tp.paint(canvas, Offset(x, plot.bottom + 6));
    }
    for (final p in [...tickPainters, ...xPainters]) {
      p.dispose();
    }
  }

  static void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    for (var d = 0.0; d < total; d += 9) {
      final e = math.min(d + 5, total);
      canvas.drawLine(a + dir * d, a + dir * e, paint);
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.series != series ||
      old.xLabels != xLabels ||
      old.progress != progress ||
      old.scaler != scaler ||
      old.axisStyle != axisStyle ||
      old.palette.background != palette.background;
}

/// Legend entry for a [TrendLineChart] series.
@immutable
class MarkerLegendItem {
  const MarkerLegendItem({required this.label, required this.color, required this.marker, this.value});

  final String label;
  final Color color;
  final MarkerShape marker;
  final String? value;
}

/// Legend for line charts: a line with the series' marker shape and a text
/// label (and value), so series are identified without colour.
class MarkerLegend extends StatelessWidget {
  const MarkerLegend({super.key, required this.items, this.note});

  final List<MarkerLegendItem> items;

  /// Optional extra entry, e.g. "Hollow marker: partial week".
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    return Semantics(
      container: true,
      label: 'Legend',
      explicitChildNodes: true,
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          for (final item in items)
            Semantics(
              label: [item.label, ?item.value, '${item.marker.name} markers'].join(', '),
              excludeSemantics: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 28,
                    height: 16,
                    child: CustomPaint(
                      painter: _MarkerSwatchPainter(item.color, item.marker, palette.background, false),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: item.label),
                          if (item.value != null)
                            TextSpan(
                              text: '  ${item.value}',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                        ],
                      ),
                      style: style,
                    ),
                  ),
                ],
              ),
            ),
          if (note != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(
                  child: SizedBox(
                    width: 28,
                    height: 16,
                    child: CustomPaint(
                      painter: _MarkerSwatchPainter(cs.onSurfaceVariant, MarkerShape.circle, palette.background, true),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(child: Text(note!, style: style)),
              ],
            ),
        ],
      ),
    );
  }
}

class _MarkerSwatchPainter extends CustomPainter {
  _MarkerSwatchPainter(this.color, this.marker, this.background, this.dashed);

  final Color color;
  final MarkerShape marker;
  final Color background;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.5;
    if (dashed) {
      _LinePainter._dashed(canvas, Offset(0, y), Offset(size.width, y), p);
    } else {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
    paintMarker(canvas, Offset(size.width / 2, y), marker, color, background, size: 4.5, hollow: dashed);
  }

  @override
  bool shouldRepaint(_MarkerSwatchPainter old) =>
      old.color != color || old.marker != marker || old.background != background || old.dashed != dashed;
}

// ------------------------------------------------------------------ heat map

/// Fill colour for a heat-map value [t] (0..1): from the card background to
/// the first palette colour, so darker/stronger means more.
Color heatColor(ChartPalette palette, double t) {
  if (t <= 0) return palette.background;
  return Color.lerp(palette.background, palette.colorAt(0), 0.12 + 0.88 * t.clamp(0.0, 1.0))!;
}

/// A weekday x hour grid. Every cell is its own semantics node with a label
/// such as "Tuesday 10 AM: 62% of rooms in use", and shows its number when
/// it is wide enough, so the grid does not rely on colour alone. On narrow
/// screens the grid turns so hours run down the page (reflow).
class HeatmapGrid extends StatelessWidget {
  const HeatmapGrid({super.key, required this.values, required this.cellLabel, this.scaleMax});

  /// `values[weekday - 1][hour]`, fractions 0..1.
  final List<List<double>> values;

  /// Semantic label for a cell: (weekday 1-7, hour 0-23, value).
  final String Function(int weekday, int hour, double value) cellLabel;

  /// Value that maps to the strongest colour (defaults to the largest value).
  final double? scaleMax;

  /// Width below which the grid is transposed.
  static const double transposeWidth = 640;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final palette = ChartPalette.of(context);
    final axis = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final cellText = theme.textTheme.labelSmall;
    var maxV = scaleMax ?? 0;
    if (scaleMax == null) {
      for (final row in values) {
        for (final v in row) {
          if (v > maxV) maxV = v;
        }
      }
    }
    final line = textLineHeight(context, axis);
    final numberW = textWidth(context, '100', cellText) + 6;

    Widget cell(int weekday, int hour, double w, double h) {
      final v = values[weekday - 1][hour];
      final t = maxV <= 0 ? 0.0 : v / maxV;
      final fill = heatColor(palette, t);
      final showNumber = w >= numberW && h >= textLineHeight(context, cellText);
      return Semantics(
        container: true,
        label: cellLabel(weekday, hour, v),
        excludeSemantics: true,
        child: Container(
          width: w,
          height: h,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: palette.gridLine, width: 0.5),
          ),
          child: showNumber && v > 0
              ? Text('${(v * 100).round()}', maxLines: 1, style: cellText?.copyWith(color: palette.onColor(fill)))
              : null,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final transposed = width < transposeWidth;
        if (!transposed) {
          final labelW =
              [for (var d = 1; d <= 7; d++) textWidth(context, Fmt.weekday(d, short: true), axis)].reduce(math.max) + 8;
          final cellW = ((width - labelW) / 24).floorToDouble();
          final cellH = math.max(24.0, textLineHeight(context, cellText) + 8);
          final hourW = textWidth(context, Fmt.hourOfDay(12), axis) + 6;
          final step = math.max(1, (hourW / cellW).ceil());
          final usedStep = const [1, 2, 3, 4, 6, 12].firstWhere((s) => s >= step, orElse: () => 12);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var d = 1; d <= 7; d++)
                Row(
                  children: [
                    SizedBox(
                      width: labelW,
                      child: ExcludeSemantics(child: Text(Fmt.weekday(d, short: true), style: axis)),
                    ),
                    for (var h = 0; h < 24; h++) cell(d, h, cellW, cellH),
                  ],
                ),
              const SizedBox(height: 4),
              ExcludeSemantics(
                child: SizedBox(
                  height: line + 2,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var h = 0; h < 24; h += usedStep)
                        Positioned(
                          left: labelW + cellW * h,
                          top: 0,
                          width: math.min(cellW * usedStep, width - labelW - cellW * h),
                          child: Text(Fmt.hourOfDay(h), maxLines: 1, overflow: TextOverflow.clip, style: axis),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        final labelW = textWidth(context, Fmt.hourOfDay(12), axis) + 10;
        final cellW = ((width - labelW) / 7).floorToDouble();
        final cellH = math.max(22.0, textLineHeight(context, cellText) + 6);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Row(
                children: [
                  SizedBox(width: labelW),
                  for (var d = 1; d <= 7; d++)
                    SizedBox(
                      width: cellW,
                      child: Text(
                        Fmt.weekday(d, short: true),
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        textAlign: TextAlign.center,
                        style: axis,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            for (var h = 0; h < 24; h++)
              Row(
                children: [
                  SizedBox(
                    width: labelW,
                    child: ExcludeSemantics(child: Text(Fmt.hourOfDay(h), maxLines: 1, style: axis)),
                  ),
                  for (var d = 1; d <= 7; d++) cell(d, h, cellW, cellH),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// The colour scale of a heat map with numeric ticks at 0, half and [max].
/// Painted, so it never overflows; the numbers are also in the card's
/// summary and table.
class HeatmapScale extends StatelessWidget {
  const HeatmapScale({super.key, required this.max, required this.format});

  final double max;
  final String Function(double value) format;

  static const double _barHeight = 16;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      size: Size.infinite,
      painter: _ScalePainter(
        ChartPalette.of(context),
        [
          for (final f in const [0.0, 0.5, 1.0]) format(max * f),
        ],
        theme.textTheme.bodySmall!.copyWith(color: theme.colorScheme.onSurfaceVariant),
        MediaQuery.textScalerOf(context),
      ),
    );
  }

  /// Height for an `AccessibleChartCard` chart slot.
  static double heightFor(BuildContext context) =>
      _barHeight + 6 + textLineHeight(context, Theme.of(context).textTheme.bodySmall) + 2;
}

class _ScalePainter extends CustomPainter {
  _ScalePainter(this.palette, this.ticks, this.style, this.scaler);

  final ChartPalette palette;
  final List<String> ticks;
  final TextStyle style;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    const steps = 40;
    final bar = Rect.fromLTWH(0, 0, size.width, HeatmapScale._barHeight);
    final w = bar.width / steps;
    for (var i = 0; i < steps; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * w, 0, w + 0.5, bar.height),
        Paint()..color = heatColor(palette, (i + 0.5) / steps),
      );
    }
    canvas.drawRect(
      bar,
      Paint()
        ..color = palette.neutral
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    for (var i = 0; i < ticks.length; i++) {
      final tp = _painter(ticks[i], style, scaler, maxWidth: size.width / ticks.length);
      final x = switch (i) {
        0 => 0.0,
        _ when i == ticks.length - 1 => size.width - tp.width,
        _ => (size.width - tp.width) / 2,
      };
      tp.paint(canvas, Offset(x, bar.bottom + 6));
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(_ScalePainter old) =>
      old.palette.background != palette.background ||
      old.palette.kind != palette.kind ||
      old.style != style ||
      old.scaler != scaler ||
      old.ticks.join() != ticks.join();
}
