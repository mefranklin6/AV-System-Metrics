// Settings > Event recognition (every ClassifierConfig field), the Data
// quality list of unmatched events, the room timeline's recognized
// categories and the "other" power-off reasons, as described in
// Implementation_Guide.md ("Matching an existing program" and "Checking
// your implementation").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/state/settings_state.dart';
import 'package:metrics_visualizer/ui/screens/overview_screen.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_room_detail.dart';
import 'package:metrics_visualizer/ui/screens/settings_screen.dart';
import 'package:metrics_visualizer/ui/screens/system_usage_screen.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_b/screens_b_helpers.dart';

/// Tall enough to build the whole Settings page.
const Size settingsTall = Size(1400, 14000);
const Size tall = Size(1400, 4000);

Finder textField(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField)).first;

Finder listEditor(String label) => find.byWidgetPredicate((w) => w is StringListEditor && w.label == label);

/// One room, SCI-101, from a program that logs its own names:
/// `Room Power - <reason>` for system power, plus one guide-style source,
/// an unmatched custom event and a help-labelled press.
Dataset customProgramDataset() {
  final t0 = DateTime.utc(2026, 11, 2, 9);
  MetricEvent e(Duration d, String metric, String action) =>
      MetricEvent(clientName: 'SCI-101', timestamp: t0.add(d), metric: metric, action: action);
  return Dataset(
    events: [
      e(Duration.zero, 'Room Power - Panel', 'Started'),
      e(const Duration(minutes: 1), 'Source - HDMI 1', 'Started'),
      e(const Duration(minutes: 5), 'Lights Preset 2', 'Recalled'),
      e(const Duration(minutes: 6), 'Help Pressed', 'Trace'),
      e(const Duration(minutes: 7), 'Btn_Nav_Display Pressed', 'Trace'),
      e(const Duration(minutes: 50), 'Room Power - Idle', 'Stopped'),
      e(const Duration(hours: 2), 'System Power - User', 'Started'),
      e(const Duration(hours: 3), 'System Power - Fire Alarm', 'Stopped'),
    ],
    heartbeats: const [],
    rangeStart: DateTime.utc(2026, 11, 2),
    rangeEnd: DateTime.utc(2026, 11, 3),
    origin: DatasetOrigin.csv,
    description: 'custom.csv',
  );
}

