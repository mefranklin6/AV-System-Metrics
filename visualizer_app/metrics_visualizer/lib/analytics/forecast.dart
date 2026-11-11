// Trend fitting and forecasting result types. Pure Dart.

import 'dart:math' as math;

import 'series.dart';

/// Ordinary least-squares line `y = intercept + slope * x`.
class LinearFit {
  const LinearFit({
    required this.n,
    required this.slope,
    required this.intercept,
    required this.rSquared,
    required this.slopeStdError,
    required this.residualStdError,
    required this.xMean,
    required this.yMean,
  });

  /// Number of points.
  final int n;
  final double slope;
  final double intercept;

  /// Coefficient of determination (0-1). Defined as 1 when every y is equal
  /// (the flat line fits perfectly).
  final double rSquared;

  /// Standard error of [slope]: `sqrt(SSE / (n - 2) / Sxx)`; 0 when n <= 2.
  final double slopeStdError;

  /// Residual standard error: `sqrt(SSE / (n - 2))`; 0 when n <= 2.
  final double residualStdError;

  final double xMean;
  final double yMean;

  /// Fitted value at [x].
  double predict(double x) => intercept + slope * x;

  /// Fits [xs] / [ys] (same length). Returns `null` for fewer than two
  /// points or when every x is identical.
  static LinearFit? fit(List<double> xs, List<double> ys) {
    if (xs.length != ys.length) {
      throw ArgumentError('xs and ys must have the same length');
    }
    final n = xs.length;
    if (n < 2) return null;
    var sx = 0.0, sy = 0.0;
    for (var i = 0; i < n; i++) {
      sx += xs[i];
      sy += ys[i];
    }
    final xm = sx / n, ym = sy / n;
    var sxx = 0.0, sxy = 0.0, syy = 0.0;
    for (var i = 0; i < n; i++) {
      final dx = xs[i] - xm, dy = ys[i] - ym;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }
    if (sxx == 0) return null;
    final slope = sxy / sxx;
    final intercept = ym - slope * xm;
    var sse = 0.0;
    for (var i = 0; i < n; i++) {
      final r = ys[i] - (intercept + slope * xs[i]);
      sse += r * r;
    }
    final r2 = syy == 0 ? 1.0 : (1 - sse / syy).clamp(0.0, 1.0);
    final s = n > 2 ? math.sqrt(sse / (n - 2)) : 0.0;
    return LinearFit(
      n: n,
      slope: slope,
      intercept: intercept,
      rSquared: r2,
      slopeStdError: n > 2 ? s / math.sqrt(sxx) : 0.0,
      residualStdError: s,
      xMean: xm,
      yMean: ym,
    );
  }
}

/// Direction of a weekly trend.
enum TrendDirection { growing, stable, declining, insufficientData }

/// Which projection line to compute (see [TrendRules.projectedWeeklyHours]).
enum ProjectionBand {
  /// The central projection.
  expected,

  /// Slower wear: slope minus one standard error.
  low,

  /// Faster wear: slope plus one standard error.
  high,

  /// The average weekly rate, repeated.
  flat,
}

/// Rules used to classify trends and decide whether there is enough data.
class TrendRules {
  const TrendRules._();

  /// At least this many complete weeks are needed before fitting a trend.
  static const int minFullWeeks = 3;

  /// Input trends also need at least this many selections in those weeks.
  static const int minSelections = 10;

  /// |slope| must exceed this fraction of the weekly mean (2 % per week) to
  /// count as growing or declining.
  static const double minRelativeSlope = 0.02;

  /// ... and the fit must explain at least this much variance.
  static const double minRSquared = 0.25;

  /// Projection horizons, in years.
  static const List<int> horizonsYears = [1, 3, 5];

  /// Weeks per year used for projections.
  static const double weeksPerYear = 52.1775;

  /// Rated-life dates further out than this are reported as `null`.
  static const int maxProjectionYears = 50;

  /// A week cannot contain more than 168 hours of use.
  static const double maxHoursPerWeek = 168;

