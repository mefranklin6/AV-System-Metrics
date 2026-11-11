import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/app.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/models.dart';
import 'package:metrics_visualizer/data/token_store.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:metrics_visualizer/ui/widgets/analysis_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui_test_helpers.dart';

export '../ui_test_helpers.dart';
export 'screens_b_fixtures.dart';

/// Pumps the full app on [initial] with [dataset] loaded (through the
/// regular demo loading path) and analysed synchronously.
Future<TestApp> pumpWithData(
  WidgetTester tester, {
  required Dataset dataset,
  required AppDestination initial,
  Size size = wideSize,
  ThemeMode themeMode = ThemeMode.light,
  bool highContrast = false,
  double textScale = 1.0,
  bool reduceMotion = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(const {});
  final settings = await SettingsState.load();
  await settings.setThemeMode(themeMode);
  await settings.setHighContrast(highContrast);
  await settings.setTextScale(textScale);
  await settings.setReduceMotion(reduceMotion);
  // Fixed zone so dates in assertions do not depend on the test machine.
  await settings.setTimeDisplay(TimeDisplay.utc);

  final tokens = MemoryTokenStore();
  final navigation = NavigationState(initial: initial);
  late TestApp t;
  final app = AppState(
    settings: settings,
    analysisRunner: (r) async => runAnalysisRequest(r),
    csvImporter: (bytes, name) async => importCsvBytes(bytes, sourceName: name),
    demoRunner: () async => dataset,
    filePicker: () async => null,
    tokenStore: tokens,
    announcer: (m, {assertive = false}) => t.announcements.add(m),
  );
  t = TestApp(settings, app, navigation, tokens);
  addTearDown(app.dispose);

  await app.loadDemo();
  await tester.pumpWidget(MetricsVisualizerApp(settings: settings, appState: app, navigation: navigation));
  await tester.pump();
  await settleWork(tester, t);
  return t;
}

/// The page-level scrollable of the current analysis screen.
Finder pageScrollable() => find
    .descendant(of: find.byType(AnalysisPage), matching: find.byType(Scrollable))
    .first;

/// Scrolls the analysis page from top to bottom so every lazily built item
/// is laid out (overflow and exceptions surface as test failures).
Future<void> scrollThroughPage(WidgetTester tester) async {
  final scrollable = pageScrollable();
  for (var i = 0; i < 80; i++) {
    final state = tester.state<ScrollableState>(scrollable);
    final pos = state.position;
    if (pos.pixels >= pos.maxScrollExtent - 1) break;
    pos.jumpTo((pos.pixels + 500).clamp(0, pos.maxScrollExtent).toDouble());
    await tester.pump();
  }
  await tester.pump();
}

/// Scrolls the page (by jumping, so inner scrollables such as chart lists
/// never swallow the drag) until [finder] is built, then brings it into view.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  final scrollable = pageScrollable();
  final pos = tester.state<ScrollableState>(scrollable).position;
  pos.jumpTo(0);
  await tester.pump();
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    if (pos.pixels >= pos.maxScrollExtent - 1) break;
    pos.jumpTo((pos.pixels + 400).clamp(0, pos.maxScrollExtent).toDouble());
    await tester.pump();
  }
  expect(finder, findsWidgets, reason: 'scrolled the whole page looking for it');
  await tester.ensureVisible(finder.first);
  await tester.pump();
}

/// Texts of the screen reader announcements made since the last call.
List<String> takeAnnouncementTexts(WidgetTester tester) =>
    [for (final a in tester.takeAnnouncements()) a.message];

/// Captures text written to the clipboard.
class ClipboardSpy {
  ClipboardSpy(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        text = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  String? text;
}
