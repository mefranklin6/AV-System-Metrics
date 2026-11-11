import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/config.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:metrics_visualizer/ui/screens/settings_screen.dart';

import 'ui_test_helpers.dart';

/// Tall enough to show the whole settings page without scrolling.
const Size settingsSize = Size(1400, 14000);

Finder textField(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextField)).first;

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('settings page meets accessibility guidelines (${mode.name})', (tester) async {
      await pumpApp(tester, themeMode: mode, size: settingsSize, initial: AppDestination.settings);
      expect(find.byType(SettingsScreen), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);
    });
  }

  testWidgets('theme, contrast and palette apply live', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    Brightness brightness() => Theme.of(tester.element(find.byType(SettingsScreen))).brightness;
    expect(brightness(), Brightness.light);

    await tester.tap(find.text('Dark'));
    await pumpFrames(tester, 3);
    expect(t.settings.themeMode, ThemeMode.dark);
    expect(brightness(), Brightness.dark);

    await tester.tap(find.text('High contrast'));
    await pumpFrames(tester, 3);
    expect(t.settings.highContrast, isTrue);
    expect(Theme.of(tester.element(find.byType(SettingsScreen))).colorScheme.surface, Colors.black);

    await tester.tap(find.text(ChartPaletteKind.tritanopia.label));
    await pumpFrames(tester, 2);
    expect(t.settings.palette, ChartPaletteKind.tritanopia);

    await tester.tap(find.text(ChartPaletteKind.monochrome.label));
    await pumpFrames(tester, 2);
    expect(find.text('Always on with the monochrome palette.'), findsOneWidget);

    await tester.tap(find.text('UTC'));
    await pumpFrames(tester, 2);
    expect(t.settings.timeDisplay, TimeDisplay.utc);
    expect(t.settings.analysisConfig.useLocalTime, isFalse);
  });

  testWidgets('text size buttons change the scale applied to the app', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    expect(find.text('Text size: 100%'), findsOneWidget);
    await tester.tap(find.byTooltip('Larger text'));
    await pumpFrames(tester, 2);
    await tester.tap(find.byTooltip('Larger text'));
    await pumpFrames(tester, 2);
    expect(t.settings.textScale, 1.2);
    expect(find.text('Text size: 120%'), findsOneWidget);
    final scaler = MediaQuery.textScalerOf(tester.element(find.byType(SettingsScreen)));
    expect(scaler.scale(10), closeTo(12, 0.001));
  });

  testWidgets('reduce motion toggle', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings, reduceMotion: false);
    await tester.tap(find.text('Reduce motion'));
    await pumpFrames(tester, 2);
    expect(t.settings.reduceMotion, isTrue);
  });

  testWidgets('invalid regular expressions show an error and are not applied', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    await tester.enterText(textField('Building pattern'), '([A-Z]+');
    await pumpFrames(tester, 2);
    expect(find.textContaining('not a valid regular expression'), findsOneWidget);
    expect(t.settings.analysisConfig.classifier.buildingPattern, ClassifierConfig.defaultBuildingPattern);

    await tester.enterText(textField('Building pattern'), '[A-Z]+');
    await pumpFrames(tester, 2);
    expect(find.textContaining('Add a capture group'), findsOneWidget);

    await tester.enterText(textField('Building pattern'), r'^([A-Z]{3})');
    await pumpFrames(tester, 2);
    expect(t.settings.analysisConfig.classifier.buildingPattern, r'^([A-Z]{3})');
    expect(find.textContaining('not a valid regular expression'), findsNothing);
  });

  testWidgets('number fields validate their range', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    await tester.enterText(textField('Repeated presses of one control: events'), '1');
    await pumpFrames(tester, 2);
    expect(find.text('Must be from 2 to 1000.'), findsOneWidget);
    expect(t.settings.analysisConfig.thresholds.buttonMashCount, 6);
    await tester.enterText(textField('Repeated presses of one control: events'), '9');
    await pumpFrames(tester, 2);
    expect(t.settings.analysisConfig.thresholds.buttonMashCount, 9);

    await tester.enterText(textField('PROJECTOR rated life'), '6000');
    await pumpFrames(tester, 2);
    expect(t.settings.analysisConfig.ratedLifeHours['PROJECTOR'], 6000);
  });

  testWidgets('source names and excluded clients can be edited', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    await tester.enterText(textField('Source name, e.g. hdmi_2'), 'HDMI_2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, 2);
    expect(t.settings.analysisConfig.classifier.inputNames, contains('hdmi_2'));
    await tester.tap(find.byTooltip('Remove hdmi_2'));
    await pumpFrames(tester, 2);
    expect(t.settings.analysisConfig.classifier.inputNames, isNot(contains('hdmi_2')));

    await tester.enterText(textField('Client name to exclude'), 'TEST_LAB');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpFrames(tester, 2);
    expect(t.settings.excludeClients, {'AVSM-System', 'TEST_LAB'});
  });

  testWidgets('reset to defaults asks first', (tester) async {
    final t = await pumpApp(tester, size: settingsSize, initial: AppDestination.settings);
    await t.settings.setShowChartPatterns(false);
    await t.settings.setPalette(ChartPaletteKind.protanopia);
    await pumpFrames(tester, 2);
    await tester.tap(find.text('Reset to defaults'));
    await pumpFrames(tester, 3);
    expect(find.text('Reset all settings?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpFrames(tester, 3);
    expect(t.settings.showChartPatterns, isFalse);
    await tester.tap(find.text('Reset to defaults'));
    await pumpFrames(tester, 3);
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await pumpFrames(tester, 3);
    expect(t.settings.showChartPatterns, isTrue);
    expect(t.settings.palette, ChartPaletteKind.standard);
  });

  testWidgets('forget saved API token removes it and says where it was kept', (tester) async {
    final t = await pumpApp(
      tester,
      size: settingsSize,
      initial: AppDestination.settings,
      savedToken: 'test-token-0123456789abcdefghijklmnopqrstuv',
      prefs: const {'v1.rememberApiToken': true},
    );
    // Tests run as a desktop build.
    expect(find.text('An API token may be saved in the operating system credential store.'), findsOneWidget);
    await tester.tap(find.text('Forget saved API token'));
    await pumpFrames(tester, 3);
    expect(t.tokens.entry, isNull);
    expect(t.settings.rememberApiToken, isFalse);
    expect(find.text('API tokens are not saved.'), findsOneWidget);
  });
}