  /// A growing or declining trend is followed for at least this many weeks
  /// past the end of the data; after that the weekly rate is held.
  static const int trendHorizonWeeks = 52;

  /// Classifies a fit with weekly mean [mean].
  static TrendDirection classify(LinearFit? fit, double mean) {
    if (fit == null) return TrendDirection.insufficientData;
    if (mean <= 0) return TrendDirection.stable;
    final rel = fit.slope / mean;
    if (fit.rSquared < minRSquared || rel.abs() < minRelativeSlope) {
      return TrendDirection.stable;
    }
    return rel > 0 ? TrendDirection.growing : TrendDirection.declining;
  }

  /// Projected hours of use in future week [k] (1 = the first week after the
  /// data), shared by the engine and the forecast chart:
  ///
  /// * [ProjectionBand.flat], no [fit], or a [direction] that is not growing
  ///   or declining: the average weekly rate [mean] (a slope the rules call
  ///   "no clear trend" is never extrapolated). The low and high bands of a
  ///   stable trend pivot around that average by one standard error.
  /// * Growing or declining: the fitted line (low / high: slope -/+ one
  ///   standard error, pivoting on the mean week) for [trendHorizonWeeks]
  ///   weeks, then held at that week's rate.
  /// * Always kept between [minObserved] and [maxObserved] (the lowest and
  ///   highest complete week used for the fit) and within 0 to
  ///   [maxHoursPerWeek].
  static double projectedWeeklyHours({
    required LinearFit? fit,
    required TrendDirection direction,
    required double mean,
    required int k,
    ProjectionBand band = ProjectionBand.expected,
    double? minObserved,
    double? maxObserved,
  }) {
    var lo = minObserved == null || minObserved < 0 ? 0.0 : minObserved;
    var hi = maxObserved == null || maxObserved > maxHoursPerWeek
        ? maxHoursPerWeek
        : maxObserved;
    if (hi < lo) hi = lo;
    double bound(double r) => r < lo ? lo : (r > hi ? hi : r);
    if (fit == null || band == ProjectionBand.flat) return bound(mean);
    final trending =
        direction == TrendDirection.growing ||
        direction == TrendDirection.declining;
    final base = trending ? fit.slope : 0.0;
    final slope = switch (band) {
      ProjectionBand.low => base - fit.slopeStdError,
      ProjectionBand.high => base + fit.slopeStdError,
      _ => base,
    };
    if (slope == 0) return bound(trending ? fit.yMean : mean);
    final lastX = (fit.n - 1).toDouble();
    final weeks = k > trendHorizonWeeks ? trendHorizonWeeks : k;
    final centre = trending ? fit.yMean : mean;
    return bound(centre + slope * (lastX + weeks - fit.xMean));
  }
}

/// Projected cumulative observed hours some years after the end of the data.
class HourProjection {
  const HourProjection({
    required this.years,
    required this.expectedHours,
    required this.lowHours,
    required this.highHours,
    required this.flatRateHours,
  });

  final int years;

  /// Following the trend under [TrendRules.projectedWeeklyHours] (the
  /// average rate for a stable trend; a growing or declining one for at
  /// most [TrendRules.trendHorizonWeeks] weeks, within the observed range).
  final double expectedHours;

  /// Trend slope minus one standard error (pivoting on the mean week).
  final double lowHours;

  /// Trend slope plus one standard error.
  final double highHours;

  /// If usage simply continues at the average weekly rate.
  final double flatRateHours;
}

/// Usage forecast for one device.
class DeviceForecast {
  const DeviceForecast({
    required this.room,
    required this.building,
    required this.deviceId,
    required this.deviceType,
    required this.observedHours,
    required this.weekly,
    required this.fullWeeksUsed,
    required this.fit,
    required this.runRateHoursPerWeek,
    required this.direction,
    required this.projections,
    required this.ratedLifeHours,
    required this.ratedLifeReached,
    required this.projectedRatedLifeDate,
    required this.projectedRatedLifeDateEarliest,
    required this.projectedRatedLifeDateLatest,
    required this.projectedRatedLifeDateFlat,
    required this.explanation,
    this.minWeeklyHours,
    this.maxWeeklyHours,
  });

