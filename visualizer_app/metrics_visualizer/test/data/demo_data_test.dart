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

  test('PC is the most selected source and DVD / Blu-ray are nearly unused', () {
    final c = MetricClassifier();
    final byLabel = <String, int>{};
    for (final e in ds.events) {
      final m = c.classify(e.metric, e.action);
      if (m.isSourceSelection) byLabel[m.inputLabel!] = (byLabel[m.inputLabel!] ?? 0) + 1;
    }
    final top = byLabel.entries.reduce((a, b) => a.value >= b.value ? a : b);
    expect(top.key, 'PC');
    final total = byLabel.values.fold(0, (a, b) => a + b);
    expect((byLabel['DVD'] ?? 0) / total, lessThan(0.01));
    expect((byLabel['Blu-ray'] ?? 0) / total, lessThan(0.01));
    expect(byLabel.keys, containsAll(['HDMI', 'Wireless', 'Document Camera', 'Station 1', 'Station 1 Laptop']));
  });

  test('most rooms use the recommended names, the legacy rooms the also-recognized ones', () {
    bool has(String room, String metric, String action) =>
        eventsOf(room).any((e) => e.metric == metric && e.action == action);
    const modern = 'SCI_101';
    expect(demoLegacyRooms, hasLength(lessThanOrEqualTo(2)));
    expect(demoLegacyRooms, isNot(contains(modern)));
    for (final room in demoLegacyRooms) {
      expect(eventsOf(room).any((e) => e.metric.startsWith('System - ')), isTrue, reason: room);
      expect(eventsOf(room).any((e) => e.metric.startsWith('System Power')), isFalse, reason: room);
      expect(eventsOf(room).any((e) => e.metric.startsWith('Source - ')), isFalse, reason: room);
    }
    for (final room in demoRooms.where((r) => !demoLegacyRooms.contains(r))) {
      expect(eventsOf(room).any((e) => e.metric.startsWith('System - ')), isFalse, reason: room);
      expect(eventsOf(room).any((e) => e.metric.contains('Btn_')), isFalse, reason: room);
    }
    expect(has(modern, 'System Power - User', 'Started'), isTrue);
    expect(has(modern, 'Source - PC', 'Started'), isTrue);
    expect(has(modern, 'Projector 1', 'Started'), isTrue);
  });

  test('contains every event family the analytics engine understands', () {
    bool has(String metric, String action) => ds.events.any((e) => e.metric == metric && e.action == action);
    for (final (m, a) in [
      // Recommended forms.
      ('System Power - User', 'Started'),
      ('System Power - User', 'Stopped'),
      ('System Power - Inactivity', 'Stopped'),
      ('System Power - Schedule', 'Stopped'),
      ('System Power - Remote', 'Started'),
      ('System Power - Restore', 'Started'),
      ('System Startup Complete', 'Trace'),
      ('System Shutdown Complete', 'Trace'),
      ('Program Start', 'Started'),
      ('Projector 1', 'Started'),
      ('Projector 1', 'Stopped'),
      ('Camera 1', 'Started'),
      ('Display 1', 'Started'),
      ('Source - HDMI', 'Started'),
      ('Help Pressed', 'Trace'),
      ('Microphone Mute', 'Started'),
      ('Program Audio Mute', 'Stopped'),
      ('Volume Up Pressed', 'Trace'),
      ('Volume Slider Released', 'Trace'),
      ('Projector 1', 'Connected'),
      ('Projector 1', 'Disconnected'),
      ('Program Audio Volume', 'Level 50'),
      // Also-recognized (legacy) forms.
      ('System - User', 'Started'),
      ('System - User', 'Stopped'),
      ('System - Inactivity', 'Stopped'),
      ('System - User Reset', 'Started'),
      ('System Startup Sequence Complete', 'Trace'),
      ('System Shutdown Sequence Complete', 'Trace'),
      ('Projector_1', 'Started'),
      ('hdmi', 'Started'),
      ('Help', 'Started'),
      ('Btn_Help Pressed', 'Trace'),
      ('Microphone Muted', 'Started'),
      ('Btn_Volume_Up Pressed', 'Trace'),
      ('Sldr_Volume Released', 'Trace'),
      ('Program Audio Volume', 'Level 50 (Device -20.0)'),
    ]) {
      expect(has(m, a), isTrue, reason: '$m / $a');
    }
    expect(ds.events.any((e) => e.action == 'Share'), isTrue);
    expect(ds.events.any((e) => e.metric.endsWith(' Tapped')), isTrue);
    expect(eventsOf('AVSM-System').every((e) => e.action == 'Trace'), isTrue);
    expect(ds.events.any((e) => e.metric.contains('GVE') || e.metric.contains('NAV Share')), isFalse);
  });

  test('injected patterns are present', () {
    List<DateTime> times(String room, bool Function(MetricEvent) test) =>
        [for (final e in eventsOf(room)) if (test(e)) e.timestamp];

    bool burst(List<DateTime> ts, int count, Duration window) {
      for (var i = 0; i + count - 1 < ts.length; i++) {
        if (ts[i + count - 1].difference(ts[i]) <= window) return true;
      }
      return false;
    }

    final c = MetricClassifier();
    ClassifiedMetric m(MetricEvent e) => c.classify(e.metric, e.action);

    expect(
        burst(
            times(DemoScenario.rapidPowerCycling,
                (e) => m(e).category == EventCategory.systemPower && m(e).isStart),
            4,
            const Duration(minutes: 10)),
        isTrue);
    expect(burst(times(DemoScenario.repeatedPresses, (e) => e.metric == 'Video Mute Pressed'), 8,
        const Duration(seconds: 10)), isTrue);
    expect(burst(times(DemoScenario.rapidNavigation, (e) => m(e).isPress && m(e).isNavigation), 12,
        const Duration(seconds: 30)), isTrue);
    expect(burst(times(DemoScenario.rapidSourceChanges, (e) => m(e).isSourceSelection), 6,
        const Duration(minutes: 2)), isTrue);
    expect(burst(times(DemoScenario.connectionFlapping, (e) => e.action == 'Disconnected'), 6,
        const Duration(minutes: 15)), isTrue);

    // Projector on for ~18 hours.
    final proj = eventsOf(DemoScenario.longDeviceSession).where((e) => e.metric == 'Projector 1').toList();
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

    expect(eventsOf(DemoScenario.helpEvents).where((e) => m(e).category == EventCategory.help).length,
        greaterThan(15));
  });

  test('heartbeats: last 30 days only, an offline room and an outage', () {
    final hbStart = end.subtract(const Duration(days: demoHeartbeatRetentionDays));
    expect(ds.heartbeatRetentionDays, demoHeartbeatRetentionDays);
    expect(ds.heartbeats.every((h) => !h.hourStart.isBefore(hbStart) && h.hourStart.isBefore(end)), isTrue);
    expect(ds.heartbeats.every((h) => h.hourStart.minute == 0 && h.count > 0), isTrue);

    final offlineSince = end.subtract(const Duration(days: DemoScenario.offlineDays));
    expect(
        ds.heartbeats.where((h) => h.clientName == DemoScenario.heartbeatGapRoom && !h.hourStart.isBefore(offlineSince)),
        isEmpty);
    expect(eventsOf(DemoScenario.heartbeatGapRoom).where((e) => !e.timestamp.isBefore(offlineSince)), isEmpty);
    expect(ds.heartbeats.where((h) => h.clientName == DemoScenario.heartbeatGapRoom), isNotEmpty);

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
              x.metric.endsWith(' - User') && x.action == 'Started' && !x.timestamp.isBefore(s) && x.timestamp.isBefore(e))
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
