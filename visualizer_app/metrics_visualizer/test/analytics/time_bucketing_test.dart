import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

void main() {
  group('TimeBucketer (UTC)', () {
    final b = TimeBucketer(useLocalTime: false);

    test('calendar helpers', () {
      expect(TimeBucketer.weekdayOfDay(0), DateTime.thursday); // 1970-01-01
      expect(b.weekdayOf(monday), DateTime.monday);
      expect(b.hourOf(monday.add(const Duration(hours: 13, minutes: 59))), 13);
      expect(TimeBucketer.dateOfDay(b.dayOf(monday)), monday);
      expect(TimeBucketer.weekStartDate(b.weekOf(monday)), monday);
      expect(
        TimeBucketer.weekStartDate(
          b.weekOf(monday.add(const Duration(days: 6, hours: 23))),
        ),
        monday,
      );
      expect(
        b.weekOf(monday.add(const Duration(days: 7))),
        b.weekOf(monday) + 1,
      );
      expect(b.zoneLabel(monday), 'UTC');
      // Before the epoch.
      expect(b.weekdayOf(DateTime.utc(1969, 12, 31)), DateTime.wednesday);
      expect(floorDiv(-1, 24), -1);
    });

    test('splitByHour and splitByDay partition the interval', () {
      final s = monday.add(const Duration(hours: 22, minutes: 30));
      final e = s.add(const Duration(hours: 3, minutes: 15));
      var total = 0;
      final hours = <int>[];
      b.splitByHour(s, e, (wall, us) {
        total += us;
        hours.add(TimeBucketer.hourOfWall(wall));
      });
      expect(total, e.difference(s).inMicroseconds);
      expect(hours, [22, 23, 0, 1]);
      final days = <int, int>{};
      b.splitByDay(s, e, (day, us) => days[day] = us);
      expect(days.values.toList(), [
        const Duration(minutes: 90).inMicroseconds,
        const Duration(minutes: 105).inMicroseconds,
      ]);
    });
  });

  group('local vs UTC bucketing', () {
    // 2026-07-15 (a Wednesday) 03:30 UTC: a different local hour, and in
    // most zones west of UTC a different local day, from UTC.
    final t = DateTime.utc(2026, 7, 15, 3, 30);
    final events = [
      ev('A_1', t, 'System - User', 'Started'),
      ev('A_1', t.add(const Duration(minutes: 45)), 'System - User', 'Stopped'),
    ];
    final data = ds(
      events,
      start: DateTime.utc(2026, 7, 13),
      end: DateTime.utc(2026, 7, 20),
    );

    test('UTC config buckets by UTC fields', () {
      final r = analyze(data, utcConfig);
      expect(r.system.powerOnByHour[3], 1);
      expect(r.system.powerOnByWeekday[DateTime.wednesday - 1], 1);
      expect(r.timeZoneLabel, 'UTC');
      expect(r.system.occupancy.valueAt(DateTime.wednesday, 3), greaterThan(0));
    });

    test('local config buckets by DateTime.toLocal() fields', () {
      final r = analyze(data, const AnalysisConfig(useLocalTime: true));
      final local = t.toLocal();
      expect(r.system.powerOnByHour[local.hour], 1);
      expect(r.system.powerOnByWeekday[local.weekday - 1], 1);
      expect(
        r.system.occupancy.valueAt(local.weekday, local.hour),
        greaterThan(0),
      );
      final off = t.add(const Duration(minutes: 45)).toLocal();
      expect(r.system.powerOffByHour[off.hour], 1);
      expect(r.useLocalTime, isTrue);
      final localDay = DateTime.utc(local.year, local.month, local.day);
      final daily = r.system.daily.firstWhere((p) => p.value > 0);
      expect(daily.date, localDay);
      expect(r.timeZoneLabel, startsWith('local time (UTC'));
    });

    test('local bucketer agrees with toLocal across a year of hours', () {
      final b = TimeBucketer(useLocalTime: true);
      final t2 = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < 24 * 366; i += 7) {
        final x = t2.add(Duration(hours: i, minutes: 17));
        final l = x.toLocal();
        expect(b.hourOf(x), l.hour, reason: '$x');
        expect(b.weekdayOf(x), l.weekday, reason: '$x');
        expect(
          TimeBucketer.dateOfDay(b.dayOf(x)),
          DateTime.utc(l.year, l.month, l.day),
        );
      }
    });
  });
}
