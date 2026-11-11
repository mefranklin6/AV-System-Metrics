import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

HeartbeatBucket hb(String room, int hour, [int count = 12]) => HeartbeatBucket(
  clientName: room,
  hourStart: monday.add(Duration(hours: hour)),
  count: count,
);

void main() {
  test('online fraction per room and per day within coverage', () {
    final r = analyze(
      ds(
        const [],
        start: monday,
        end: monday.add(const Duration(days: 2)),
        heartbeats: [
          for (var h = 0; h < 48; h++) hb('A_1', h),
          for (var h = 0; h < 48; h++)
            if (h < 12 || h >= 24) hb('B_1', h),
        ],
      ),
      utcConfig,
    );
    final c = r.connectivity;
    expect(c.hasHeartbeatCoverage, isTrue);
    expect(c.coverageStart, monday);
    expect(c.coverageEnd, monday.add(const Duration(days: 2)));
    final a = c.rooms.firstWhere((x) => x.room == 'A_1');
    final b = c.rooms.firstWhere((x) => x.room == 'B_1');
    expect(a.onlineFraction, 1);
    expect(b.onlineFraction, closeTo(36 / 48, 1e-12));
    expect(b.coveredHours, 48);
    expect(b.dailyOnline.map((p) => p.value), [0.5, 1.0]);
    expect(b.offlinePeriods.single.hours, 12);
    expect(b.offlinePeriods.single.ongoing, isFalse);
    expect(b.lastSeen, monday.add(const Duration(hours: 47)));
    expect(r.roomSummary('B_1')!.onlineFraction, closeTo(0.75, 1e-12));
  });

  test('retention limits coverage', () {
    final r = analyze(
      ds(
        [ev('A_1', monday, 'pc', 'Started')],
        start: monday,
        end: monday.add(const Duration(days: 10)),
        retentionDays: 2,
        heartbeats: [for (var h = 0; h < 240; h++) hb('A_1', h)],
      ),
      utcConfig,
    );
    expect(r.connectivity.coverageStart, monday.add(const Duration(days: 8)));
    expect(r.connectivity.retentionDays, 2);
    expect(r.connectivity.coverageNote, contains('2 days'));
  });

  test('a room without heartbeats is not judged online or offline', () {
    // B_1's program has heartbeats turned off: only daytime usage events.
    final r = analyze(
      ds(
        [
          ev('B_1', monday.add(const Duration(hours: 9)), 'pc', 'Started'),
          ev('B_1', monday.add(const Duration(hours: 33)), 'pc', 'Started'),
        ],
        start: monday,
        end: monday.add(const Duration(days: 2)),
        heartbeats: [for (var h = 0; h < 48; h++) hb('A_1', h)],
      ),
      utcConfig,
    );
    final b = r.connectivity.rooms.firstWhere((x) => x.room == 'B_1');
    expect(b.onlineFraction, isNull);
    expect(b.coveredHours, 0);
    expect(b.offlinePeriods, isEmpty);
    expect(b.dailyOnline, isEmpty);
    expect(r.issues.where((i) => i.type == IssueType.offlineRoom), isEmpty);
    expect(r.connectivity.coverageNote, contains('1 room sent no heartbeats'));
  });

  test('a room is judged from its first sign of life', () {
    // C_1 was commissioned at hour 20 and then reported every hour.
    final r = analyze(
      ds(
        const [],
        start: monday,
        end: monday.add(const Duration(days: 2)),
        heartbeats: [
          for (var h = 0; h < 48; h++) hb('A_1', h),
          for (var h = 20; h < 48; h++) hb('C_1', h),
        ],
      ),
      utcConfig,
    );
    final c = r.connectivity.rooms.firstWhere((x) => x.room == 'C_1');
    expect(c.coveredHours, 28);
    expect(c.onlineFraction, 1);
    expect(c.offlinePeriods, isEmpty);
    expect(c.dailyOnline.map((p) => p.value), [1.0, 1.0]);
  });

  test('a room that stops reporting is still flagged as offline', () {
    final r = analyze(
      ds(
        const [],
        start: monday,
        end: monday.add(const Duration(days: 2)),
        heartbeats: [
          for (var h = 0; h < 48; h++) hb('A_1', h),
          for (var h = 0; h < 30; h++) hb('C_1', h),
        ],
      ),
      utcConfig,
    );
    final c = r.connectivity.rooms.firstWhere((x) => x.room == 'C_1');
    expect(c.offlinePeriods.single.ongoing, isTrue);
    expect(c.offlinePeriods.single.hours, 18);
  });

  test('lastSeen is the exact time of a later event', () {
    final r = analyze(
      ds(
        [
          ev(
            'A_1',
            monday.add(const Duration(hours: 15, minutes: 59)),
            'pc',
            'Started',
          ),
        ],
        start: monday,
        end: monday.add(const Duration(days: 1)),
        heartbeats: [for (var h = 0; h < 16; h++) hb('A_1', h)],
      ),
      utcConfig,
    );
    final a = r.connectivity.rooms.single;
    expect(a.lastSeen, monday.add(const Duration(hours: 15, minutes: 59)));
    expect(a.lastEvent, a.lastSeen);
    expect(a.lastHeartbeatHour, monday.add(const Duration(hours: 15)));
  });

  test('no heartbeats means no online figures', () {
    final r = analyze(ds([ev('A_1', monday, 'pc', 'Started')]), utcConfig);
    expect(r.connectivity.hasHeartbeatCoverage, isFalse);
    expect(r.connectivity.rooms.single.onlineFraction, isNull);
    expect(r.connectivity.rooms.single.offlinePeriods, isEmpty);
    expect(r.connectivity.coverageNote, contains('No heartbeat'));
  });

  test('connection events: timeline, per-day and per-target counts', () {
    final r = analyze(
      ds(
        [
          ev(
            'A_1',
            monday.add(const Duration(hours: 9)),
            'Projector_1',
            'Disconnected',
          ),
          ev(
            'A_1',
            monday.add(const Duration(hours: 10)),
            'Projector_1',
            'Connected',
          ),
          ev(
            'A_1',
            monday.add(const Duration(days: 1, hours: 9)),
            'Switcher',
            'Disconnected',
          ),
        ],
        start: monday,
        end: monday.add(const Duration(days: 3)),
      ),
      utcConfig,
    );
    final c = r.connectivity;
    expect(c.events, hasLength(3));
    expect(c.events.first.connected, isFalse);
    expect(c.daily, hasLength(3));
    expect(
      [for (final d in c.daily) (d.connects, d.disconnects)],
      [(1, 1), (0, 1), (0, 0)],
    );
    final room = c.rooms.single;
    expect(room.connects, 1);
    expect(room.disconnects, 2);
    expect(room.daily, hasLength(2));
    expect(
      [for (final t in room.targets) (t.target, t.lastState)],
      [('Projector_1', true), ('Switcher', false)],
    );
    expect(room.flapBursts, 0);
  });

  test('flapping bursts are counted per target', () {
    final events = [
      for (var k = 0; k < 4; k++)
        ev(
          'A_1',
          monday.add(Duration(minutes: 9 * 60 + k)),
          'Projector_1',
          k.isEven ? 'Disconnected' : 'Connected',
        ),
      for (var k = 0; k < 4; k++)
        ev(
          'A_1',
          monday.add(Duration(minutes: 15 * 60 + k)),
          'Projector_1',
          k.isEven ? 'Disconnected' : 'Connected',
        ),
    ];
    final r = analyze(ds(events), utcConfig);
    expect(r.connectivity.rooms.single.targets.single.flapBursts, 2);
    expect(r.connectivity.rooms.single.flapBursts, 2);
    expect(
      r.issues.where((i) => i.type == IssueType.connectionFlapping).length,
      2,
    );
  });
}
