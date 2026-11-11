import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/data/demo_data.dart';

void main() {
  final end = DateTime.utc(2026, 11, 10);
  late Dataset ds;

  setUpAll(() => ds = generateDemoDataset(end: end));

  Iterable<MetricEvent> eventsOf(String room) => ds.events.where((e) => e.clientName == room);

  test('is deterministic for the same end and seed', () {
    final again = generateDemoDataset(end: end);
    expect(again.events.length, ds.events.length);
    for (var i = 0; i < ds.events.length; i += 997) {
      expect(again.events[i].toString(), ds.events[i].toString());
      expect(again.events[i].eventId, ds.events[i].eventId);
    }
    expect(again.heartbeats.length, ds.heartbeats.length);
    final other = generateDemoDataset(end: end, seed: 7);
    expect(other.events.length, isNot(ds.events.length));
  });

  test('covers 10 weeks, 24 rooms in 6 buildings plus the server client', () {
    expect(ds.origin, DatasetOrigin.demo);
    expect(ds.rangeEnd, end);
    expect(ds.rangeStart, end.subtract(const Duration(days: 70)));
    expect(ds.clientNames.toSet(), {...demoRooms, 'AVSM-System'});
    final buildings = {for (final r in demoRooms) RegExp(r'^([A-Za-z]+)').firstMatch(r)!.group(1)!.toUpperCase()};
    expect(buildings, hasLength(6));
    expect(ds.events.length, greaterThan(50000));
    for (final e in ds.events) {
      expect(e.timestamp.isBefore(ds.rangeStart), isFalse);
      expect(e.timestamp.isBefore(ds.rangeEnd), isTrue);
    }
  });

  test('pc is the most popular input and dvd / blu_ray are nearly unused', () {
    final inputs = <String, int>{};
    for (final e in ds.events) {
      if (e.action == 'Started' && const ClassifierConfig().inputNames.contains(e.metric.toLowerCase())) {
        inputs[e.metric] = (inputs[e.metric] ?? 0) + 1;
      }
    }
    final top = inputs.entries.reduce((a, b) => a.value >= b.value ? a : b);
    expect(top.key, 'pc');
    final total = inputs.values.fold(0, (a, b) => a + b);
    expect((inputs['dvd'] ?? 0) / total, lessThan(0.01));
    expect((inputs['blu_ray'] ?? 0) / total, lessThan(0.01));
    expect(inputs.keys, containsAll(['hdmi', 'wireless', 'doc_cam', 'station_1', 'station_1_laptop']));
  });

  test('contains every event family the analytics engine understands', () {
    bool has(String metric, String action) => ds.events.any((e) => e.metric == metric && e.action == action);
    for (final (m, a) in [
      ('System - User', 'Started'),
      ('System - User', 'Stopped'),
      ('System - Inactivity', 'Stopped'),
      ('System - Scheduled', 'Stopped'),
      ('System - GVE', 'Started'),
      ('System - Restore', 'Started'),
      ('System - User Reset', 'Started'),
      ('System Startup Sequence Complete', 'Trace'),
      ('System Shutdown Sequence Complete', 'Trace'),
      ('System Restored', 'Trace'),
      ('Initialize', 'Started'),
      ('Initialize', 'Stopped'),
      ('Projector_1', 'Started'),
      ('Projector_1', 'Stopped'),
      ('Camera_1', 'Started'),
      ('Display_1', 'Started'),
      ('Help', 'Started'),
      ('Microphone Muted', 'Started'),
      ('Program Audio Muted', 'Stopped'),
      ('Btn_Volume_Up Pressed', 'Trace'),
      ('Sldr_Volume Released', 'Trace'),
      ('Projector_1', 'Connected'),
      ('Projector_1', 'Disconnected'),
    ]) {
      expect(has(m, a), isTrue, reason: '$m / $a');
    }
    expect(ds.events.any((e) => e.action.startsWith('Level ')), isTrue);
    expect(ds.events.any((e) => e.action == 'Share' && e.metric.startsWith('NAV Share - ')), isTrue);
    expect(ds.events.any((e) => e.metric.endsWith(' Tapped')), isTrue);
    expect(eventsOf('AVSM-System').every((e) => e.action == 'Trace'), isTrue);
  });

  test('injected issues are present', () {
    List<DateTime> times(String room, bool Function(MetricEvent) test) =>
        [for (final e in eventsOf(room)) if (test(e)) e.timestamp];

    bool burst(List<DateTime> ts, int count, Duration window) {
      for (var i = 0; i + count - 1 < ts.length; i++) {
        if (ts[i + count - 1].difference(ts[i]) <= window) return true;
      }
      return false;
    }

    expect(
        burst(times(DemoScenario.rapidPowerCycling, (e) => e.metric == 'System - User' && e.action == 'Started'),
            4, const Duration(minutes: 10)),
        isTrue);
    expect(burst(times(DemoScenario.buttonMashing, (e) => e.metric == 'Btn_Volume_Up Pressed'), 10,
        const Duration(seconds: 10)), isTrue);
    final nav = RegExp(ClassifierConfig.defaultNavigationButtonPattern, caseSensitive: false);
    expect(
        burst(
            times(DemoScenario.navigationThrash,
                (e) => e.action == 'Trace' && e.metric.endsWith(' Pressed') && nav.hasMatch(e.metric.replaceAll(' Pressed', ''))),
            12,
            const Duration(seconds: 30)),
        isTrue);
    final inputNames = const ClassifierConfig().inputNames.toSet();
    expect(
        burst(times(DemoScenario.inputHunting, (e) => e.action == 'Started' && inputNames.contains(e.metric.toLowerCase())),
            6, const Duration(minutes: 2)),
        isTrue);
    expect(burst(times(DemoScenario.connectionFlapping, (e) => e.action == 'Disconnected'), 6,
        const Duration(minutes: 15)), isTrue);

    // Projector left on for ~18 hours.
    final proj = eventsOf(DemoScenario.deviceLeftOn).where((e) => e.metric == 'Projector_1').toList();
    var longest = Duration.zero;
    DateTime? on;
    for (final e in proj) {
      if (e.action == 'Started') on ??= e.timestamp;
      if (e.action == 'Stopped' && on != null) {
        final d = e.timestamp.difference(on);
        if (d > longest) longest = d;
        on = null;
      }
    }
    expect(longest, greaterThan(const Duration(hours: 16)));

    expect(eventsOf(DemoScenario.helpRequests).where((e) => e.metric == 'Help' && e.action == 'Started').length,
        greaterThan(5));
  });

  test('heartbeats: last 30 days only, an offline room and an outage', () {
    final hbStart = end.subtract(const Duration(days: demoHeartbeatRetentionDays));
    expect(ds.heartbeatRetentionDays, demoHeartbeatRetentionDays);
    expect(ds.heartbeats.every((h) => !h.hourStart.isBefore(hbStart) && h.hourStart.isBefore(end)), isTrue);
    expect(ds.heartbeats.every((h) => h.hourStart.minute == 0 && h.count > 0), isTrue);

    final offlineSince = end.subtract(const Duration(days: DemoScenario.offlineDays));
    expect(
        ds.heartbeats.where((h) => h.clientName == DemoScenario.offlineRoom && !h.hourStart.isBefore(offlineSince)),
        isEmpty);
    expect(eventsOf(DemoScenario.offlineRoom).where((e) => !e.timestamp.isBefore(offlineSince)), isEmpty);
    expect(ds.heartbeats.where((h) => h.clientName == DemoScenario.offlineRoom), isNotEmpty);

    final outage = ds.heartbeats.where((h) => h.clientName == DemoScenario.outageRoom).toList();
    final expectedHours = 30 * 24;
    expect(outage.length, lessThan(expectedHours - 4), reason: 'several hours missing');
    expect(ds.heartbeats.where((h) => h.clientName == 'AVSM-System'), isEmpty);
  });

  test('usage grows over the 10 weeks', () {
    int sessionsInWeek(int w) {
      final s = ds.rangeStart.add(Duration(days: w * 7)), e = s.add(const Duration(days: 7));
      return ds.events
          .where((x) =>
              x.metric == 'System - User' && x.action == 'Started' && !x.timestamp.isBefore(s) && x.timestamp.isBefore(e))
          .length;
    }

    final firstTwo = sessionsInWeek(0) + sessionsInWeek(1);
    final lastTwo = sessionsInWeek(8) + sessionsInWeek(9);
    expect(lastTwo, greaterThan(firstTwo));
  });

  test('the analytics engine accepts the demo dataset', () {
    final result = analyze(ds, const AnalysisConfig());
    expect(result, isNotNull);
  });
}
