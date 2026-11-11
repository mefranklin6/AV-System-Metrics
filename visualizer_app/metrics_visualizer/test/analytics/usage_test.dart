import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

DateTime at(int hour, [int minute = 0]) =>
    monday.add(Duration(hours: hour, minutes: minute));

void main() {
  group('input usage', () {
    test('time on screen is weighted by duration', () {
      final r = analyze(
        ds(
          [
            ev('BSS_1', at(9, 59), 'System - User', 'Started'),
            ev('BSS_1', at(10), 'pc', 'Started'),
            ev('BSS_1', at(10, 30), 'hdmi', 'Started'),
            ev('BSS_1', at(12), 'System - User', 'Stopped'),
          ],
          start: monday,
          end: monday.add(const Duration(days: 1)),
        ),
        utcConfig,
      );
      final byKey = {for (final s in r.inputs.campus) s.key: s};
      expect(byKey['pc']!.hours, closeTo(0.5, 1e-9));
      expect(byKey['hdmi']!.hours, closeTo(1.5, 1e-9));
      expect(byKey['pc']!.selectionShare, 0.5);
      expect(byKey['pc']!.timeShare, closeTo(0.25, 1e-9));
      expect(byKey['hdmi']!.timeShare, closeTo(0.75, 1e-9));
      expect(r.inputs.campus.first.key, 'hdmi');
      expect(r.inputs.mostUsedByTime!.label, 'HDMI');
      expect(r.inputs.byRoom['BSS_1'], hasLength(2));
      expect(r.inputs.byBuilding['BSS']!.first.key, 'hdmi');
      expect(r.inputs.totalSelections, 2);
      expect(r.inputs.totalHours, closeTo(2, 1e-9));
    });

    test('rarely used inputs are listed as removal candidates', () {
      final events = <MetricEvent>[];
      for (var d = 0; d < 60; d++) {
        final base = monday.add(Duration(days: d));
        events
          ..add(ev('ARTS_1', base.add(hrs(9)), 'System - User', 'Started'))
          ..add(ev('ARTS_1', base.add(hrs(9)).add(min(1)), 'pc', 'Started'))
          ..add(ev('ARTS_1', base.add(hrs(10)), 'System - User', 'Stopped'));
      }
      events
        ..add(ev('ARTS_1', at(20), 'System - User', 'Started'))
        ..add(ev('ARTS_1', at(20, 1), 'dvd', 'Started'))
        ..add(ev('ARTS_1', at(20, 5), 'System - User', 'Stopped'));
      final r = analyze(ds(events), utcConfig);
      final campus = r.inputs.underused
          .where((u) => u.kind == UnderuseKind.rarelyUsedCampus)
          .map((u) => u.key);
      expect(campus, ['dvd']);
      final room = r.inputs.underused
          .where((u) => u.kind == UnderuseKind.rarelyUsedInRoom)
          .map((u) => (u.room, u.key));
      expect(room, [('ARTS_1', 'dvd')]);
    });

    test('inputs used in sibling rooms but never here are reported', () {
      final events = <MetricEvent>[];
      for (final room in ['BSS_1', 'BSS_2', 'BSS_3']) {
        for (var i = 0; i < 25; i++) {
          final t = monday.add(Duration(hours: i * 3));
          events
            ..add(ev(room, t, 'System - User', 'Started'))
            ..add(ev(room, t.add(min(1)), 'pc', 'Started'));
          if (room != 'BSS_3') {
            events.add(ev(room, t.add(min(30)), 'doc_cam', 'Started'));
          }
          events.add(ev(room, t.add(hrs(1)), 'System - User', 'Stopped'));
        }
      }
      final r = analyze(ds(events), utcConfig);
      final never = r.inputs.underused
          .where((u) => u.kind == UnderuseKind.neverUsedInRoom)
          .map((u) => (u.room, u.key))
          .toList();
      expect(never, [('BSS_3', 'doc_cam')]);
    });

    test('the startup default source counts for time but not selections', () {
      // The ControlScript template selects PC itself during startup, before
      // the "System Startup Sequence Complete" trace (production sample).
      final on = at(9);
      final r = analyze(
        ds(
          [
            ev('SSC_150', on, 'System - User', 'Started'),
            ev('SSC_150', on.add(const Duration(milliseconds: 3560)), 'pc',
                'Started'),
            ev('SSC_150', on.add(const Duration(milliseconds: 4940)),
                'System Startup Sequence Complete', 'Trace'),
            ev('SSC_150', on.add(min(20)), 'hdmi', 'Started'),
            ev('SSC_150', on.add(hrs(1)), 'System - User', 'Stopped'),
          ],
          start: monday,
          end: monday.add(const Duration(days: 1)),
        ),
        utcConfig,
      );
      final byKey = {for (final s in r.inputs.campus) s.key: s};
      expect(byKey['pc']!.selections, 0);
      expect(byKey['pc']!.hours, closeTo(20 / 60 - 3.56 / 3600, 1e-9));
      expect(byKey['hdmi']!.selections, 1);
      expect(byKey['hdmi']!.selectionShare, 1);
      expect(r.inputs.totalSelections, 1);
      final sessions = r.sessions['SSC_150']!;
      expect(sessions.automaticInputStarts, hasLength(1));
      expect(sessions.automaticInputStarts.single.metric, 'pc');
    });

    test('a slow startup selection counts as automatic only with the trace',
        () {
      List<MetricEvent> run(String room, {required bool trace}) => [
            ev(room, at(9), 'System - User', 'Started'),
            ev(room, at(9).add(const Duration(seconds: 40)), 'pc', 'Started'),
            if (trace)
              ev(room, at(9).add(const Duration(seconds: 50)),
                  'System Startup Sequence Complete', 'Trace'),
            ev(room, at(10), 'System - User', 'Stopped'),
          ];
      final r = analyze(
        ds([...run('A_1', trace: true), ...run('B_1', trace: false)]),
        utcConfig,
      );
      expect(r.inputs.byRoom['A_1']!.single.selections, 0);
      expect(r.inputs.byRoom['B_1']!.single.selections, 1);
    });
  });

  group('system usage', () {
    late AnalysisResult r;
    setUpAll(() {
      r = analyze(
        ds(
          [
            ev('A_1', at(9), 'System - User', 'Started'),
            ev('A_1', at(11), 'System - User', 'Stopped'),
            ev('B_1', at(9, 30), 'System - User', 'Started'),
            ev('B_1', at(10), 'System - Inactivity', 'Stopped'),
          ],
          start: monday,
          end: monday.add(const Duration(days: 7)),
        ),
        utcConfig,
      );
    });

    test('hour x weekday heatmap is the fraction of rooms in use', () {
      final occ = r.system.occupancy;
      expect(occ.valueAt(DateTime.monday, 9), closeTo(0.75, 1e-9));
      expect(occ.valueAt(DateTime.monday, 10), closeTo(0.5, 1e-9));
      expect(occ.valueAt(DateTime.monday, 11), 0);
      expect(occ.valueAt(DateTime.tuesday, 9), 0);
      expect(r.system.roomCount, 2);
      expect(r.overview.busiestWeekday, DateTime.monday);
      expect(r.overview.busiestHour, 9);
      expect(r.overview.busiestOccupancy, closeTo(0.75, 1e-9));
    });

    test('per-room heatmap and utilization', () {
      final a = r.system.rooms.firstWhere((u) => u.room == 'A_1');
      expect(a.occupancy.valueAt(1, 9), 1.0);
      expect(a.occupancy.valueAt(1, 10), 1.0);
      expect(a.hours, 2);
      expect(a.businessHoursAvailable, 75); // 5 days x 15 h
      expect(a.businessHoursInUse, 2);
      expect(a.utilization, closeTo(2 / 75, 1e-12));
      expect(a.afterHoursHours, 0);
    });

    test('power on/off histograms, lengths and off reasons', () {
      expect(r.system.powerOnByHour[9], 2);
      expect(r.system.powerOffByHour[11], 1);
      expect(r.system.powerOffByHour[10], 1);
      expect(r.system.powerOnByWeekday[0], 2);
      final buckets = {
        for (final b in r.system.sessionLengths) b.label: b.count,
      };
      expect(buckets['2-4 h'], 1);
      expect(buckets['30-60 min'], 1);
      expect(r.system.offReasons[OffReason.user], 1);
      expect(r.system.offReasons[OffReason.inactivity], 1);
      expect(r.system.offReasons[OffReason.scheduled], 0);
      expect(r.system.totalHours, 2.5);
      expect(r.system.medianSessionHours, 1.25);
      expect(r.system.daily.first.value, 2.5);
      expect(r.system.daily, hasLength(7));
      expect(r.system.weekly.single.value, 2.5);
      expect(r.system.weekly.single.isComplete, isTrue);
    });

    test('overview numbers', () {
      expect(r.overview.roomCount, 2);
      expect(r.overview.buildingCount, 2);
      expect(r.overview.totalSystemHours, 2.5);
      expect(r.overview.averageDailyHoursPerRoom, closeTo(2.5 / 2 / 7, 1e-12));
      expect(r.overview.eventCount, 4);
    });

    test('after-hours use is separated from business hours', () {
      final res = analyze(
        ds(
          [
            ev('A_1', at(21), 'System - User', 'Started'),
            ev('A_1', at(23), 'System - User', 'Stopped'),
          ],
          start: monday,
          end: monday.add(const Duration(days: 7)),
        ),
        utcConfig,
      );
      final a = res.system.rooms.single;
      expect(a.businessHoursInUse, 1);
      expect(a.afterHoursHours, 1);
    });
  });

  group('device usage', () {
    test('hours split across midnight and left-on sessions counted', () {
      final r = analyze(
        ds(
          [
            ev('A_1', at(22), 'Projector_1', 'Started'),
            ev('A_1', at(26), 'Projector_1', 'Stopped'),
            ev('A_1', at(30), 'Projector_1', 'Started'),
            ev('A_1', at(43), 'Projector_1', 'Stopped'),
          ],
          start: monday,
          end: monday.add(const Duration(days: 7)),
        ),
        utcConfig,
      );
      final d = r.devices.devices.single;
      expect(d.key, 'A_1/Projector_1');
      expect(d.onHours, 17);
      expect(d.sessions, 2);
      expect(d.daily[0].value, 2);
      expect(d.daily[1].value, 15);
      expect(d.leftOnSessions, 1);
      expect(d.longestSessionHours, 13);
      expect(d.weekly.single.value, 17);
      expect(r.devices.types.single.type, 'PROJECTOR');
      expect(r.devices.hoursByRoom['A_1'], 17);
    });
  });

  group('ui and audio usage', () {
    test('only Pressed counts as a press; nav share', () {
      final r = analyze(
        ds([
          ev('A_1', at(9), 'Btn_Volume_Up Pressed', 'Trace'),
          ev('A_1', at(9), 'Btn_Volume_Up Tapped', 'Trace'),
          ev('A_1', at(9, 1), 'Btn_Volume_Up Pressed', 'Trace'),
          ev('A_1', at(9, 2), 'Btn_Back Pressed', 'Trace'),
          ev('A_1', at(9, 3), 'Sldr_Volume Released', 'Trace'),
          ev('A_1', at(9, 4), 'NAV Share - Station 2', 'Share'),
        ]),
        utcConfig,
      );
      expect(r.ui.totalPresses, 3);
      expect(r.ui.navigationPresses, 1);
      expect(r.ui.navigationShare, closeTo(1 / 3, 1e-12));
      final up = r.ui.buttons.first;
      expect(up.control, 'Btn_Volume_Up');
      expect(up.presses, 2);
      expect(up.taps, 1);
      expect(r.ui.rooms.single.topButtons.first.control, 'Btn_Volume_Up');
      expect(r.ui.shares.single.station, 'Station 2');
    });

    test('volume levels and mute time', () {
      final r = analyze(
        ds([
          ev('A_1', at(9), 'System - User', 'Started'),
          ev('A_1', at(9), 'Program Audio Volume', 'Level 50 (Device -20.0)'),
          ev('A_1', at(9, 1), 'Program Audio Volume', 'Level 100'),
          ev('A_1', at(9, 2), 'Program Audio Volume', 'Level 5'),
          ev('A_1', at(9, 30), 'Microphone Muted', 'Started'),
          ev('A_1', at(10), 'System - User', 'Stopped'),
        ]),
        utcConfig,
      );
      final v = r.audio.volumes.single;
      expect(v.changes, 3);
      expect(v.averageLevel, closeTo(155 / 3, 1e-9));
      expect(v.minLevel, 5);
      expect(v.maxLevel, 100);
      expect(v.levelHistogram[0], 1);
      expect(v.levelHistogram[5], 1);
      expect(v.levelHistogram[9], 1);
      final m = r.audio.mutes.single;
      expect(m.muteCount, 1);
      expect(m.mutedHours, 0.5);
    });
  });

  test('excluded and admin clients are not rooms', () {
    final events = [
      ev('A_1', at(9), 'pc', 'Started'),
      ev('AVSM-System', at(9), 'Update Started', 'Trace'),
    ];
    final r = analyze(ds(events), utcConfig);
    expect(r.rooms, ['A_1']);
    expect(r.dataQuality.excludedEvents, 1);
    final r2 = analyze(ds(events), utcConfig, excludeClients: const {});
    expect(r2.rooms, ['A_1']);
    expect(r2.dataQuality.adminEvents, 1);
    final r3 = analyze(ds(events), utcConfig, excludeClients: const {'a_1'});
    expect(r3.rooms, isEmpty);
  });

  test('empty dataset analyses without errors', () {
    final r = analyze(ds(const []), utcConfig);
    expect(r.isEmpty, isTrue);
    expect(r.overview.roomCount, 0);
    expect(r.issues, isEmpty);
    expect(r.system.occupancy.maxValue, 0);
    expect(r.forecast.devices, isEmpty);
  });

  test('unclassified metrics are reported for data quality', () {
    final r = analyze(
      ds([
        ev('A_1', at(9), 'Weird', 'Custom'),
        ev('A_1', at(9, 1), 'Weird', 'Custom'),
      ]),
      utcConfig,
    );
    expect(r.dataQuality.unclassifiedTotal, 2);
    expect(r.dataQuality.unclassified.single.count, 2);
  });

  test('production sample analyses end to end', () {
    final r = analyze(productionSampleDataset(), utcConfig);
    expect(r.rooms, contains('SSC_150'));
    expect(r.rooms, contains('AJH_125A')); // heartbeat-only room
    expect(r.buildings, containsAll(['BSS', 'HOLT', 'SSC', 'YOLO']));
    expect(r.dataQuality.unclassifiedTotal, 0);
    final ssc = r.sessions['SSC_150']!;
    expect(ssc.system.single.ongoing, isTrue);
    expect(ssc.inputs.single.inputKey, 'pc');
    final holt = r.sessions['Holt_171']!;
    expect(holt.system.single.startClipped, isTrue);
    expect(holt.system.single.offReason, OffReason.user);
    final yolo = r.sessions['YOLO_142']!;
    expect(yolo.system.single.offReason, OffReason.inactivity);
    expect(r.inputs.campus.single.key, 'pc');
    expect(r.ui.totalPresses, greaterThan(20));
    // BSS_251 pressed Btn_Cam_Right 4 times in a second: below the
    // repeatable threshold, so not flagged.
    expect(r.issues.where((i) => i.type == IssueType.buttonMashing), isEmpty);
  });
}
