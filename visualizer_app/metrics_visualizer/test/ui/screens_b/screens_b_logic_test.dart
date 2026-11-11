import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_charts.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_forecast_logic.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_issue_logic.dart';
import 'package:metrics_visualizer/ui/widgets/formatters.dart';

import 'screens_b_fixtures.dart';

Issue issue({
  required String id,
  IssueType type = IssueType.helpEvents,
  IssueSeverity severity = IssueSeverity.info,
  IssueArea cause = IssueArea.help,
  String room = 'BSS_245',
  String building = 'BSS',
  String? subject,
  required DateTime start,
  String title = 'Help requested',
}) =>
    Issue(
      id: id,
      type: type,
      severity: severity,
      area: cause,
      room: room,
      building: building,
      start: start,
      end: start.add(const Duration(minutes: 5)),
      count: 3,
      title: title,
      explanation: 'Explanation for $id.',
      suggestedAction: 'Do something.',
      evidence: const [],
      subject: subject,
    );

void main() {
  final end = DateTime.utc(2026, 11, 10);
  final issues = [
    issue(id: 'a', start: end.subtract(const Duration(days: 20))),
    issue(
        id: 'b',
        type: IssueType.repeatedPresses,
        severity: IssueSeverity.critical,
        cause: IssueArea.controls,
        room: 'ARTS_107',
        building: 'ARTS',
        subject: 'Btn_Volume_Up',
        title: 'Repeated button presses',
        start: end.subtract(const Duration(hours: 3))),
    issue(
        id: 'c',
        type: IssueType.heartbeatGap,
        severity: IssueSeverity.warning,
        cause: IssueArea.reporting,
        room: 'HOLT_155',
        building: 'HOLT',
        title: 'Room offline',
        start: end.subtract(const Duration(days: 3))),
    issue(id: 'd', room: 'ARTS_110', building: 'ARTS', start: end.subtract(const Duration(days: 40))),
  ];

  group('IssueFilter', () {
    List<String> ids(IssueFilter f, {Set<String> b = const {}, Set<String> r = const {}}) =>
        [for (final i in f.apply(issues, rangeEnd: end, knownBuildings: b, knownRooms: r)) i.id];

    test('default shows everything, newest first', () {
      const f = IssueFilter();
      expect(f.isDefault, isTrue);
      expect(ids(f), ['b', 'c', 'a', 'd']);
    });

    test('filters by type, severity and cause (empty set = all)', () {
      expect(ids(const IssueFilter(types: {IssueType.helpEvents})), ['a', 'd']);
      expect(ids(const IssueFilter(severities: {IssueSeverity.critical, IssueSeverity.warning})), ['b', 'c']);
      expect(ids(const IssueFilter(areas: {IssueArea.reporting})), ['c']);
      expect(
          ids(const IssueFilter(types: {IssueType.helpEvents}, severities: {IssueSeverity.critical})), isEmpty);
    });

    test('filters by building, room and period', () {
      expect(ids(const IssueFilter(building: 'ARTS')), ['b', 'd']);
      expect(ids(const IssueFilter(building: 'ARTS', room: 'ARTS_110')), ['d']);
      expect(ids(const IssueFilter(period: IssuePeriod.lastDay)), ['b']);
      expect(ids(const IssueFilter(period: IssuePeriod.lastWeek)), ['b', 'c']);
      expect(ids(const IssueFilter(period: IssuePeriod.lastMonth)), ['b', 'c', 'a']);
    });

    test('ignores building and room values that no longer exist', () {
      expect(ids(const IssueFilter(building: 'GONE'), b: {'ARTS', 'BSS', 'HOLT'}), hasLength(4));
      expect(ids(const IssueFilter(room: 'GONE_1'), r: {'ARTS_107'}), hasLength(4));
    });

    test('search is case-insensitive over title, room, subject and explanation', () {
      expect(ids(const IssueFilter(query: 'volume_up')), ['b']);
      expect(ids(const IssueFilter(query: 'holt')), ['c']);
      expect(ids(const IssueFilter(query: '  EXPLANATION FOR D ')), ['d']);
    });

    test('sort orders', () {
      expect(ids(const IssueFilter(sort: IssueSort.oldest)), ['d', 'a', 'c', 'b']);
      expect(ids(const IssueFilter(sort: IssueSort.severity)), ['b', 'c', 'a', 'd']);
      expect(ids(const IssueFilter(sort: IssueSort.room)), ['b', 'd', 'a', 'c']);
    });

    test('copyWith, toggle, cleared and equality', () {
      final f = const IssueFilter().copyWith(
        types: IssueFilter.toggle(const <IssueType>{}, IssueType.longDeviceSession),
        building: () => 'ARTS',
        sort: IssueSort.room,
      );
      expect(f.types, {IssueType.longDeviceSession});
      expect(IssueFilter.toggle(f.types, IssueType.longDeviceSession), isEmpty);
      expect(f.copyWith(building: () => null).building, isNull);
      expect(f.isDefault, isFalse);
      expect(f.cleared(), const IssueFilter(sort: IssueSort.room));
      expect(f, const IssueFilter(types: {IssueType.longDeviceSession}, building: 'ARTS', sort: IssueSort.room));
      expect(f.hashCode,
          const IssueFilter(types: {IssueType.longDeviceSession}, building: 'ARTS', sort: IssueSort.room).hashCode);
    });
  });

  test('issuesToCsv quotes text and neutralises spreadsheet formulas', () {
    final csv = issuesToCsv([
      issue(id: 'x', room: '=HYPERLINK("http://evil")', subject: '+cmd', start: end),
      issue(id: 'y', start: end, title: 'Has, comma'),
    ]);
    final lines = csv.trim().split('\n');
    expect(lines.first, startsWith('id,severity,type,area,building,room,subject,start_utc'));
    expect(lines, hasLength(3));
    expect(csv, contains("'=HYPERLINK"));
    expect(csv, contains("'+cmd"));
    expect(csv, isNot(contains(',=HYPERLINK')));
    expect(csv, contains('"Has, comma"'));
    expect(csv, contains('2026-11-10T00:00:00.000Z'));
  });

  test('countIssuesBy keeps enum order and drops zero counts', () {
    final c = countIssuesBy(issues, (i) => i.type, IssueType.values);
    expect(c.keys.toList(), [IssueType.repeatedPresses, IssueType.heartbeatGap, IssueType.helpEvents]);
    expect(c[IssueType.helpEvents], 2);
  });

  test('niceTicks covers the maximum with round steps', () {
    expect(niceTicks(0), [0, 1]);
    expect(niceTicks(7), [0, 2, 4, 6, 8]);
    expect(niceTicks(100).last, greaterThanOrEqualTo(100));
    final t = niceTicks(12345);
    expect(t.first, 0);
    expect(t.last, greaterThanOrEqualTo(12345));
    expect(t.length, lessThanOrEqualTo(7));
  });

  test('calendar dates are formatted without time zone conversion', () {
    final d = DateTime.utc(2026, 3, 1);
    expect(Fmt.calendarDateIso(d), '2026-03-01');
    expect(Fmt.calendarDate(d), 'Mar 1, 2026');
    expect(Fmt.calendarDateShort(d), 'Mar 1');
  });

  group('forecast logic', () {
    late ForecastReport report;
    setUpAll(() {
      report = analyze(demoDataset(10), const AnalysisConfig()).forecast;
    });

    test('projection curve matches the engine projections at every horizon', () {
      final fitted = report.devices.where((d) => d.fit != null).toList();
      expect(fitted, isNotEmpty);
      for (final d in fitted) {
        final curve = projectionCurve(d, report.origin, horizonWeeks: weeksForYears(5));
        expect(curve.observed.last.dx, closeTo(0, 1e-9));
        expect(curve.observed.last.dy, closeTo(d.observedHours, 1e-6));
        // Cumulative observed hours never decrease.
        for (var i = 1; i < curve.observed.length; i++) {
          expect(curve.observed[i].dy, greaterThanOrEqualTo(curve.observed[i - 1].dy - 1e-9));
        }
        for (final p in d.projections) {
          final w = weeksForYears(p.years);
          expect(curve.expected[w].dy, closeTo(p.expectedHours, 1e-6), reason: '${d.key} ${p.years}y expected');
          expect(curve.low[w].dy, closeTo(p.lowHours, 1e-6), reason: '${d.key} ${p.years}y low');
          expect(curve.high[w].dy, closeTo(p.highHours, 1e-6), reason: '${d.key} ${p.years}y high');
          expect(curve.flat[w].dy, closeTo(p.flatRateHours, 1e-6), reason: '${d.key} ${p.years}y flat');
        }
        // Every weekly step is the engine's own projected week.
        for (final k in [1, 26, 52, 53, 200]) {
          expect(curve.expected[k].dy - curve.expected[k - 1].dy, closeTo(d.projectedWeeklyHours(k), 1e-6));
          expect(curve.low[k].dy - curve.low[k - 1].dy, closeTo(d.projectedWeeklyHours(k, ProjectionBand.low), 1e-6));
          expect(curve.high[k].dy - curve.high[k - 1].dy,
              closeTo(d.projectedWeeklyHours(k, ProjectionBand.high), 1e-6));
        }
      }
    });

    test('devices without a fit have no projection and "not enough data" confidence', () {
      final short = analyze(demoDataset(2), const AnalysisConfig()).forecast;
      final d = short.devices.first;
      expect(d.fit, isNull);
      expect(projectionCurve(d, short.origin, horizonWeeks: 52).hasProjection, isFalse);
      final c = assessConfidence(d);
      expect(c.level, ForecastConfidence.notEnoughData);
      expect(c.reason, contains('at least ${TrendRules.minFullWeeks}'));
    });

    test('confidence is limited by the weeks of history', () {
      for (final d in report.devices.where((d) => d.fit != null)) {
        final c = assessConfidence(d);
        // Nine complete weeks are below the threshold for "high".
        expect(c.level, isNot(ForecastConfidence.high));
        expect(c.level, isNot(ForecastConfidence.notEnoughData));
        expect(c.reason, contains('${d.fullWeeksUsed} complete weeks'));
      }
      expect(ConfidenceRules.description, contains('±15%'));
    });
  });
}
