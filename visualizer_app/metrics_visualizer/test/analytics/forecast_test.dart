import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

/// A projector that is on `hoursPerWeek[w]` hours in week w (sessions of
/// up to 8 h starting 08:00 each day from Monday), over a range of exactly
/// `hoursPerWeek.length` weeks.
Dataset projectorWeeks(List<double> hoursPerWeek, {String room = 'A_1'}) {
  final events = <MetricEvent>[];
  for (var w = 0; w < hoursPerWeek.length; w++) {
    var remaining = hoursPerWeek[w];
    for (var d = 0; remaining > 0; d++) {
      final h = math.min(8.0, remaining);
      final start = monday.add(Duration(days: 7 * w + d, hours: 8));
      events
        ..add(ev(room, start, 'Projector_1', 'Started'))
        ..add(ev(room, start.add(hrs(h)), 'Projector_1', 'Stopped'));
      remaining -= h;
    }
  }
  return ds(
    events,
    start: monday,
    end: monday.add(Duration(days: 7 * hoursPerWeek.length)),
  );
}

void main() {
  group('LinearFit', () {
    test('matches hand-computed least squares', () {
      // xs 0..3, ys 1,3,2,5: Sxx = 5, Sxy = 5.5, slope 1.1, intercept 1.1,
      // SSE = 2.7, Syy = 8.75, R^2 = 1 - 2.7 / 8.75.
      final f = LinearFit.fit([0, 1, 2, 3], [1, 3, 2, 5])!;
      expect(f.n, 4);
      expect(f.slope, closeTo(1.1, 1e-12));
      expect(f.intercept, closeTo(1.1, 1e-12));
      expect(f.rSquared, closeTo(1 - 2.7 / 8.75, 1e-12));
      expect(f.residualStdError, closeTo(math.sqrt(1.35), 1e-12));
      expect(f.slopeStdError, closeTo(math.sqrt(1.35) / math.sqrt(5), 1e-12));
      expect(f.xMean, 1.5);
      expect(f.yMean, 2.75);
      expect(f.predict(4), closeTo(5.5, 1e-12));
    });

    test('perfect and flat lines', () {
      final p = LinearFit.fit([0, 1, 2], [2, 4, 6])!;
      expect(p.slope, closeTo(2, 1e-12));
      expect(p.rSquared, closeTo(1, 1e-12));
      expect(p.slopeStdError, closeTo(0, 1e-12));
      final flat = LinearFit.fit([0, 1, 2], [3, 3, 3])!;
      expect(flat.slope, 0);
      expect(flat.rSquared, 1);
    });

    test('degenerate inputs', () {
      expect(LinearFit.fit([1], [1]), isNull);
      expect(LinearFit.fit([2, 2, 2], [1, 2, 3]), isNull);
      expect(() => LinearFit.fit([1, 2], [1]), throwsArgumentError);
      final two = LinearFit.fit([0, 1], [0, 1])!;
      expect(two.slopeStdError, 0);
    });
  });

  group('TrendRules.classify', () {
    test('thresholds', () {
      LinearFit f(double slope, double r2) => LinearFit(
        n: 5,
        slope: slope,
        intercept: 0,
        rSquared: r2,
        slopeStdError: 0,
        residualStdError: 0,
        xMean: 0,
        yMean: 0,
      );
      expect(TrendRules.classify(null, 10), TrendDirection.insufficientData);
      expect(TrendRules.classify(f(0.5, 0.9), 10), TrendDirection.growing);
      expect(TrendRules.classify(f(-0.5, 0.9), 10), TrendDirection.declining);
      expect(TrendRules.classify(f(0.1, 0.9), 10), TrendDirection.stable);
      expect(TrendRules.classify(f(0.5, 0.1), 10), TrendDirection.stable);
      expect(TrendRules.classify(f(0.5, 0.9), 0), TrendDirection.stable);
    });
  });

  group('device forecasts', () {
    test('steady 10 h/week projects linearly to rated life', () {
      final r = analyze(projectorWeeks([10, 10, 10, 10]), utcConfig);
      final f = r.forecast.devices.single;
      expect(r.forecast.fullWeeksAvailable, 4);
      expect(f.observedHours, 40);
      expect(f.fullWeeksUsed, 4);
      expect(f.runRateHoursPerWeek, 10);
      expect(f.fit!.slope, closeTo(0, 1e-12));
      expect(f.direction, TrendDirection.stable);
      // 1 year = round(52.1775) = 52 weeks.
      final y1 = f.projections.firstWhere((p) => p.years == 1);
      expect(y1.expectedHours, closeTo(40 + 520, 1e-9));
      expect(y1.flatRateHours, closeTo(40 + 520, 1e-9));
      expect(y1.lowHours, closeTo(560, 1e-9));
      final y5 = f.projections.firstWhere((p) => p.years == 5);
      expect(y5.expectedHours, closeTo(40 + 10 * 261, 1e-9));
      // Rated 20000 h: 19960 h remaining at 10 h/week = 1996 weeks.
      expect(f.ratedLifeHours, 20000);
      expect(f.ratedLifeReached, isFalse);
      final expected = r.rangeEnd.add(const Duration(days: 7 * 1996));
      expect(f.projectedRatedLifeDate, expected);
      expect(f.projectedRatedLifeDateFlat, expected);
      expect(f.lifeUsedFraction, closeTo(40 / 20000, 1e-12));
      expect(f.explanation, contains('earlier use is unknown'));
    });

    test('growing usage: projection stays within the observed weeks', () {
      final r = analyze(projectorWeeks([5, 10, 15, 20]), utcConfig);
      final f = r.forecast.devices.single;
      expect(f.fit!.slope, closeTo(5, 1e-9));
      expect(f.fit!.intercept, closeTo(5, 1e-9));
      expect(f.fit!.rSquared, closeTo(1, 1e-9));
      expect(f.direction, TrendDirection.growing);
      expect(f.minWeeklyHours, 5);
      expect(f.maxWeeklyHours, 20);
      // Week k after the data: 20 + 5k h on the line, but never above the
      // busiest observed week (20 h).
      final y1 = f.projections.firstWhere((p) => p.years == 1);
      expect(y1.expectedHours, closeTo(50 + 20 * 52, 1e-6));
      expect(y1.flatRateHours, closeTo(50 + 12.5 * 52, 1e-6));
      // Perfect fit: no uncertainty band.
      expect(y1.lowHours, closeTo(y1.expectedHours, 1e-6));
      expect(y1.highHours, closeTo(y1.expectedHours, 1e-6));
      expect(f.projectedWeeklyHours(1), 20);
      expect(f.explanation, contains('levels off'));
    });

    test('projectedWeeklyHours: trend horizon, bounds and stable trends', () {
      // ys mean 10, xs 0..3 (xMean 1.5, last x 3), slope 1 h/week.
      const fit = LinearFit(
        n: 4,
        slope: 1,
        intercept: 8.5,
        rSquared: 0.9,
        slopeStdError: 0.5,
        residualStdError: 1,
        xMean: 1.5,
        yMean: 10,
      );
      double rate(int k, TrendDirection d,
              {ProjectionBand band = ProjectionBand.expected,
              double? max}) =>
          TrendRules.projectedWeeklyHours(
            fit: fit,
            direction: d,
            mean: 10,
            k: k,
            band: band,
            minObserved: 0,
            maxObserved: max,
          );
      const g = TrendDirection.growing;
      expect(rate(1, g), closeTo(12.5, 1e-12));
      expect(rate(52, g), closeTo(63.5, 1e-12));
      expect(rate(500, g), closeTo(63.5, 1e-12), reason: 'held after 52 weeks');
      expect(rate(1, g, max: 11), 11);
      expect(rate(30, g, max: 20), 20);
      expect(rate(1, g, band: ProjectionBand.high), closeTo(13.75, 1e-12));
      expect(rate(1, g, band: ProjectionBand.flat), 10);
      // A slope the rules call "no clear trend" is not extrapolated.
      expect(rate(1, TrendDirection.stable), 10);
      expect(rate(400, TrendDirection.stable), 10);
      expect(rate(1, TrendDirection.stable, band: ProjectionBand.low),
          closeTo(10 - 0.5 * 2.5, 1e-12));
    });

    test('a stable trend projects the average, not the fitted slope', () {
      // Weekly hours wobble with a slight downward slope (R^2 < 0.25).
      final r = analyze(projectorWeeks([30, 34, 26, 33, 27, 31, 25, 30]),
          utcConfig);
      final f = r.forecast.devices.single;
      expect(f.direction, TrendDirection.stable);
      expect(f.fit!.slope, lessThan(0));
      expect(f.projectedRatedLifeDate, f.projectedRatedLifeDateFlat);
      final y5 = f.projections.firstWhere((p) => p.years == 5);
      expect(y5.expectedHours, closeTo(y5.flatRateHours, 1e-6));
      expect(f.explanation, contains('At its average of'));
      expect(f.explanation, isNot(contains('At this trend')));
    });

    test('noisy usage has a band around the expectation', () {
      final r = analyze(projectorWeeks([8, 14, 9, 15, 10]), utcConfig);
      final y3 = r.forecast.devices.single.projections.firstWhere(
        (p) => p.years == 3,
      );
      expect(y3.lowHours, lessThan(y3.expectedHours));
      expect(y3.highHours, greaterThan(y3.expectedHours));
      final f = r.forecast.devices.single;
      expect(
        f.projectedRatedLifeDateEarliest!.isBefore(f.projectedRatedLifeDate!),
        isTrue,
      );
    });

    test('a device type override sets grouping and rated life', () {
      final r = analyze(
        projectorWeeks([10, 10, 10, 10]),
        utcConfig.copyWith(
          deviceTypeOverrides: const {'A_1/Projector_1': 'DISPLAY'},
        ),
      );
      expect(r.devices.devices.single.deviceType, 'DISPLAY');
      expect(r.devices.types.single.type, 'DISPLAY');
      expect(r.forecast.devices.single.ratedLifeHours, 50000);
    });

    test('a room that starts reporting mid-range skips its partial week', () {
      // B_1 first reports on the Thursday of week 1; weeks 2-4 are full.
      final events = <MetricEvent>[
        for (var w = 1; w < 5; w++)
          for (var d = w == 1 ? 3 : 0; d < 5; d++) ...[
            ev('B_1', monday.add(Duration(days: 7 * w + d, hours: 8)),
                'Projector_1', 'Started'),
            ev('B_1', monday.add(Duration(days: 7 * w + d, hours: 14)),
                'Projector_1', 'Stopped'),
          ],
      ];
      final r = analyze(
        ds(events, start: monday, end: monday.add(const Duration(days: 35))),
        utcConfig,
      );
      final f = r.forecast.devices.single;
      expect(f.fullWeeksUsed, 3);
      expect(f.runRateHoursPerWeek, 30);
      expect(f.direction, TrendDirection.stable);
    });

    test('fewer than three complete weeks: no fit', () {
      final r = analyze(projectorWeeks([10, 10]), utcConfig);
      final f = r.forecast.devices.single;
      expect(f.fit, isNull);
      expect(f.direction, TrendDirection.insufficientData);
      expect(f.projections, isEmpty);
      expect(f.projectedRatedLifeDate, isNull);
      expect(r.forecast.hasEnoughData, isFalse);
      expect(f.explanation, contains('at least 3'));
    });

    test('partial weeks are excluded from the fit', () {
      // Shift the range start to Wednesday: week 0 is partial.
      final base = projectorWeeks([10, 10, 10, 10]);
      final shifted = Dataset(
        events: base.events,
        heartbeats: const [],
        rangeStart: monday.add(const Duration(days: 2)),
        rangeEnd: base.rangeEnd,
        origin: DatasetOrigin.demo,
        description: 'x',
      );
      final r = analyze(shifted, utcConfig);
      final f = r.forecast.devices.single;
      // Event on the first Monday widens the range back to that Monday
      // 08:00, so week 0 is still partial.
      expect(f.weekly.first.isComplete, isFalse);
      expect(f.fullWeeksUsed, 3);
    });

    test('rated life reached and not configured', () {
      final cfg = utcConfig.copyWith(ratedLifeHours: {'PROJECTOR': 30});
      final f = analyze(
        projectorWeeks([10, 10, 10, 10]),
        cfg,
      ).forecast.devices.single;
      expect(f.ratedLifeReached, isTrue);
      expect(f.projectedRatedLifeDate, isNull);
      expect(f.explanation, contains('already passed'));
      final none = analyze(
        projectorWeeks([10, 10, 10, 10]),
        utcConfig.copyWith(ratedLifeHours: const {}),
      ).forecast.devices.single;
      expect(none.ratedLifeHours, isNull);
      expect(none.projectedRatedLifeDate, isNull);
      expect(none.lifeUsedFraction, isNull);
    });

    test('declining usage is held at the quietest observed week', () {
      final r = analyze(projectorWeeks([40, 30, 20, 10]), utcConfig);
      final f = r.forecast.devices.single;
      expect(f.direction, TrendDirection.declining);
      final y5 = f.projections.firstWhere((p) => p.years == 5);
      // Week k on the line: 10 - 10k, kept at the lowest week (10 h).
      expect(y5.expectedHours, closeTo(100 + 10 * 261, 1e-9));
      // 19900 h remaining at 10 h/week = 1990 weeks (about 38 years).
      expect(
        f.projectedRatedLifeDate,
        r.rangeEnd.add(const Duration(days: 7 * 1990)),
      );
    });

    test('declining to zero within the observed weeks never reaches life', () {
      final f = analyze(
        projectorWeeks([30, 20, 10, 0]),
        utcConfig,
      ).forecast.devices.single;
      expect(f.direction, TrendDirection.declining);
      expect(f.projectedRatedLifeDate, isNull);
      expect(f.explanation, contains('would not reach its rated life'));
    });
  });

  group('input trends', () {
    Dataset selections(List<int> perWeek) {
      final events = <MetricEvent>[];
      for (var w = 0; w < perWeek.length; w++) {
        for (var i = 0; i < perWeek[w]; i++) {
          events.add(
            ev(
              'A_1',
              monday.add(Duration(days: 7 * w, hours: 8, minutes: i)),
              i.isEven ? 'pc' : 'hdmi',
              'Started',
            ),
          );
        }
      }
      return ds(
        events,
        start: monday,
        end: monday.add(Duration(days: 7 * perWeek.length)),
      );
    }

    test('growing, stable and insufficient', () {
      final grow = analyze(
        selections([20, 40, 60, 80]),
        utcConfig,
      ).forecast.inputs.firstWhere((t) => t.key == 'pc');
      expect(grow.direction, TrendDirection.growing);
      expect(grow.fit!.slope, closeTo(10, 1e-9));
      expect(grow.meanWeeklySelections, 25);
      expect(grow.percentChangePerWeek, closeTo(40, 1e-9));
      final stable = analyze(
        selections([20, 20, 20, 20]),
        utcConfig,
      ).forecast.inputs.firstWhere((t) => t.key == 'pc');
      expect(stable.direction, TrendDirection.stable);
      final decline = analyze(
        selections([80, 60, 40, 20]),
        utcConfig,
      ).forecast.inputs.firstWhere((t) => t.key == 'pc');
      expect(decline.direction, TrendDirection.declining);
      final short = analyze(
        selections([20, 20]),
        utcConfig,
      ).forecast.inputs.firstWhere((t) => t.key == 'pc');
      expect(short.direction, TrendDirection.insufficientData);
      final few = analyze(
        selections([2, 2, 2, 2]),
        utcConfig,
      ).forecast.inputs.firstWhere((t) => t.key == 'pc');
      expect(few.direction, TrendDirection.insufficientData);
    });
  });
}