void main() {
  group('Event recognition settings', () {
    testWidgets('shows every recognition field with its default and the guide address', (tester) async {
      await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      expect(find.text('Event recognition'), findsOneWidget);
      for (final label in [
        'System power names',
        'Reasons grouped as User',
        'Reasons grouped as Schedule',
        'Reasons grouped as Inactivity',
        'Reasons grouped as Remote',
        'Reasons grouped as Restore',
        'Startup complete names',
        'Shutdown complete names',
        'Program start names',
        'Source prefixes',
        'Source names',
      ]) {
        expect(listEditor(label), findsOneWidget, reason: label);
      }
      for (final label in ['Device pattern', 'Navigation pattern', 'Repeatable control pattern', 'Help pattern', 'Building pattern']) {
        expect(textField(label), findsOneWidget, reason: label);
      }
      expect(find.text('Device type overrides'), findsOneWidget);
      expect(find.text('Default: ${ClassifierConfig.defaultSystemPowerNames.join(', ')}'), findsOneWidget);
      expect(find.text(implementationGuideUrl), findsOneWidget);
      // The recognition groups are headings.
      final handle = tester.ensureSemantics();
      for (final h in ['System power', 'Program start', 'Sources', 'Devices', 'Controls', 'Rooms and buildings']) {
        final node = tester.getSemantics(find.descendant(of: find.byType(SettingsScreen), matching: find.text(h)).first);
        expect(node.flagsCollection.isHeader, isTrue, reason: h);
      }
      handle.dispose();
    });

    testWidgets('a name can be added and removed, and the list reset to its default', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await tester.enterText(textField('System power name'), 'Room Power');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.classifier.systemPowerNames, [...ClassifierConfig.defaultSystemPowerNames, 'Room Power']);
      expect(takeAnnouncementTexts(tester), contains('Room Power added.'));

      await tester.tap(find.byTooltip('Remove System'));
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.classifier.systemPowerNames, ['System Power', 'Room Power']);

      await tester.tap(find.text('Reset system power names to default'));
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.classifier.systemPowerNames, ClassifierConfig.defaultSystemPowerNames);
      expect(takeAnnouncementTexts(tester), contains('System power names reset to the default.'));
      expect(find.text('Reset system power names to default'), findsNothing);
    });

    testWidgets('power reason synonyms are edited per group', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await tester.enterText(textField('Inactivity reason'), 'Vacancy');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpFrames(tester, 2);
      final synonyms = t.settings.analysisConfig.classifier.powerReasonSynonyms;
      expect(synonyms['inactivity'], contains('Vacancy'));
      expect(synonyms['user'], ClassifierConfig.defaultPowerReasonSynonyms['user']);
    });

    testWidgets('a change that leaves no way to recognize sources is refused and announced', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await t.settings.setAnalysisConfig(t.settings.analysisConfig
          .copyWith(classifier: const ClassifierConfig(inputNames: [], sourcePrefixes: ['Source -'])));
      await pumpFrames(tester, 2);
      tester.takeAnnouncements();
      await tester.tap(find.byTooltip('Remove Source -'));
      await pumpFrames(tester, 2);
      const error = 'Add at least one source prefix or source name.';
      expect(t.settings.analysisConfig.classifier.sourcePrefixes, ['Source -']);
      expect(find.text(error), findsOneWidget);
      expect(takeAnnouncementTexts(tester), contains('Source prefix: $error'));
    });

    testWidgets('an invalid pattern is shown, announced and not applied; the default can be restored',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      tester.takeAnnouncements();
      await tester.enterText(textField('Help pattern'), '(help');
      await pumpFrames(tester, 2);
      expect(find.textContaining('not a valid regular expression'), findsOneWidget);
      expect(t.settings.analysisConfig.classifier.helpPattern, ClassifierConfig.defaultHelpPattern);
      expect(takeAnnouncementTexts(tester).any((a) => a.startsWith('Help pattern: This is not a valid')), isTrue);

      await tester.enterText(textField('Help pattern'), r'\bassist\b');
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.classifier.helpPattern, r'\bassist\b');

      await tester.tap(find.byTooltip('Reset Help pattern to default'));
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.classifier.helpPattern, ClassifierConfig.defaultHelpPattern);
    });

    testWidgets('reset event recognition asks first and keeps device type overrides', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await t.settings.setAnalysisConfig(t.settings.analysisConfig.copyWith(
        classifier: const ClassifierConfig(programStartNames: ['Boot']),
        deviceTypeOverrides: {'SCI-101/Projector 1': 'DISPLAY'},
      ));
      await pumpFrames(tester, 2);
      await tester.tap(find.text('Reset event recognition to defaults'));
      await pumpFrames(tester, 3);
      expect(find.text('Reset event recognition?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await pumpFrames(tester, 3);
      expect(t.settings.analysisConfig.classifier.programStartNames, ClassifierConfig.defaultProgramStartNames);
      expect(t.settings.analysisConfig.deviceTypeOverrides, {'SCI-101/Projector 1': 'DISPLAY'});
    });

    testWidgets('edits are saved and reloaded', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await tester.enterText(textField('Program start name'), 'Boot Complete');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.enterText(textField('Navigation pattern'), r'(^|_)Page(_|$)');
      await pumpFrames(tester, 2);
      final reloaded = await SettingsState.load();
      expect(reloaded.analysisConfig.classifier.programStartNames, contains('Boot Complete'));
      expect(reloaded.analysisConfig.classifier.navigationButtonPattern, r'(^|_)Page(_|$)');
      expect(reloaded.analysisConfig.classifier.toJson(), t.settings.analysisConfig.classifier.toJson());
    });

    testWidgets('a name added in Settings changes the analysis', (tester) async {
      final t = await pumpWithData(tester, dataset: customProgramDataset(), initial: AppDestination.settings, size: settingsTall);
      final before = t.app.analysis!;
      // Only the guide-style session is recognized at first.
      expect(before.system.offReasons[OffReason.inactivity] ?? 0, 0);
      expect(before.dataQuality.unclassified.any((m) => m.metric == 'Room Power - Panel'), isTrue);

      await tester.enterText(textField('System power name'), 'Room Power');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleWork(tester, t);
      final after = t.app.analysis!;
      expect(after.system.offReasons[OffReason.inactivity], 1);
      expect(after.dataQuality.unclassified.any((m) => m.metric.startsWith('Room Power')), isFalse);
      expect(after.system.totalHours, greaterThan(before.system.totalHours));
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('meets accessibility guidelines (${mode.name})', (tester) async {
        final t = await pumpApp(tester, themeMode: mode, initial: AppDestination.settings);
        t.navigation.openSettings(SettingsSection.eventRecognition);
        await pumpFrames(tester, 12);
        expect(find.text('System power names'), findsOneWidget);
        await expectMeetsA11yGuidelines(tester);
        t.navigation.openSettings(SettingsSection.deviceTypeOverrides);
        await pumpFrames(tester, 12);
        await expectMeetsA11yGuidelines(tester);
      });
    }

    testWidgets('reflows at 320 px with 200% text and meets the guidelines', (tester) async {
      final t = await pumpApp(tester, size: const Size(320, 640), textScale: 2.0, initial: AppDestination.settings);
      t.navigation.openSettings(SettingsSection.eventRecognition);
      await pumpFrames(tester, 12);
      expect(tester.takeException(), isNull);
      final scrollable = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
      for (final target in ['Source prefixes', 'Help pattern', 'Building pattern']) {
        await tester.scrollUntilVisible(find.text(target), 300, scrollable: scrollable);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: target);
        await expectMeetsA11yGuidelines(tester);
      }
    });
  });

  group('Data quality lists unmatched events', () {
    testWidgets('as a table with links to Event recognition and the guide', (tester) async {
      final t = await pumpWithData(tester, dataset: customProgramDataset(), initial: AppDestination.overview, size: tall);
      await scrollTo(tester, find.text(DataQualityCard.unmatchedTitle));
      expect(find.text('Lights Preset 2'), findsOneWidget);
      expect(find.text('Recalled'), findsOneWidget);
      expect(find.text(implementationGuideUrl), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);

      await tester.tap(find.text('Open Event recognition settings'));
      await pumpFrames(tester, 12);
      expect(t.navigation.current, AppDestination.settings);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Settings Event recognition');
      expect(takeAnnouncementTexts(tester), contains('Showing Event recognition settings.'));
    });
  });

  group('Room timeline shows what each event was recognized as', () {
    testWidgets('categories and details appear for every event', (tester) async {
      final t = await pumpWithData(tester, dataset: customProgramDataset(), initial: AppDestination.rooms, size: tall);
      t.navigation.goTo(AppDestination.rooms, room: 'SCI-101');
      await settleWork(tester, t);
      await scrollTo(tester, find.byKey(EventTimeline.focusKey));
      expect(find.textContaining('Recognized as Source: source "HDMI 1"'), findsOneWidget);
      expect(find.textContaining('Recognized as Help-labelled'), findsOneWidget);
      expect(find.textContaining('Recognized as Control: navigation'), findsOneWidget);
      expect(find.textContaining('Recognized as System power: reason "Fire Alarm" (in no reason group)'), findsOneWidget);
      expect(find.textContaining('Recognized as System power: reason group User'), findsOneWidget);
      expect(find.textContaining('Recognized as Not recognized (matched no rule)'), findsWidgets);
      await expectMeetsA11yGuidelines(tester);
    });

    test('recognizedAs describes the classification', () {
      final c = MetricClassifier();
      expect(EventTimeline.recognizedAs(c.classify('Projector 1', 'Started')), 'Device power: type PROJECTOR');
      expect(EventTimeline.recognizedAs(c.classify('Program Start', 'Started')), 'Processor lifecycle: program start');
      expect(EventTimeline.recognizedAs(c.classify('System Power', 'Stopped')), 'System power: no reason logged');
      expect(EventTimeline.recognizedAs(c.classify('System - Scheduled', 'Stopped')), 'System power: reason group Schedule');
      expect(EventTimeline.recognizedAs(c.classify('Volume Up Pressed', 'Trace')), 'Control: repeatable');
      expect(EventTimeline.recognizedAs(c.classify('Custom Thing', 'Done')), 'Not recognized (matched no rule)');
    });
  });

  group('System usage shows other power-off reasons as logged', () {
    testWidgets('in a chart with a table', (tester) async {
      await pumpWithData(tester, dataset: customProgramDataset(), initial: AppDestination.systemUsage, size: tall);
      await scrollTo(tester, find.text(OtherOffReasonsCard.title));
      expect(find.textContaining('reason outside the standard groups'), findsWidgets);
      final card = find.ancestor(of: find.text(OtherOffReasonsCard.title), matching: find.byType(AccessibleChartCard));
      expect(find.descendant(of: card, matching: find.text('Fire Alarm')), findsWidgets);
      await tester.tap(find.descendant(of: card, matching: find.text('View as table')));
      await pumpFrames(tester, 3);
      expect(find.descendant(of: card, matching: find.text('Reason as logged')), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);
    });
  });
}
