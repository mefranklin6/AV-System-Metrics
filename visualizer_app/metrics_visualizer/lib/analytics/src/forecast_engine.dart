// Internal: device-life and input-trend forecasting. Not exported.

import '../classifier.dart';
import '../forecast.dart';
import '../series.dart';
import '../time_bucketing.dart';
import '../usage.dart';
import 'context.dart';

/// Complete-week points `(x, y)` from a weekly series, starting at the
/// first complete week whose index is >= [fromWeekIndex].
(List<double>, List<double>, int) _completeWeeks(
  List<SeriesPoint> weekly,
  int fromWeekIndex,
) {
  final xs = <double>[], ys = <double>[];
  int? base;
  var lastIndex = -1;
  for (var w = 0; w < weekly.length; w++) {
    if (w < fromWeekIndex || !weekly[w].isComplete) continue;
    base ??= w;
    xs.add((w - base).toDouble());
    ys.add(weekly[w].value);
    lastIndex = w;
  }
  return (xs, ys, lastIndex);
}

/// Cumulative hours after [weeks] future weeks using [rate] (week k = 1..).
double _cumulative(int weeks, double Function(int k) rate) {
  var sum = 0.0;
  for (var k = 1; k <= weeks; k++) {
    sum += rate(k);
  }
  return sum;
}

/// Date at which [remaining] more hours accumulate, or null beyond the
/// projection horizon.
DateTime? _dateToReach(
  DateTime origin,
  double remaining,
  double Function(int k) rate,
) {
  if (remaining <= 0) return null;
  final maxWeeks = (TrendRules.maxProjectionYears * TrendRules.weeksPerYear)
      .ceil();
  var cum = 0.0;
  for (var k = 1; k <= maxWeeks; k++) {
    final r = rate(k);
    if (r <= 0) {
      // A non-positive rate never recovers for a linear trend with a
      // negative slope; a zero flat rate never reaches the target.
      continue;
    }
    if (cum + r >= remaining) {
      final weeks = (k - 1) + (remaining - cum) / r;
      return origin.add(Duration(microseconds: (weeks * usPerWeek).round()));
    }
    cum += r;
  }
  return null;
}

