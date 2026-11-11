import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

const room = 'BSS_245';
final classifier = MetricClassifier();

RoomSessions build(
  List<MetricEvent> events, {
  DateTime? start,
  DateTime? end,
  Duration cap = const Duration(hours: 16),
}) {
  final sorted = List.of(events)..sort();
  return SessionBuilder.build(
    room: room,
    events: [
      for (final e in sorted) ClassifiedEvent(e, classifier.classifyEvent(e)),
    ],
    rangeStart: start ?? monday,
    rangeEnd: end ?? monday.add(const Duration(days: 7)),
    maxSessionLength: cap,
  );
}

DateTime at(int hour, [int minute = 0, int second = 0]) =>
    monday.add(Duration(hours: hour, minutes: minute, seconds: second));

void main() {
  group('system sessions', () {
    test('user on, user off', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(10, 30), 'System - User', 'Stopped'),
      ]);
      expect(s.system, hasLength(1));
      final x = s.system.single;
      expect(x.start, at(9));
      expect(x.end, at(10, 30));
      expect(x.hours, 1.5);
      expect(x.startSource, PowerSource.user);
      expect(x.offReason, OffReason.user);
      expect(x.unterminated, isFalse);
      expect(x.ongoing, isFalse);
      expect(s.powerOnEvents, hasLength(1));
    });

    test('Inactivity stop ends a User session', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(11), 'System - Inactivity', 'Stopped'),
      ]);
      expect(s.system.single.offReason, OffReason.inactivity);
    });

    test('reason groups, synonyms and verbatim other reasons', () {
      final s = build([
        ev(room, at(8), 'System Power - Remote', 'Started'),
        ev(room, at(9), 'System Power - Remote', 'Stopped'),
        ev(room, at(10), 'System - Restore', 'Started'),
        ev(room, at(11), 'System - Scheduled', 'Stopped'),
        ev(room, at(12), 'System - GVE', 'Started'),
        ev(room, at(13), 'System - GVE', 'Stopped'),
        ev(room, at(14), 'System Power', 'Started'),
        ev(room, at(15), 'System Power - Idle', 'Stopped'),
        ev(room, at(16), 'System Power - Schedule', 'Started'),
        ev(room, at(17), 'System Power', 'Stopped'),
      ]);
      expect(
        [for (final x in s.system) x.offReason],
        [
          OffReason.remote,
          OffReason.scheduled,
          OffReason.other,
          OffReason.inactivity,
          OffReason.unknown,
        ],
      );
      expect(
        [for (final x in s.system) x.startSource],
        [
          PowerSource.remote,
          PowerSource.restore,
          PowerSource.other,
          PowerSource.unknown,
          PowerSource.scheduled,
        ],
      );
      expect(s.system[2].startReason, 'GVE');
      expect(s.system[2].offReasonText, 'GVE');
      expect(s.system[3].offReasonText, 'Idle');
      expect(s.system[4].offReasonText, isNull);
    });

    test('missing stop is capped and flagged unterminated', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(40), 'pc', 'Started'), // next day, after the cap
      ], cap: const Duration(hours: 16));
      final x = s.system.single;
      expect(x.end, at(25));
      expect(x.offReason, OffReason.capped);
      expect(x.unterminated, isTrue);
    });

    test('duplicate Started is ignored', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9, 5), 'System - User', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
      ]);
      expect(s.system.single.start, at(9));
      expect(s.duplicateStarts, 1);
      expect(s.powerOnEvents, hasLength(1));
    });

    test('Initialize closes every open session', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(9), 'pc', 'Started'),
        ev(room, at(9), 'Microphone Muted', 'Started'),
        ev(room, at(10), 'Initialize', 'Started'),
        ev(room, at(10, 1), 'Initialize', 'Stopped'),
        ev(room, at(10, 2), 'Projector_1', 'Stopped'),
      ]);
      expect(s.reboots, 1);
      expect(s.system.single.offReason, OffReason.reinitialized);
      expect(s.system.single.end, at(10));
      expect(s.devices.single.endKind, SessionEnd.reinitialized);
      expect(s.devices.single.end, at(10));
      expect(s.inputs.single.endKind, SessionEnd.reinitialized);
      expect(s.mutes.single.endKind, SessionEnd.reinitialized);
      // The later Stopped has nothing to stop: it is the boot-time status
      // re-sync, not an orphan.
      expect(s.orphanStops, 0);
      expect(s.devices, hasLength(1));
    });

    test('a Started while on (such as a reset) is a marker only', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9, 11), 'System - User Reset', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
      ]);
      expect(s.system, hasLength(1));
      expect(s.system.single.hours, 1);
      expect(s.powerOnEvents, hasLength(1));
      expect(s.duplicateStarts, 1);
    });

    test('Program Start closes an open session (recommended names)', () {
      final s = build([
        ev(room, at(9), 'System Power - User', 'Started'),
        ev(room, at(9), 'Projector 1', 'Started'),
        ev(room, at(10), 'Program Start', 'Started'),
        ev(room, at(10, 1), 'System Power - Restore', 'Started'),
        ev(room, at(11), 'System Power - User', 'Stopped'),
      ]);
      expect(s.reboots, 1);
      expect([for (final x in s.system) x.offReason], [OffReason.reinitialized, OffReason.user]);
      expect(s.system[1].startSource, PowerSource.restore);
      expect(s.devices.single.endKind, SessionEnd.reinitialized);
    });

    test('startup trace opens and shutdown trace closes when needed', () {
      final s = build([
        ev(room, at(9), 'System Startup Sequence Complete', 'Trace'),
        ev(room, at(11), 'System Shutdown Sequence Complete', 'Trace'),
        ev(room, at(12), 'System - User', 'Started'),
        ev(room, at(12), 'System Startup Sequence Complete', 'Trace'),
        ev(room, at(13), 'System - User', 'Stopped'),
        ev(room, at(13), 'System Shutdown Sequence Complete', 'Trace'),
      ]);
      expect(s.system, hasLength(2));
      expect(s.system[0].startSource, PowerSource.unknown);
      expect(s.system[0].offReason, OffReason.unknown);
      expect(s.system[1].offReason, OffReason.user);
    });

    test('a first Stopped near the range start is clipped to the range', () {
      final s = build([ev(room, at(2), 'System - User', 'Stopped')]);
      final x = s.system.single;
      expect(x.start, monday);
      expect(x.startClipped, isTrue);
      expect(x.startSource, isNull);
      expect(x.hours, 2);
    });

    test('a first Scheduled stop is not turned into a session', () {
      final s = build([ev(room, at(2), 'System - Scheduled', 'Stopped')]);
      expect(s.system, isEmpty);
      expect(s.orphanStops, 1);
    });

    test('a first Stopped beyond the cap from range start is an orphan', () {
      final s = build([ev(room, at(17), 'System - User', 'Stopped')]);
      expect(s.system, isEmpty);
      expect(s.orphanStops, 1);
    });

    test('open at range end is clipped and flagged ongoing', () {
      final s = build([
        ev(room, at(20), 'System - User', 'Started'),
        ev(room, at(20), 'Projector_1', 'Started'),
      ], end: at(22));
      expect(s.system.single.end, at(22));
      expect(s.system.single.offReason, OffReason.truncated);
      expect(s.system.single.ongoing, isTrue);
      expect(s.devices.single.endKind, SessionEnd.ongoing);
    });

    test('open past the cap at range end is capped, not ongoing', () {
      final s = build([
        ev(room, at(1), 'System - User', 'Started'),
      ], end: at(30));
      expect(s.system.single.offReason, OffReason.capped);
      expect(s.system.single.end, at(17));
    });

    test('events outside the range are ignored', () {
      final s = build([
        ev(room, at(-2), 'System - User', 'Started'),
        ev(room, at(1), 'System - User', 'Stopped'),
      ], start: monday);
      // The Started is outside, so the Stopped is clipped from range start.
      expect(s.system.single.start, monday);
      expect(s.system.single.startClipped, isTrue);
    });
  });

  group('device sessions', () {
    test('duplicate Started keeps the first start', () {
      final s = build([
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(9, 30), 'Projector_1', 'Started'),
        ev(room, at(10), 'Projector_1', 'Stopped'),
      ]);
      expect(s.devices.single.start, at(9));
      expect(s.devices.single.hours, 1);
      expect(s.devices.single.deviceType, 'PROJECTOR');
      expect(s.duplicateStarts, 1);
    });

    test('devices stay on after system power-off until their own Stopped', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
        ev(room, at(10, 1), 'Projector_1', 'Stopped'),
      ]);
      expect(s.devices.single.end, at(10, 1));
      expect(s.devices.single.endKind, SessionEnd.stopped);
    });

    test('missing device stop is capped', () {
      final s = build(
        [ev(room, at(9), 'Camera_2', 'Started')],
        cap: const Duration(hours: 4),
        end: at(20),
      );
      expect(s.devices.single.unterminated, isTrue);
      expect(s.devices.single.end, at(13));
    });

    test('several devices are tracked independently', () {
      final s = build([
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(9), 'Projector_2', 'Started'),
        ev(room, at(10), 'Projector_2', 'Stopped'),
        ev(room, at(11), 'Projector_1', 'Stopped'),
      ]);
      expect(
        {for (final d in s.devices) d.deviceId: d.hours},
        {'Projector_1': 2.0, 'Projector_2': 1.0},
      );
    });

    test('first device Stopped near range start is clipped', () {
      final s = build([ev(room, at(1), 'Projector_1', 'Stopped')]);
      expect(s.devices.single.startClipped, isTrue);
      expect(s.devices.single.hours, 1);
    });

    test('a Stopped after the cap ends the session at its real time', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
        ev(room, at(30), 'System - User', 'Started'),
        ev(room, at(31), 'System - User', 'Stopped'),
        ev(room, at(39), 'Projector_1', 'Stopped'), // on for 30 h
      ]);
      final d = s.devices.single;
      expect(d.end, at(39));
      expect(d.hours, 30);
      expect(d.endKind, SessionEnd.stopped);
      expect(d.unterminated, isFalse);
      expect(s.orphanStops, 0);
    });

    test('a Started again after the cap means the Stopped was lost', () {
      final s = build([
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(40), 'Projector_1', 'Started'),
        ev(room, at(41), 'Projector_1', 'Stopped'),
      ]);
      expect(
        [for (final d in s.devices) (d.start, d.end, d.endKind)],
        [
          (at(9), at(25), SessionEnd.capped),
          (at(40), at(41), SessionEnd.stopped),
        ],
      );
      expect(s.duplicateStarts, 0);
    });

    test('a Stopped beyond the hard limit cannot stretch a session', () {
      final s = build([
        ev(room, at(9), 'Projector_1', 'Started'),
        ev(room, at(9 + 24 * 8), 'Projector_1', 'Stopped'),
      ], end: at(24 * 10));
      expect(s.devices.first.end, at(25));
      expect(s.devices.first.endKind, SessionEnd.capped);
    });

    test('a Stopped after a reboot is a re-sync, not a clipped session', () {
      final s = build([
        ev(room, at(1), 'Initialize', 'Started'),
        ev(room, at(1, 2), 'Projector_1', 'Stopped'),
        ev(room, at(5), 'Camera_1', 'Stopped'),
      ]);
      expect(s.devices, isEmpty);
      expect(s.orphanStops, 0);
    });

    test('a Stopped long after power-off is a re-sync', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9), 'Camera_1', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
        ev(room, at(10, 1), 'Camera_1', 'Stopped'),
        // Camera connection lost while the room is off.
        ev(room, at(14), 'Camera_1', 'Stopped'),
      ]);
      expect(s.devices, hasLength(1));
      expect(s.orphanStops, 0);
    });
  });

  group('input sessions', () {
    test('input runs until the next input, then until power-off', () {
      final s = build([
        ev(room, at(9), 'System - User', 'Started'),
        ev(room, at(9), 'pc', 'Started'),
        ev(room, at(9, 30), 'hdmi', 'Started'),
        ev(room, at(11), 'System - User', 'Stopped'),
      ]);
      expect(
        [for (final i in s.inputs) (i.inputKey, i.hours, i.endKind)],
        [('pc', 0.5, SessionEnd.switched), ('hdmi', 1.5, SessionEnd.systemOff)],
      );
    });

    test('prefixed sources, Trace selections and an explicit Stopped', () {
      final s = build([
        ev(room, at(9), 'System Power - User', 'Started'),
        ev(room, at(9, 30), 'Source - HDMI 1', 'Started'),
        ev(room, at(10), 'Source - HDMI 1', 'Stopped'),
        ev(room, at(10, 30), 'Input: Wireless', 'Trace'),
        ev(room, at(10, 45), 'Source - HDMI 1', 'Stopped'), // not on screen
        ev(room, at(11), 'System Power - User', 'Stopped'),
      ]);
      expect(
        [for (final i in s.inputs) (i.inputLabel, i.hours, i.endKind)],
        [
          ('HDMI 1', 0.5, SessionEnd.stopped),
          ('Wireless', 0.5, SessionEnd.systemOff),
        ],
      );
    });

    test('automatic default source: within 15 s or before startup complete', () {
      final s = build([
        ev(room, at(9), 'System Power', 'Started'),
        ev(room, at(9, 0, 14), 'Source - PC', 'Started'),
        ev(room, at(9, 5), 'Source - HDMI', 'Started'),
        ev(room, at(10), 'System Power', 'Stopped'),
        ev(room, at(11), 'System Power', 'Started'),
        ev(room, at(11, 0, 40), 'Source - PC', 'Started'),
        ev(room, at(11, 0, 50), 'System Startup Complete', 'Trace'),
        ev(room, at(12), 'System Power', 'Stopped'),
        ev(room, at(13), 'System Power', 'Started'),
        ev(room, at(13, 0, 20), 'Source - PC', 'Started'),
        ev(room, at(14), 'System Power', 'Stopped'),
      ]);
      expect(
        [for (final e in s.automaticInputStarts) e.timestamp],
        unorderedEquals([at(9, 0, 14), at(11, 0, 40)]),
      );
    });

    test('re-selecting the same input continues the session', () {
      final s = build([
        ev(room, at(9), 'pc', 'Started'),
        ev(room, at(9, 10), 'PC', 'Started'),
        ev(room, at(10), 'System - User', 'Stopped'),
      ]);
      expect(s.inputs.single.selections, 2);
      expect(s.inputs.single.hours, 1);
    });

    test('input without power-off is capped', () {
      final s = build(
        [ev(room, at(1), 'pc', 'Started')],
        cap: const Duration(hours: 2),
        end: at(5),
      );
      expect(s.inputs.single.endKind, SessionEnd.capped);
      expect(s.inputs.single.hours, 2);
    });
  });

  group('mute sessions', () {
    test('mute from Started to Stopped, closed by power-off', () {
      final s = build([
        ev(room, at(9), 'Microphone Muted', 'Started'),
        ev(room, at(9, 15), 'Microphone Muted', 'Stopped'),
        ev(room, at(9, 30), 'Program Audio Muted', 'Started'),
        ev(room, at(10), 'System - Inactivity', 'Stopped'),
      ]);
      expect(
        [for (final m in s.mutes) (m.name, m.hours, m.endKind)],
        [
          ('Microphone', 0.25, SessionEnd.stopped),
          ('Program Audio', 0.5, SessionEnd.systemOff),
        ],
      );
    });
  });
}
