import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_charts.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_common.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_insights.dart';
import 'package:metrics_visualizer/ui/screens/system_usage_screen.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_a_helpers.dart';

InputShare share(String key, {int selections = 0, double hours = 0}) => InputShare(
  key: key,
  label: key.toUpperCase(),
  selections: selections,
  hours: hours,
  selectionShare: 0,
  timeShare: 0,
  roomCount: 1,
);

ChartPalette palette() => ChartPalette.resolve(
  kind: ChartPaletteKind.standard,
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  highContrast: false,
  patterns: true,
);

void main() {
  test('niceCeiling picks 1, 2, 2.5, 5 steps', () {
    expect(niceCeiling(0), 1);
    expect(niceCeiling(0.62), 1);
    expect(niceCeiling(0.18), 0.2);
    expect(niceCeiling(7), 10);
    expect(niceCeiling(21), 25);
    expect(niceCeiling(240), 250);
    expect(niceCeiling(1000), 1000);
    expect(niceCeiling(double.nan), 1);
  });

  test('series dates are formatted without a time-zone shift', () {
    // UTC midnight stands for the calendar date itself.
    expect(Fmt.calendarDateShort(DateTime.utc(2026, 11, 3)), 'Nov 3');
    expect(Fmt.calendarDate(DateTime.utc(2026, 1, 1)), 'Jan 1, 2026');
    expect(weekLabel(DateTime.utc(2026, 11, 2)), 'Week of Nov 2');
  });

  test('lastPeriodChange compares the last two complete periods only', () {
    final d = DateTime.utc(2026, 1, 5);
    expect(lastPeriodChange([SeriesPoint(d, 10)]), isNull);
    expect(
      lastPeriodChange([SeriesPoint(d, 10), SeriesPoint(d, 15), SeriesPoint(d, 1, coverage: 0.2)]),
      closeTo(0.5, 1e-9),
    );
    expect(lastPeriodChange([SeriesPoint(d, 0), SeriesPoint(d, 5)]), isNull);
  });

  test('inputs keep one colour everywhere; the tail is grouped as Other', () {
    final campus = [for (var i = 0; i < 10; i++) share('in$i', selections: 100 - i, hours: 50.0 - i)];
    final p = palette();
    final styles = InputStyles(p, campus);
    expect(styles.color('in0'), p.colorAt(0));
    expect(styles.color('in3'), p.colorAt(3));
    expect(styles.color('in9'), styles.otherColor);
    expect(styles.color('unknown'), styles.otherColor);

    final slices = inputSlices(sortInputs(campus, InputMeasure.selections), InputMeasure.selections, styles);
    expect(slices, hasLength(maxNamedSeries + 1));
    expect(slices.last.label, 'Other');
    expect(slices.last.value, 93 + 92 + 91);
    // A room-level ranking keeps campus colours even if its order differs.
    final room = sortInputs([share('in5', selections: 9), share('in0', selections: 1)], InputMeasure.selections);
    expect(room.first.key, 'in5');
    expect(inputSlices(room, InputMeasure.selections, styles).first.color, p.colorAt(5));
  });

  test('sortInputs orders by the chosen measure with a label tie-break', () {
    final list = [share('b', selections: 5, hours: 1), share('a', selections: 5, hours: 9), share('c', selections: 9)];
    expect([for (final s in sortInputs(list, InputMeasure.selections)) s.key], ['c', 'a', 'b']);
    expect([for (final s in sortInputs(list, InputMeasure.time)) s.key], ['a', 'b', 'c']);
  });

  test('heat colours run from the background to the first series colour', () {
    final p = palette();
    expect(heatColor(p, 0), p.background);
    expect(heatColor(p, 1), p.colorAt(0));
    final mid = heatColor(p, 0.5);
    expect(mid, isNot(p.background));
    expect(mid, isNot(p.colorAt(0)));
  });

  test('business hours are described in words', () {
    expect(businessHoursLabel(const BusinessHours()), matches(RegExp(r'^Mon-Fri 7\sAM to 10\sPM$')));
    expect(
      businessHoursLabel(const BusinessHours(weekdays: [1, 3], startHour: 8, endHour: 24)),
      matches(RegExp(r'^Mon, Wed 8\sAM to 12\sAM$')),
    );
  });

  group('buildInsights', () {
    final analysis = analyze(demoDataset(), const AnalysisConfig(useLocalTime: false));

    test('leads with the clearest findings, each linked to its page', () {
      final insights = buildInsights(analysis);
      expect(insights, isNotEmpty);
      expect(insights.length, lessThanOrEqualTo(10));
      expect(insights.first.kind, InsightKind.attention);
      // The least used source is named first with its room count and share.
      final rare = insights.firstWhere((i) => i.text.contains('least-used sources'));
      expect(rare.text, startsWith('Blu-ray was selected in 1 of 24 rooms ('));
      expect(rare.destination, AppDestination.inputs);
      expect(insights.any((i) => i.kind == InsightKind.energy && i.text.contains('inactivity power-off')), isTrue);
      expect(insights.any((i) => i.kind == InsightKind.pattern), isTrue);
      for (final i in insights) {
        expect(i.destination, isNotNull, reason: i.text);
        expect(i.text, isNot(contains('null')));
        expect(i.text, isNot(contains('NaN')));
      }
    });

    test('uses the configured left-on threshold in its wording', () {
      final insights = buildInsights(analysis, leftOnHours: 9);
      expect(insights.any((i) => i.text.contains('more than 9 hours')), isTrue);
    });

    test('respects the maximum and handles empty results', () {
      expect(buildInsights(analysis, max: 2), hasLength(2));
      final empty = analyze(heartbeatOnlyDataset(), const AnalysisConfig()).copyWithNoRooms();
      expect(buildInsights(empty), isEmpty);
    });

    test('a quiet dataset produces no misleading claims', () {
      final quiet = analyze(heartbeatOnlyDataset(), const AnalysisConfig(useLocalTime: false));
      final insights = buildInsights(quiet);
      expect(insights.where((i) => i.text.contains('least-used sources')), isEmpty);
      expect(insights.where((i) => i.kind == InsightKind.energy), isEmpty);
    });
  });
}

extension on AnalysisResult {
  /// The same result with no rooms (what an empty filter produces).
  AnalysisResult copyWithNoRooms() => AnalysisResult(
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    useLocalTime: useLocalTime,
    timeZoneLabel: timeZoneLabel,
    rooms: const [],
    buildings: const [],
    roomBuildings: const {},
    overview: overview,
    inputs: inputs,
    devices: devices,
    system: system,
    connectivity: connectivity,
    ui: ui,
    audio: audio,
    issues: issues,
    forecast: forecast,
    roomSummaries: const [],
    sessions: sessions,
    dataQuality: dataQuality,
  );
}