String _h(double v) => v >= 100 ? v.round().toString() : v.toStringAsFixed(1);

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Builds device and input forecasts.
ForecastReport computeForecast(
  AnalysisContext ctx,
  DeviceUsage devices,
  InputUsage inputs,
) {
  final origin = ctx.rangeEnd;
  final fullWeeks = [
    for (var w = 0; w < ctx.weekCount; w++)
      if (ctx.weekCoverage(w) >= 0.999) w,
  ].length;

  // First week index per room: the week of the room's first sign of life
  // (event or heartbeat), so a room that started reporting mid-range does
  // not get leading zero weeks. When that is after the first week of the
  // data, the room's first week is only partly reported and is skipped.
  final roomFirstWeek = <String, int>{};
  for (final room in ctx.rooms) {
    DateTime? first;
    final ev = ctx.eventsByRoom[room];
    if (ev != null && ev.isNotEmpty) first = ev.first.time;
    for (final h in ctx.heartbeatsByRoom[room] ?? const []) {
      if (h.count > 0 && (first == null || h.hourStart.isBefore(first))) {
        first = h.hourStart;
      }
    }
    if (first == null) continue;
    final w = ctx.bucketer.weekOf(first) - ctx.firstWeek;
    roomFirstWeek[room] = w > 0 ? w + 1 : w;
  }

  final forecasts = <DeviceForecast>[];
  for (final d in devices.devices) {
    final (xs, ys, _) = _completeWeeks(d.weekly, roomFirstWeek[d.room] ?? 0);
    final enough = xs.length >= TrendRules.minFullWeeks;
    final fit = enough ? LinearFit.fit(xs, ys) : null;
    final mean = ys.isEmpty ? 0.0 : ys.reduce((a, b) => a + b) / ys.length;
    final direction = TrendRules.classify(fit, mean);
    final rated = ctx.config.ratedLifeHours[d.deviceType.toUpperCase()];
    final ratedLife = rated != null && rated > 0 ? rated : null;
    final reached = ratedLife != null && d.onHours >= ratedLife;
    final minWeek = ys.isEmpty ? null : ys.reduce((a, b) => a < b ? a : b);
    final maxWeek = ys.isEmpty ? null : ys.reduce((a, b) => a > b ? a : b);

    final projections = <HourProjection>[];
    DateTime? lifeDate, lifeEarliest, lifeLatest, lifeFlat;
    if (fit != null) {
      double rate(int k, ProjectionBand band) =>
          TrendRules.projectedWeeklyHours(
            fit: fit,
            direction: direction,
            mean: mean,
            k: k,
            band: band,
            minObserved: minWeek,
            maxObserved: maxWeek,
          );
      double expected(int k) => rate(k, ProjectionBand.expected);
      double low(int k) => rate(k, ProjectionBand.low);
      double high(int k) => rate(k, ProjectionBand.high);
      double flat(int k) => rate(k, ProjectionBand.flat);
      for (final years in TrendRules.horizonsYears) {
        final weeks = (years * TrendRules.weeksPerYear).round();
        projections.add(
          HourProjection(
            years: years,
            expectedHours: d.onHours + _cumulative(weeks, expected),
            lowHours: d.onHours + _cumulative(weeks, low),
            highHours: d.onHours + _cumulative(weeks, high),
            flatRateHours: d.onHours + _cumulative(weeks, flat),
          ),
        );
      }
      if (ratedLife != null && !reached) {
        final remaining = ratedLife - d.onHours;
        lifeDate = _dateToReach(origin, remaining, expected);
        lifeEarliest = _dateToReach(origin, remaining, high);
        lifeLatest = _dateToReach(origin, remaining, low);
        lifeFlat = _dateToReach(origin, remaining, flat);
      }
    }

    final buffer = StringBuffer()
      ..write(
        '${d.deviceId} in ${d.room} was on for ${_h(d.onHours)} hours '
        'in this data',
      );
    if (fit == null) {
      buffer.write(
        '. There are only ${xs.length} complete weeks of data for '
        'this device; at least ${TrendRules.minFullWeeks} are needed before '
        'a trend or projection is shown.',
      );
    } else {
      buffer.write(
        ', an average of ${_h(mean)} hours per week over '
        '${xs.length} complete weeks. ',
      );
      final trending =
          direction == TrendDirection.growing ||
          direction == TrendDirection.declining;
      buffer.write(switch (direction) {
        TrendDirection.growing =>
          'Weekly use is rising by about ${_h(fit.slope)} hours per week. ',
        TrendDirection.declining =>
          'Weekly use is falling by about '
              '${_h(-fit.slope)} hours per week. ',
        _ => 'Weekly use shows no clear trend. ',
      });
      final basis = trending
          ? 'If this trend continues for up to a year and then levels off, '
                'it would'
          : 'At its average of ${_h(mean)} hours per week it would';
      if (ratedLife != null) {
        if (reached) {
          buffer.write(
            'It has already passed its rated life of '
            '${_h(ratedLife)} hours based on observed use alone. ',
          );
        } else if (lifeDate != null) {
          buffer.write(
            '$basis reach its rated life of '
            '${_h(ratedLife)} hours around ${_date(lifeDate)}'
            '${lifeEarliest != null && lifeLatest != null && lifeEarliest != lifeLatest ? ' (likely range ${_date(lifeEarliest)} to ${_date(lifeLatest)})' : ''}. ',
          );
        } else {
          buffer.write(
            '$basis not reach its rated life of '
            '${_h(ratedLife)} hours within '
            '${TrendRules.maxProjectionYears} years. ',
          );
        }
        buffer.write(
          'Only hours recorded since metrics collection began are '
          'counted; earlier use is unknown, so the real date may be sooner.',
        );
      } else {
        buffer.write(
          'No rated life is configured for '
          '${d.deviceType.toLowerCase()} devices.',
        );
      }
    }

    forecasts.add(
      DeviceForecast(
        room: d.room,
        building: d.building,
        deviceId: d.deviceId,
        deviceType: d.deviceType,
        observedHours: d.onHours,
        weekly: d.weekly,
        fullWeeksUsed: xs.length,
        fit: fit,
        runRateHoursPerWeek: mean,
        direction: direction,
        projections: List.unmodifiable(projections),
        ratedLifeHours: ratedLife,
        ratedLifeReached: reached,
        projectedRatedLifeDate: lifeDate,
        projectedRatedLifeDateEarliest: lifeEarliest,
        projectedRatedLifeDateLatest: lifeLatest,
        projectedRatedLifeDateFlat: lifeFlat,
        explanation: buffer.toString(),
        minWeeklyHours: fit == null ? null : minWeek,
        maxWeeklyHours: fit == null ? null : maxWeek,
      ),
    );
  }
  forecasts.sort((a, b) {
    final da = a.ratedLifeReached ? DateTime.utc(0) : a.projectedRatedLifeDate;
    final db = b.ratedLifeReached ? DateTime.utc(0) : b.projectedRatedLifeDate;
    if (da != null && db != null) {
      final c = da.compareTo(db);
      if (c != 0) return c;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    return a.key.compareTo(b.key);
  });

  // ---- input trends (campus-wide selections per week)
  final weeklyByInput = <String, List<double>>{};
  final labels = <String, String>{};
  for (final room in ctx.rooms) {
    final sessions = ctx.sessions[room];
    for (final ce in ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[]) {
      final m = ce.meaning;
      if (!m.isSourceSelection) continue;
      labels[m.inputKey!] = m.inputLabel!;
      if (sessions?.isAutomaticSelection(ce.event) ?? false) continue;
      final w = ctx.bucketer.weekOf(ce.time) - ctx.firstWeek;
      final list = weeklyByInput.putIfAbsent(
        m.inputKey!,
        () => List.filled(ctx.weekCount, 0.0),
      );
      if (w >= 0 && w < list.length) list[w]++;
    }
  }
  final trends = <InputTrend>[];
  for (final key in (weeklyByInput.keys.toList()..sort())) {
    final values = weeklyByInput[key]!;
    final weekly = List<SeriesPoint>.unmodifiable([
      for (var w = 0; w < values.length; w++)
        SeriesPoint(
          TimeBucketer.weekStartDate(ctx.firstWeek + w),
          values[w],
          coverage: ctx.weekCoverage(w),
        ),
    ]);
    final (xs, ys, _) = _completeWeeks(weekly, 0);
    final total = ys.fold<double>(0, (a, b) => a + b);
    final mean = ys.isEmpty ? 0.0 : total / ys.length;
    final enough =
        xs.length >= TrendRules.minFullWeeks &&
        total >= TrendRules.minSelections;
    final fit = enough ? LinearFit.fit(xs, ys) : null;
    final direction = TrendRules.classify(fit, mean);
    final pct = fit == null || mean <= 0 ? null : fit.slope / mean * 100;
    final label = labels[key] ?? MetricClassifier.inputLabelFor(key);
    final explanation = switch (direction) {
      TrendDirection.insufficientData =>
        '$label: not enough data for a trend '
            '(needs ${TrendRules.minFullWeeks} complete weeks and '
            '${TrendRules.minSelections} selections).',
      TrendDirection.growing =>
        '$label is selected about ${_h(mean)} times '
            'per week and rising by about ${pct!.toStringAsFixed(1)}% of that '
            'per week.',
      TrendDirection.declining =>
        '$label is selected about ${_h(mean)} times '
            'per week and falling by about ${(-pct!).toStringAsFixed(1)}% of '
            'that per week.',
      TrendDirection.stable =>
        '$label is selected about ${_h(mean)} times '
            'per week with no clear upward or downward trend.',
    };
    trends.add(
      InputTrend(
        key: key,
        label: label,
        weekly: weekly,
        fit: fit,
        direction: direction,
        meanWeeklySelections: mean,
        percentChangePerWeek: pct,
        explanation: explanation,
      ),
    );
  }
  trends.sort((a, b) {
    final c = b.meanWeeklySelections.compareTo(a.meanWeeklySelections);
    return c != 0 ? c : a.key.compareTo(b.key);
  });

  return ForecastReport(
    devices: List.unmodifiable(forecasts),
    inputs: List.unmodifiable(trends),
    fullWeeksAvailable: fullWeeks,
    origin: origin,
    assumptions: const [
      'Only hours recorded by the metrics system are counted. Hours a device '
          'ran before metrics collection began are unknown, so real wear is '
          'at least what is shown and replacement may be needed sooner.',
      'Trends are straight lines fitted to complete weeks (least squares). '
          'Partial weeks at the start and end of the data, and the first '
          'partly reported week of a room that started reporting later, are '
          'left out.',
      'At least ${TrendRules.minFullWeeks} complete weeks are needed for a '
          'trend. Short periods, holidays and term breaks make trends less '
          'reliable; prefer at least a full term of data.',
      'A trend is called growing or declining only when it changes by at '
          'least 2% of the weekly average per week and explains at least 25% '
          'of the week-to-week variation; otherwise it is called stable.',
      'A stable device is projected at its average weekly hours. A growing '
          'or declining trend is followed for at most '
          '${TrendRules.trendHorizonWeeks} weeks and then held level. '
          'Projected weekly hours never go below the quietest or above the '
          'busiest complete week observed.',
      'The likely range uses the trend slope plus or minus one standard '
          'error, with the same limits.',
      'Rated life values come from Settings and should match the '
          'manufacturer\'s figures for your equipment.',
      'Device types are read from metric names (the text before the device '
          'number, such as Projector in "Projector 1"). A device whose name '
          'does not say what it is, such as a flat panel logged as a '
          'projector, is forecast with the rated life of the logged type '
          'unless a device type override is set in Settings.',
    ],
  );
}
