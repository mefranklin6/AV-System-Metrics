import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:metrics_visualizer/app.dart';
import 'package:metrics_visualizer/data/api_client.dart';
import 'package:metrics_visualizer/data/csv_importer.dart';
import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/data/token_store.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Size wideSize = Size(1280, 900);
const Size narrowSize = Size(400, 860);

/// Tall enough that the whole Data source page is on screen.
const Size tallSize = Size(1400, 2600);

/// A running app under test with fakes for every side effect.
class TestApp {
  TestApp(this.settings, this.app, this.navigation, this.tokens);

  final SettingsState settings;
  final AppState app;
  final NavigationState navigation;
  final MemoryTokenStore tokens;
  final List<String> announcements = [];
  int filePicks = 0;
}

/// Pumps the full app. Analysis runs synchronously (no isolates in widget
/// tests); demo data is a small fixed campus.
Future<TestApp> pumpApp(
  WidgetTester tester, {
  Size size = wideSize,
  ThemeMode themeMode = ThemeMode.light,
  bool highContrast = false,
  double textScale = 1.0,
  bool reduceMotion = true,
  AppDestination initial = AppDestination.dataSource,
  bool loadDemo = false,
  http.Client? httpClient,
  Map<String, Object> prefs = const {},
  String? savedToken,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefs);
  final settings = await SettingsState.load();
  await settings.setThemeMode(themeMode);
  await settings.setHighContrast(highContrast);
  await settings.setTextScale(textScale);
  await settings.setReduceMotion(reduceMotion);

  final tokens = MemoryTokenStore(savedToken);
  final navigation = NavigationState(initial: initial);
  late TestApp t;
  final app = AppState(
    settings: settings,
    analysisRunner: (r) async => runAnalysisRequest(r),
    csvImporter: (bytes, name) async => importCsvBytes(bytes, sourceName: name),
    demoRunner: () async => generateDemoDataset(end: DateTime.utc(2026, 11, 10), weeks: 2),
    filePicker: () async {
      t.filePicks++;
      return null;
    },
    apiClientFactory: (url, token) => AnalyticsApiClient(baseUrl: url, token: token, httpClient: httpClient),
    tokenStore: tokens,
    announcer: (m, {assertive = false}) => t.announcements.add(m),
  );
  t = TestApp(settings, app, navigation, tokens);
  addTearDown(app.dispose);

  if (loadDemo) await app.loadDemo();

  await tester.pumpWidget(MetricsVisualizerApp(settings: settings, appState: app, navigation: navigation));
  await tester.pump();
  if (loadDemo) await settleWork(tester, t);
  return t;
}

/// Pumps a few frames (indeterminate progress indicators never "settle").
Future<void> pumpFrames(WidgetTester tester, [int frames = 5]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets fake-async futures (loading, analysis) complete and the UI update.
Future<void> settleWork(WidgetTester tester, TestApp t) async {
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (!t.app.isLoading && !t.app.isAnalyzing) break;
  }
  await pumpFrames(tester, 3);
}

/// The WCAG checks every main screen must pass. Run them under
/// `variant: TargetPlatformVariant.desktop()` too: several semantics differ
/// on desktop (for example DropdownMenu's arrow button).
Future<void> expectMeetsA11yGuidelines(WidgetTester tester) async {
  final handle = tester.ensureSemantics();
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  handle.dispose();
}
