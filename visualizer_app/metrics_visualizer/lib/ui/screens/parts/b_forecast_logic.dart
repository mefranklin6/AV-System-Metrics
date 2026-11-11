// Presentation logic for the Forecast screen: confidence ratings and the
// week-by-week projection curve drawn on the chart. Pure Dart (no widgets).

import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../../../analytics/analytics.dart';

/// How much to trust a device projection.
enum ForecastConfidence {
  high('High'),
  medium('Medium'),
  low('Low'),
  notEnoughData('Not enough data');

  const ForecastConfidence(this.label);

  final String label;
}

/// A confidence rating with the reason in plain language.
class ConfidenceAssessment {
  const ConfidenceAssessment(this.level, this.reason);

  final ForecastConfidence level;
  final String reason;
}

/// Rules behind [assessConfidence] (also shown on the methodology panel).
abstract final class ConfidenceRules {
  /// Complete weeks needed for "high".
  static const int highWeeks = 12;

  /// Complete weeks needed for "medium".
  static const int mediumWeeks = 6;

  /// Largest relative half-width of the one-year likely range for "high".
  static const double highSpread = 0.15;

  /// Largest relative half-width of the one-year likely range for "medium".
  static const double mediumSpread = 0.35;

  static String get description =>
      'Confidence combines how much history there is with how wide the likely range is. '
      'High: at least $highWeeks complete weeks and a one-year likely range within '
      '±${(highSpread * 100).round()}% of the projected hours. Medium: at least $mediumWeeks weeks and within '
      '±${(mediumSpread * 100).round()}%. Anything else is low.';
}

/// Rates [f]: more complete weeks and a narrower one-year likely range give
/// more confidence. The spread is the half-width of the likely range
/// divided by the hours projected to be added in that year.
ConfidenceAssessment assessConfidence(DeviceForecast f) {
  final fit = f.fit;
  if (fit == null || f.projections.isEmpty) {
    return ConfidenceAssessment(
      ForecastConfidence.notEnoughData,
      'Only ${f.fullWeeksUsed} complete weeks of data; at least ${TrendRules.minFullWeeks} are needed.',
    );
  }
  final oneYear = f.projections.firstWhere((p) => p.years == 1, orElse: () => f.projections.first);
  final added = oneYear.expectedHours - f.observedHours;
  final halfWidth = (oneYear.highHours - oneYear.lowHours).abs() / 2;
  final spread = added <= 0 ? double.infinity : halfWidth / added;
  final weeks = f.fullWeeksUsed;
  final pct = spread.isFinite ? '±${(spread * 100).round()}%' : 'very wide';
  final ForecastConfidence level;
  if (weeks >= ConfidenceRules.highWeeks && spread <= ConfidenceRules.highSpread) {
    level = ForecastConfidence.high;
  } else if (weeks >= ConfidenceRules.mediumWeeks && spread <= ConfidenceRules.mediumSpread) {
    level = ForecastConfidence.medium;
  } else {
    level = ForecastConfidence.low;
  }
  return ConfidenceAssessment(
    level,
    'Based on $weeks complete weeks; the one-year likely range is $pct of the projected hours.',
  );
}

/// Week-by-week cumulative hours for the chart. x is in weeks relative to
/// the end of the data (negative = past), y is cumulative observed hours.
class ProjectionCurve {
  const ProjectionCurve({
    required this.observed,
    required this.expected,
    required this.low,
    required this.high,
    required this.flat,
  });

  final List<Offset> observed;

  /// Empty when there is no fit.
  final List<Offset> expected;
  final List<Offset> low;
  final List<Offset> high;
  final List<Offset> flat;

  bool get hasProjection => expected.isNotEmpty;
}

const double _usPerWeek = 7 * 24 * 3600 * 1e6;

/// Builds the observed cumulative curve from [f.weekly] and projects it
/// [horizonWeeks] weeks past [origin] with [DeviceForecast.projectedWeeklyHours]
/// (the engine's own rule: weekly hours follow the fitted line or its +/- one
/// standard error slopes within the observed weekly range; the flat rate
/// repeats the average week).
///
/// [f.weekly] dates are calendar dates (week starts) in the analysis time
/// [zone], encoded as UTC midnight, while [origin] is an instant. Each week
/// start is converted to the instant it begins in [zone] (UTC when null)
/// before it is placed on the chart's week axis.
ProjectionCurve projectionCurve(DeviceForecast f, DateTime origin, {required int horizonWeeks, TimeBucketer? zone}) {
  final bucketer = zone ?? TimeBucketer(useLocalTime: false);
  int weekStartUs(DateTime calendarDate) =>
      bucketer.startOfDay(floorDiv(calendarDate.microsecondsSinceEpoch, usPerDay)).microsecondsSinceEpoch;
  final observed = <Offset>[];
  if (f.weekly.isNotEmpty) {
    var cum = 0.0;
    final first = f.weekly.first;
    final startUs = weekStartUs(first.date) +
        (1 - first.coverage).clamp(0.0, 1.0) * _usPerWeek;
    observed.add(Offset((startUs - origin.microsecondsSinceEpoch) / _usPerWeek, 0));
    for (final p in f.weekly) {
      cum += p.value;
      final endUs = math.min(
        (weekStartUs(p.date) + _usPerWeek).toDouble(),
        origin.microsecondsSinceEpoch.toDouble(),
      );
      observed.add(Offset((endUs - origin.microsecondsSinceEpoch) / _usPerWeek, cum));
    }
    // The last point is the end of the data with the device's total.
    observed[observed.length - 1] = Offset(math.min(0, observed.last.dx), f.observedHours);
  } else {
    observed.add(Offset(0, f.observedHours));
  }

  final fit = f.fit;
  if (fit == null || horizonWeeks <= 0) {
    return ProjectionCurve(observed: observed, expected: const [], low: const [], high: const [], flat: const []);
  }
  // Ask the engine for each week's projected hours (same mean, bounds and
  // trend horizon it used for the table and the rated-life dates), so the
  // chart and the table cannot disagree.
  double expectedRate(int k) => f.projectedWeeklyHours(k);
  double lowRate(int k) => f.projectedWeeklyHours(k, ProjectionBand.low);
  double highRate(int k) => f.projectedWeeklyHours(k, ProjectionBand.high);
  final flatRate = f.projectedWeeklyHours(1, ProjectionBand.flat);

  final expected = <Offset>[Offset(0, f.observedHours)];
  final low = <Offset>[Offset(0, f.observedHours)];
  final high = <Offset>[Offset(0, f.observedHours)];
  final flat = <Offset>[Offset(0, f.observedHours)];
  var e = f.observedHours, l = f.observedHours, h = f.observedHours, fl = f.observedHours;
  for (var k = 1; k <= horizonWeeks; k++) {
    e += expectedRate(k);
    l += lowRate(k);
    h += highRate(k);
    fl += flatRate;
    expected.add(Offset(k.toDouble(), e));
    low.add(Offset(k.toDouble(), l));
    high.add(Offset(k.toDouble(), h));
    flat.add(Offset(k.toDouble(), fl));
  }
  return ProjectionCurve(observed: observed, expected: expected, low: low, high: high, flat: flat);
}

/// Weeks in [years] years, as the engine counts them.
int weeksForYears(int years) => (years * TrendRules.weeksPerYear).round();
