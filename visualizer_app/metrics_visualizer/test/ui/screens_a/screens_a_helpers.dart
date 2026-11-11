import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/app.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/data/models.dart';
import 'package:metrics_visualizer/data/token_store.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Window sizes used by the screen tests.
const Size wide = Size(1400, 1000);
const Size extraWide = Size(1800, 1100);

/// 360 dp: the narrowest common phone width.
const Size narrow = Size(360, 800);

/// End of the demo data used in tests.
final DateTime demoEnd = DateTime.utc(2026, 11, 10);

/// Two weeks of the demo campus (24 rooms).
Dataset demoDataset({int weeks = 2}) => generateDemoDataset(end: demoEnd, weeks: weeks);

/// A running app with real providers, a fixed dataset and no side effects.
class ScreenHarness {
  ScreenHarness(this.settings, this.app, this.navigation);

  final SettingsState settings;
  final AppState app;
  final NavigationState navigation;
  final List<String> announcements = [];
}

/// Pumps the full app showing [destination]. When [dataset] is given it is
/// loaded (through AppState.loadDemo with an injected runner) and analysed
/// synchronously with the real engine.
Future<ScreenHarness> pumpScreen(
  WidgetTester tester,
  AppDestination destination, {
  Dataset? dataset,
  Size size = wide,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool reduceMotion = true,
  bool highContrast = false,
  String? room,
  AnalysisRunner? analysisRunner,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues({});
  final settings = await SettingsState.load();
  await settings.setThemeMode(themeMode);
  await settings.setTextScale(textScale);
  await settings.setReduceMotion(reduceMotion);
  await settings.setHighContrast(highContrast);
  // Bucket in UTC so results do not depend on the test machine's zone.
  await settings.setTimeDisplay(TimeDisplay.utc);

  final navigation = NavigationState(initial: destination);
  late ScreenHarness h;
  final app = AppState(
    settings: settings,
    analysisRunner: analysisRunner ?? (r) async => runAnalysisRequest(r),
    csvImporter: (bytes, name) async => importCsvBytes(bytes, sourceName: name),
    demoRunner: () async => dataset ?? demoDataset(),
    filePicker: () async => null,
    tokenStore: MemoryTokenStore(),
    announcer: (m, {assertive = false}) => h.announcements.add(m),
  );
  h = ScreenHarness(settings, app, navigation);
  addTearDown(app.dispose);

  if (dataset != null) await app.loadDemo();
  // loadDemo navigates nowhere by itself; make sure we show the right page.
  navigation.goTo(destination, room: room);

  await tester.pumpWidget(MetricsVisualizerApp(settings: settings, appState: app, navigation: navigation));
  await tester.pump();
  await settle(tester, h);
  return h;
}

/// Lets loading/analysis futures complete and the UI rebuild.
Future<void> settle(WidgetTester tester, ScreenHarness h) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (!h.app.isLoading && !h.app.isAnalyzing) break;
  }
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The analysis page's own scrollable (the outermost one under it).
Finder pageScrollable() => find.descendant(of: find.byType(AnalysisPage), matching: find.byType(Scrollable)).first;

/// Scrolls the page from top to bottom, calling [atEachStep] at every
/// position, and fails on any exception (including layout overflow).
Future<int> scrollThroughPage(WidgetTester tester, {Future<void> Function()? atEachStep}) async {
  final state = tester.state<ScrollableState>(pageScrollable());
  state.position.jumpTo(0);
  await tester.pump();
  var steps = 0;
  while (true) {
    expect(tester.takeException(), isNull, reason: 'exception at offset ${state.position.pixels}');
    if (atEachStep != null) await atEachStep();
    steps++;
    final p = state.position;
    if (p.pixels >= p.maxScrollExtent - 0.5 || steps > 200) break;
    p.jumpTo(math.min(p.pixels + p.viewportDimension * 0.8, p.maxScrollExtent));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.takeException(), isNull);
  return steps;
}