  final String room;
  final String building;
  final String deviceId;
  final String deviceType;

  String get key => '$room/$deviceId';

  /// Hours observed in this dataset. Hours before metrics collection began
  /// are unknown and not included.
  final double observedHours;

  /// Weekly on-hours (dense); incomplete weeks have coverage < 1.
  final List<SeriesPoint> weekly;

  /// Complete weeks used for the fit.
  final int fullWeeksUsed;

  /// `null` when there is not enough data ([TrendRules.minFullWeeks]).
  final LinearFit? fit;

  /// Average hours per complete week.
  final double runRateHoursPerWeek;

  final TrendDirection direction;

  /// Empty when [fit] is `null`.
  final List<HourProjection> projections;

  /// From [AnalysisConfig.ratedLifeHours]; `null` when not configured.
  final double? ratedLifeHours;

  /// Observed hours already exceed [ratedLifeHours].
  final bool ratedLifeReached;

  /// When cumulative observed hours reach [ratedLifeHours] following the
  /// trend; `null` if not applicable, already reached, or beyond
  /// [TrendRules.maxProjectionYears].
  final DateTime? projectedRatedLifeDate;

  /// Same, using the high (faster wear) band.
  final DateTime? projectedRatedLifeDateEarliest;

  /// Same, using the low (slower wear) band.
  final DateTime? projectedRatedLifeDateLatest;

  /// Same, assuming the current average weekly rate continues.
  final DateTime? projectedRatedLifeDateFlat;

  /// Fraction of rated life used by observed hours alone (0-1+), or `null`.
  double? get lifeUsedFraction => ratedLifeHours == null || ratedLifeHours! <= 0
      ? null
      : observedHours / ratedLifeHours!;

  /// Plain-language summary including assumptions.
  final String explanation;

  /// Lowest and highest complete week used for the fit; projections stay
  /// within them. `null` without a fit.
  final double? minWeeklyHours;
  final double? maxWeeklyHours;

  /// Projected hours of use in future week [k] (1 = the first week after the
  /// data) for [band], following the same rules as [projections] and the
  /// rated-life dates. See [TrendRules.projectedWeeklyHours].
  double projectedWeeklyHours(
    int k, [
    ProjectionBand band = ProjectionBand.expected,
  ]) => TrendRules.projectedWeeklyHours(
    fit: fit,
    direction: direction,
    mean: runRateHoursPerWeek,
    k: k,
    band: band,
    minObserved: minWeeklyHours,
    maxObserved: maxWeeklyHours,
  );
}

/// Weekly trend for one video input (campus-wide selections).
class InputTrend {
  const InputTrend({
    required this.key,
    required this.label,
    required this.weekly,
    required this.fit,
    required this.direction,
    required this.meanWeeklySelections,
    required this.percentChangePerWeek,
    required this.explanation,
  });

  final String key;
  final String label;

  /// Selections per week (dense).
  final List<SeriesPoint> weekly;
  final LinearFit? fit;
  final TrendDirection direction;
  final double meanWeeklySelections;

  /// Slope as a percentage of the weekly mean; `null` without a fit.
  final double? percentChangePerWeek;
  final String explanation;
}

/// All forecasts plus the assumptions to show next to them.
class ForecastReport {
  const ForecastReport({
    required this.devices,
    required this.inputs,
    required this.fullWeeksAvailable,
    required this.origin,
    required this.assumptions,
  });

  /// Sorted by projected rated-life date (soonest first, unknown last),
  /// then by key.
  final List<DeviceForecast> devices;

  /// Sorted by mean weekly selections, highest first.
  final List<InputTrend> inputs;

  /// Complete weeks in the dataset range.
  final int fullWeeksAvailable;

  /// Projections start here (the end of the dataset range).
  final DateTime origin;

  /// Plain-language assumptions and caveats.
  final List<String> assumptions;

  /// Whether the data is long enough for any trend.
  bool get hasEnoughData => fullWeeksAvailable >= TrendRules.minFullWeeks;
}
