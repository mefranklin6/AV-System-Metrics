// Determinism, isolate safety and performance of analyze().

import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

/// Deterministic synthetic campus with roughly [target] events.
Dataset synthetic(int target, {int rooms = 100, int seed = 42}) {
  final rnd = math.Random(seed);
  const inputs = ['pc', 'hdmi', 'doc_cam', 'wireless', 'usb', 'dvd'];
  const buttons = [
    'Btn_Volume_Up',
    'Btn_Volume_Down',
    'Btn_Video_Mute',
    'Btn_Back',
    'Btn_Cam_Nav',
    'Btn_Start_Page',
  ];
  final events = <MetricEvent>[];
  final hb = <HeartbeatBucket>[];
  final roomNames = [for (var i = 0; i < rooms; i++) 'B${i % 8}_${100 + i}'];
  var seq = 0;
  MetricEvent e(String room, DateTime t, String m, String a) => MetricEvent(
    clientName: room,
    timestamp: t,
    metric: m,
    action: a,
    eventId: 'id${(seq++).toString().padLeft(10, '0')}',
  );
  var day = 0;
  while (events.length < target) {
    final date = monday.add(Duration(days: day));
    for (final room in roomNames) {
      for (var h = 0; h < 24; h += 1) {
        hb.add(
          HeartbeatBucket(
            clientName: room,
            hourStart: date.add(Duration(hours: h)),
            count: 12,
          ),
        );
      }
      if (date.weekday > 5 && rnd.nextDouble() < 0.8) continue;
      final classes = 1 + rnd.nextInt(4);
      var t = date.add(Duration(hours: 7 + rnd.nextInt(3)));
      for (var c = 0; c < classes; c++) {
        events.add(e(room, t, 'System - User', 'Started'));
        events.add(
          e(room, t.add(const Duration(seconds: 5)), 'Projector_1', 'Started'),
        );
        final len = Duration(minutes: 50 + rnd.nextInt(100));
        var u = t.add(const Duration(seconds: 10));
        while (u.isBefore(t.add(len))) {
          final r = rnd.nextDouble();
          if (r < 0.3) {
            events.add(
              e(room, u, inputs[rnd.nextInt(inputs.length)], 'Started'),
            );
          } else if (r < 0.9) {
            final b = buttons[rnd.nextInt(buttons.length)];
            events.add(e(room, u, '$b Pressed', 'Trace'));
            events.add(e(room, u, '$b Tapped', 'Trace'));
          } else {
            events.add(
              e(
                room,
                u,
                'Program Audio Volume',
                'Level ${rnd.nextInt(101)} (Device -20.0)',
              ),
            );
          }
          u = u.add(Duration(seconds: 20 + rnd.nextInt(400)));
        }
        final end = t.add(len);
        events.add(
          e(
            room,
            end,
            rnd.nextBool() ? 'System - User' : 'System - Inactivity',
            'Stopped',
          ),
        );
        events.add(
          e(
            room,
            end.add(const Duration(seconds: 30)),
            'Projector_1',
            'Stopped',
          ),
        );
        t = end.add(Duration(minutes: 10 + rnd.nextInt(60)));
      }
    }
    day++;
  }
  return Dataset(
    events: events,
    heartbeats: hb,
    rangeStart: monday,
    rangeEnd: monday.add(Duration(days: day)),
    origin: DatasetOrigin.demo,
    description: 'synthetic',
    heartbeatRetentionDays: 30,
  );
}

/// A compact fingerprint of everything that matters in a result.
String fingerprint(AnalysisResult r) {
  final b = StringBuffer()
    ..writeln(r.rooms.join(','))
    ..writeln(r.overview.eventCount)
    ..writeln(r.system.totalHours.toStringAsFixed(9))
    ..writeln(r.devices.totalOnHours.toStringAsFixed(9))
    ..writeln(
      [
        for (final s in r.inputs.campus)
          '${s.key}:${s.selections}:${s.hours.toStringAsFixed(9)}',
      ].join(';'),
    )
    ..writeln([for (final i in r.issues) i.id].join(';'))
    ..writeln(
      [
        for (final row in r.system.occupancy.values)
          row.map((v) => v.toStringAsFixed(9)).join(','),
      ].join('|'),
    )
    ..writeln(
      [
        for (final f in r.forecast.devices)
          '${f.key}:${f.projectedRatedLifeDate}',
      ].join(';'),
    )
    ..writeln(
      [for (final u in r.ui.buttons) '${u.control}:${u.presses}'].join(';'),
    )
    ..writeln(
      [for (final c in r.connectivity.rooms) '${c.room}:${c.onlineFraction}']
          .join(';'),
    );
  return b.toString();
}

/// Upper bound for analysing 1M events. A typical run takes 2-4 s, but the
/// full suite runs test files in parallel on shared CI machines, where a
/// 6 s limit flaked (6.4 s). 20 s still fails loudly on a pathological
/// regression: anything quadratic in the event count would take hours.
const Duration scaleLimit = Duration(seconds: 20);

void main() {
  test('deterministic for the same input, regardless of input order', () {
    final data = synthetic(20000, rooms: 10);
    final shuffled = Dataset(
      events: List.of(data.events)..shuffle(math.Random(7)),
      heartbeats: List.of(data.heartbeats)..shuffle(math.Random(8)),
      rangeStart: data.rangeStart,
      rangeEnd: data.rangeEnd,
      origin: data.origin,
      description: data.description,
      heartbeatRetentionDays: data.heartbeatRetentionDays,
    );
    final a = fingerprint(analyze(data, utcConfig));
    final b = fingerprint(analyze(data, utcConfig));
    final c = fingerprint(analyze(shuffled, utcConfig));
    expect(a, b);
    expect(a, c);
  });

  test('runs inside an isolate and the result can be sent back', () async {
    final data = synthetic(5000, rooms: 5);
    final r = await Isolate.run(() => analyze(data, utcConfig));
    expect(fingerprint(r), fingerprint(analyze(data, utcConfig)));
  });

  test('1M events analyse in seconds, not minutes', () {
    final data = synthetic(1000000);
    expect(data.events.length, greaterThanOrEqualTo(1000000));
    final sw = Stopwatch()..start();
    final r = analyze(data, utcConfig);
    sw.stop();
    // ignore: avoid_print
    print(
      'analyze(${data.events.length} events, '
      '${data.heartbeats.length} heartbeat buckets): ${sw.elapsedMilliseconds} ms',
    );
    expect(r.rooms, hasLength(100));
    expect(r.system.sessionCount, greaterThan(1000));
    expect(sw.elapsed, lessThan(scaleLimit));

    // Local-time bucketing uses cached zone offsets and must stay fast too.
    final local = Stopwatch()..start();
    analyze(data, const AnalysisConfig(useLocalTime: true));
    local.stop();
    // ignore: avoid_print
    print('analyze with local time: ${local.elapsedMilliseconds} ms');
    expect(local.elapsed, lessThan(scaleLimit));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
