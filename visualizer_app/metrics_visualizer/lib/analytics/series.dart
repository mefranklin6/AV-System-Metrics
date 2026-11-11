// Small value types shared by several analytics results. Pure Dart.

/// One point of a daily or weekly series.
///
/// [date] is a calendar date in the analysis time zone encoded as UTC
/// midnight (the Monday for weekly series). Format it directly; do not call
/// `toLocal()` on it.
class SeriesPoint {
  const SeriesPoint(this.date, this.value, {this.coverage = 1.0});

  final DateTime date;

  /// Hours, counts or fractions depending on the series.
  final double value;

  /// Fraction (0-1) of this day/week that lies inside the dataset range.
  /// Partial periods at either end have coverage below 1 and their values
  /// are naturally smaller; charts should mark them.
  final double coverage;

  /// Whether the whole period is inside the dataset range.
  bool get isComplete => coverage >= 0.999;

  @override
  String toString() => 'SeriesPoint(${date.toIso8601String()}, $value)';
}

/// A 7 x 24 grid indexed by weekday (1 = Monday .. 7 = Sunday) and hour of
/// day (0-23) in the analysis time zone. Values are fractions 0-1.
class HourWeekdayHeatmap {
  const HourWeekdayHeatmap(this.values);

  /// An all-zero heatmap.
  factory HourWeekdayHeatmap.empty() => HourWeekdayHeatmap(
    List.unmodifiable([
      for (var d = 0; d < 7; d++)
        List<double>.unmodifiable(List.filled(24, 0.0)),
    ]),
  );

  /// `values[weekday - 1][hour]`.
  final List<List<double>> values;

  /// Value for [weekday] (1-7) and [hour] (0-23).
  double valueAt(int weekday, int hour) => values[weekday - 1][hour];

  /// Largest cell value.
  double get maxValue {
    var m = 0.0;
    for (final row in values) {
      for (final v in row) {
        if (v > m) m = v;
      }
    }
    return m;
  }

  /// Mean of the 24 hourly values of [weekday] (1-7).
  double weekdayMean(int weekday) {
    final row = values[weekday - 1];
    return row.fold<double>(0, (a, b) => a + b) / 24;
  }
}

/// One bar of a histogram over durations.
class DurationBucket {
  const DurationBucket({
    required this.label,
    required this.minMinutes,
    required this.maxMinutes,
    required this.count,
  });

  /// Display label such as `15-30 min` or `8 h+`.
  final String label;

  /// Inclusive lower bound in minutes.
  final double minMinutes;

  /// Exclusive upper bound in minutes; `null` for the open-ended last bucket.
  final double? maxMinutes;

  final int count;
}

/// A (metric, action) pair with its event count.
class MetricCount {
  const MetricCount(this.metric, this.action, this.count);
  final String metric;
  final String action;
  final int count;
}