/// Grows the test window until the whole analysis page fits without
/// scrolling, so accessibility checks see every card un-clipped (a node cut
/// by the scroll edge would report a misleading small tap target).
Future<void> fitWholePage(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    final state = tester.state<ScrollableState>(pageScrollable());
    final extent = state.position.maxScrollExtent;
    if (extent <= 0.5) break;
    final size = tester.view.physicalSize;
    tester.view.physicalSize = Size(size.width, size.height + extent + 40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(tester.takeException(), isNull);
}

/// WCAG checks every main screen must pass, for what is on screen now.
Future<void> expectGuidelines(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
}

/// A very small dataset: one room, one session, two inputs, one device.
Dataset tinyDataset() {
  final t0 = DateTime.utc(2026, 11, 2, 9);
  MetricEvent e(int minutes, String metric, String action) => MetricEvent(
    clientName: 'TINY_101',
    timestamp: t0.add(Duration(minutes: minutes)),
    metric: metric,
    action: action,
  );
  return Dataset(
    events: [
      e(0, 'System - User', 'Started'),
      e(1, 'Projector_1', 'Started'),
      e(2, 'pc', 'Started'),
      e(30, 'hdmi', 'Started'),
      e(31, 'Btn_Volume_Up Pressed', 'Trace'),
      e(50, 'System - User', 'Stopped'),
      e(52, 'Projector_1', 'Stopped'),
    ],
    heartbeats: [HeartbeatBucket(clientName: 'TINY_101', hourStart: DateTime.utc(2026, 11, 2, 9), count: 12)],
    rangeStart: DateTime.utc(2026, 11, 2),
    rangeEnd: DateTime.utc(2026, 11, 3),
    origin: DatasetOrigin.demo,
    description: 'Tiny test dataset',
  );
}

/// Rooms that only sent heartbeats (no activity at all).
Dataset heartbeatOnlyDataset() => Dataset(
  events: const [],
  heartbeats: [
    for (final room in ['HB_100', 'HB_200'])
      for (var h = 0; h < 24; h++)
        HeartbeatBucket(clientName: room, hourStart: DateTime.utc(2026, 11, 2, h), count: 12),
  ],
  rangeStart: DateTime.utc(2026, 11, 2),
  rangeEnd: DateTime.utc(2026, 11, 3),
  origin: DatasetOrigin.demo,
  description: 'Heartbeats only',
);

/// Many rooms (for list virtualization and paging), each with a short day.
Dataset manyRoomsDataset({int rooms = 320}) {
  final events = <MetricEvent>[];
  final day = DateTime.utc(2026, 11, 2, 8);
  for (var r = 0; r < rooms; r++) {
    final name = 'B${(r ~/ 20).toString().padLeft(2, '0')}_${(100 + r).toString()}';
    final start = day.add(Duration(minutes: r % 300));
    events
      ..add(MetricEvent(clientName: name, timestamp: start, metric: 'System - User', action: 'Started'))
      ..add(
        MetricEvent(
          clientName: name,
          timestamp: start.add(const Duration(minutes: 1)),
          metric: r.isEven ? 'pc' : 'hdmi',
          action: 'Started',
        ),
      )
      ..add(
        MetricEvent(
          clientName: name,
          timestamp: start.add(const Duration(minutes: 2)),
          metric: 'Display_1',
          action: 'Started',
        ),
      )
      ..add(
        MetricEvent(
          clientName: name,
          timestamp: start.add(Duration(minutes: 40 + r % 90)),
          metric: 'Display_1',
          action: 'Stopped',
        ),
      )
      ..add(
        MetricEvent(
          clientName: name,
          timestamp: start.add(Duration(minutes: 45 + r % 90)),
          metric: r % 3 == 0 ? 'System - Inactivity' : 'System - User',
          action: 'Stopped',
        ),
      );
  }
  return Dataset(
    events: events,
    heartbeats: const [],
    rangeStart: DateTime.utc(2026, 11, 2),
    rangeEnd: DateTime.utc(2026, 11, 3),
    origin: DatasetOrigin.demo,
    description: 'Many rooms',
  );
}
