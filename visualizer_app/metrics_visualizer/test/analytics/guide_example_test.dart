// The "Example: one room, one session" table from Implementation_Guide.md,
// with the numbers the guide says the Visualizer reports for it.

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

void main() {
  const room = 'SCI-101';
  DateTime at(int h, int m, int s) => DateTime.utc(2026, 1, 5, h, m, s);

  final events = [
    ev(room, at(8, 0, 0), 'Program Start', 'Started'),
    ev(room, at(8, 5, 0), 'Ok', 'Heartbeat'),
    ev(room, at(13, 58, 2), 'System Power - User', 'Started'),
    ev(room, at(13, 58, 3), 'Source - Lectern PC', 'Started'),
    ev(room, at(13, 58, 4), 'Projector 1', 'Started'),
    ev(room, at(13, 58, 40), 'System Startup Complete', 'Trace'),
    ev(room, at(14, 3, 11), 'Source - HDMI 1', 'Started'),
    ev(room, at(14, 20, 45), 'Program Audio Mute', 'Started'),
    ev(room, at(14, 21, 30), 'Program Audio Mute', 'Stopped'),
    ev(room, at(14, 30, 12), 'Help Pressed', 'Trace'),
    ev(room, at(14, 55, 0), 'Program Audio Volume', 'Level 40'),
    ev(room, at(15, 15, 9), 'System Power - User', 'Stopped'),
    ev(room, at(15, 15, 10), 'Projector 1', 'Stopped'),
    ev(room, at(15, 15, 50), 'System Shutdown Complete', 'Trace'),
  ];

  late AnalysisResult r;
  setUpAll(() {
    r = analyze(
      ds(events, start: DateTime.utc(2026, 1, 5), end: DateTime.utc(2026, 1, 6)),
      utcConfig,
    );
  });

  int roundedMinutes(Duration d) => (d.inSeconds / 60).round();

  test('every event is recognized', () {
    expect(r.dataQuality.unclassifiedTotal, 0);
  });

  test('one system session of 1 h 17 m', () {
    final s = r.sessions[room]!.system;
    expect(s, hasLength(1));
    expect(roundedMinutes(s.single.duration), 77);
    expect(s.single.startSource, PowerSource.user);
    expect(s.single.offReason, OffReason.user);
  });

  test('automatic default source, then one selection on screen 1 h 12 m', () {
    final sessions = r.sessions[room]!;
    expect(sessions.automaticInputStarts.single.metric, 'Source - Lectern PC');
    final inputs = sessions.inputs;
    expect([for (final i in inputs) i.inputLabel], ['Lectern PC', 'HDMI 1']);
    expect(roundedMinutes(inputs.last.duration), 72);
    expect(inputs.last.endKind, SessionEnd.systemOff);
    expect(r.inputs.totalSelections, 1);
    final hdmi = r.inputs.campus.firstWhere((s) => s.label == 'HDMI 1');
    expect(hdmi.selections, 1);
    final pc = r.inputs.campus.firstWhere((s) => s.label == 'Lectern PC');
    expect(pc.selections, 0);
    expect(pc.hours, greaterThan(0));
  });

  test('1 h 17 m of projector use', () {
    final d = r.devices.devices.single;
    expect(d.deviceId, 'Projector 1');
    expect(d.deviceType, 'PROJECTOR');
    expect((d.onHours * 60).round(), 77);
  });

  test('one mute of 45 s', () {
    final mute = r.audio.mutes.single;
    expect(mute.name, 'Program Audio');
    expect(mute.muteCount, 1);
    expect((mute.mutedHours * 3600).round(), 45);
    expect(r.audio.volumes.single.averageLevel, 40);
  });

  test('one help-labelled event at 14:30', () {
    expect(r.roomSummary(room)!.helpEvents, 1);
    final help = r.issues.where((i) => i.type == IssueType.helpEvents).toList();
    expect(help, hasLength(1));
    expect(help.single.count, 1);
    expect(help.single.start, at(14, 30, 12));
  });

  test('the program start is counted and nothing else is reported', () {
    expect(r.roomSummary(room)!.reboots, 1);
    expect(
      {for (final i in r.issues) i.type},
      {IssueType.helpEvents},
    );
  });
}
