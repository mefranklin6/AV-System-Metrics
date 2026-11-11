import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/config.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults', () async {
    final s = await SettingsState.load();
    expect(s.themeMode, ThemeMode.system);
    expect(s.highContrast, isFalse);
    expect(s.palette, ChartPaletteKind.standard);
    expect(s.textScale, 1.0);
    expect(s.reduceMotion, isFalse);
    expect(s.showChartPatterns, isTrue);
    expect(s.timeDisplay, TimeDisplay.local);
    expect(s.excludeClients, {'AVSM-System'});
    expect(s.apiBaseUrl, '');
    expect(s.rememberApiToken, isFalse);
    expect(jsonEncode(s.analysisConfig.toJson()), jsonEncode(const AnalysisConfig().toJson()));
  });

  test('every setting persists and reloads', () async {
    final s = await SettingsState.load();
    var notifications = 0;
    s.addListener(() => notifications++);
    await s.setThemeMode(ThemeMode.dark);
    await s.setHighContrast(true);
    await s.setPalette(ChartPaletteKind.tritanopia);
    await s.setTextScale(1.5);
    await s.setReduceMotion(true);
    await s.setShowChartPatterns(false);
    await s.setTimeDisplay(TimeDisplay.utc);
    final config = const AnalysisConfig().copyWith(
      classifier: const ClassifierConfig(inputNames: ['pc', 'hdmi'], buildingPattern: r'^([A-Z]{2,4})_'),
      thresholds: const IssueThresholds(powerCycleCount: 4, buttonMashWindow: Duration(seconds: 20)),
      ratedLifeHours: const {'PROJECTOR': 6000, 'CAMERA': 30000},
      maxSessionLength: const Duration(hours: 10),
    );
    await s.setAnalysisConfig(config);
    await s.setExcludeClients({'AVSM-System', ' TEST_ROOM ', ''});
    await s.setApiBaseUrl(' https://avsm.example.edu:8081 ');
    await s.setRememberApiToken(true);
    expect(notifications, 11);

    final reloaded = await SettingsState.load(await SharedPreferences.getInstance());
    expect(reloaded.themeMode, ThemeMode.dark);
    expect(reloaded.highContrast, isTrue);
    expect(reloaded.palette, ChartPaletteKind.tritanopia);
    expect(reloaded.textScale, 1.5);
    expect(reloaded.reduceMotion, isTrue);
    expect(reloaded.showChartPatterns, isFalse);
    expect(reloaded.timeDisplay, TimeDisplay.utc);
    expect(reloaded.analysisConfig.classifier.inputNames, ['pc', 'hdmi']);
    expect(reloaded.analysisConfig.classifier.buildingPattern, r'^([A-Z]{2,4})_');
    expect(reloaded.analysisConfig.thresholds.powerCycleCount, 4);
    expect(reloaded.analysisConfig.thresholds.buttonMashWindow, const Duration(seconds: 20));
    expect(reloaded.analysisConfig.ratedLifeHours, {'PROJECTOR': 6000.0, 'CAMERA': 30000.0});
    expect(reloaded.analysisConfig.maxSessionLength, const Duration(hours: 10));
    expect(reloaded.analysisConfig.useLocalTime, isFalse, reason: 'follows UTC display');
    expect(reloaded.excludeClients, {'AVSM-System', 'TEST_ROOM'});
    expect(reloaded.apiBaseUrl, 'https://avsm.example.edu:8081');
    expect(reloaded.rememberApiToken, isTrue);
  });

  test('unchanged values do not notify', () async {
    final s = await SettingsState.load();
    var notifications = 0;
    s.addListener(() => notifications++);
    await s.setThemeMode(ThemeMode.system);
    await s.setTextScale(1.0);
    await s.setExcludeClients({'AVSM-System'});
    await s.setAnalysisConfig(const AnalysisConfig());
    expect(notifications, 0);
  });

  test('text scale is clamped to 1.0-2.0 and rounded to 10% steps', () async {
    final s = await SettingsState.load();
    await s.setTextScale(5);
    expect(s.textScale, 2.0);
    await s.setTextScale(0.2);
    expect(s.textScale, 1.0);
    await s.setTextScale(1.234);
    expect(s.textScale, 1.2);
  });

  test('corrupt or invalid stored values fall back to defaults', () async {
    SharedPreferences.setMockInitialValues({
      'v1.themeMode': 'purple',
      'v1.palette': 'nope',
      'v1.textScale': 9.0,
      'v1.analysisConfig': '{not json',
    });
    final s = await SettingsState.load();
    expect(s.themeMode, ThemeMode.system);
    expect(s.palette, ChartPaletteKind.standard);
    expect(s.textScale, 2.0);
    expect(s.analysisConfig.classifier.inputNames, ClassifierConfig.defaultInputNames);

    final bad = const AnalysisConfig()
        .copyWith(classifier: const ClassifierConfig(devicePattern: '(unclosed'));
    SharedPreferences.setMockInitialValues({'v1.analysisConfig': jsonEncode(bad.toJson())});
    final s2 = await SettingsState.load();
    expect(s2.analysisConfig.classifier.devicePattern, ClassifierConfig.defaultDevicePattern);
  });

  test('invalid analysis config is rejected with a message', () async {
    final s = await SettingsState.load();
    expect(
        () => s.setAnalysisConfig(const AnalysisConfig(classifier: ClassifierConfig(buildingPattern: '[A-Z]+'))),
        throwsA(isA<ArgumentError>().having((e) => '${e.message}', 'message', contains('capture group'))));
    expect(s.analysisConfig.classifier.buildingPattern, ClassifierConfig.defaultBuildingPattern);
  });

  test('reset restores defaults but keeps the API connection details', () async {
    final s = await SettingsState.load();
    await s.setThemeMode(ThemeMode.light);
    await s.setTextScale(2);
    await s.setPalette(ChartPaletteKind.monochrome);
    await s.setExcludeClients({});
    await s.setApiBaseUrl('https://avsm.example.edu');
    await s.setRememberApiToken(true);
    await s.resetToDefaults();
    expect(s.themeMode, ThemeMode.system);
    expect(s.textScale, 1.0);
    expect(s.palette, ChartPaletteKind.standard);
    expect(s.excludeClients, {'AVSM-System'});
    expect(s.apiBaseUrl, 'https://avsm.example.edu');
    expect(s.rememberApiToken, isTrue);
    final reloaded = await SettingsState.load(await SharedPreferences.getInstance());
    expect(reloaded.textScale, 1.0);
    expect(reloaded.excludeClients, {'AVSM-System'});
  });

  group('validateRegexPattern', () {
    test('accepts valid patterns and counts capture groups', () {
      expect(validateRegexPattern(ClassifierConfig.defaultDevicePattern, minGroups: 1), isNull);
      expect(validateRegexPattern(ClassifierConfig.defaultNavigationButtonPattern), isNull);
      expect(validateRegexPattern(ClassifierConfig.defaultBuildingPattern, minGroups: 1), isNull);
      expect(validateRegexPattern(r'(?:a)(b)', minGroups: 1), isNull);
    });

    test('explains problems', () {
      expect(validateRegexPattern(''), contains('Enter'));
      expect(validateRegexPattern('(abc'), contains('not a valid regular expression'));
      expect(validateRegexPattern('[a-'), isNotNull);
      expect(validateRegexPattern('abc', minGroups: 1), contains('capture group'));
      expect(validateRegexPattern('(?:abc)', minGroups: 1), contains('capture group'));
      expect(validateRegexPattern('a' * 501), contains('500'));
    });
  });

  test('validateAnalysisConfig checks every limit', () {
    expect(validateAnalysisConfig(const AnalysisConfig()), isNull);
    expect(validateAnalysisConfig(const AnalysisConfig(classifier: ClassifierConfig(inputNames: [], sourcePrefixes: []))), isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(thresholds: IssueThresholds(buttonMashCount: 1))), isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(thresholds: IssueThresholds(inputHuntWindow: Duration.zero))),
        isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(thresholds: IssueThresholds(deviceLeftOnHours: 0))), isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(thresholds: IssueThresholds(offlineGap: Duration(minutes: 1)))),
        isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(ratedLifeHours: {'PROJECTOR': 0})), isNotNull);
    expect(validateAnalysisConfig(const AnalysisConfig(maxSessionLength: Duration(minutes: 5))), isNotNull);
  });
}
