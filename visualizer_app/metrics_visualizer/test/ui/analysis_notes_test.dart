// Explanations and caveats added from the analytics review: device type
// overrides (ANA-08), the navigation pattern exclusions (ANA-11), session
// limits (ANA-03), automatic startup inputs (ANA-01), rooms without
// heartbeats (ANA-04/13), data quality warnings, and per-page titles.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/connectivity_screen.dart';
import 'package:metrics_visualizer/ui/screens/inputs_screen.dart';
import 'package:metrics_visualizer/ui/screens/overview_screen.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_cards.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_common.dart' show InputMeasure;
import 'package:metrics_visualizer/ui/screens/parts/b_charts.dart';
import 'package:metrics_visualizer/ui/screens/parts/device_type_note.dart';
import 'package:metrics_visualizer/ui/screens/settings_screen.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_b/screens_b_helpers.dart';

/// Tall enough for the whole Settings page, including the last cards.
const Size settingsTall = Size(1400, 9000);
const Size tall = Size(1400, 4000);

Finder textField(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField)).first;

/// [ds] with every heartbeat of [room] removed.
Dataset withoutHeartbeatsFor(Dataset ds, String room) => Dataset(
      events: ds.events,
      heartbeats: [
        for (final h in ds.heartbeats)
          if (h.clientName != room) h,
      ],
      rangeStart: ds.rangeStart,
      rangeEnd: ds.rangeEnd,
      origin: ds.origin,
      description: 'Demo with a silent room',
      heartbeatRetentionDays: ds.heartbeatRetentionDays,
    );

/// One room: power-on, the program's default source 5 s later (automatic),
/// then a person choosing HDMI.
Dataset startupDataset({List<String> warnings = const []}) {
  final t0 = DateTime.utc(2026, 11, 2, 9);
  MetricEvent e(Duration d, String metric, String action) =>
      MetricEvent(clientName: 'AUTO_101', timestamp: t0.add(d), metric: metric, action: action);
  return Dataset(
    events: [
      e(Duration.zero, 'System - User', 'Started'),
      e(const Duration(seconds: 5), 'pc', 'Started'),
      e(const Duration(minutes: 30), 'hdmi', 'Started'),
      e(const Duration(minutes: 60), 'System - User', 'Stopped'),
    ],
    heartbeats: const [],
    rangeStart: DateTime.utc(2026, 11, 2),
    rangeEnd: DateTime.utc(2026, 11, 3),
    origin: DatasetOrigin.csv,
    description: 'startup.csv',
    warnings: warnings,
  );
}

RoomConnectivity roomConn({DateTime? lastEvent, DateTime? lastHeartbeatHour, DateTime? lastSeen, double? online}) =>
    RoomConnectivity(
      room: 'R_1',
      building: 'R',
      connects: 0,
      disconnects: 0,
      targets: const [],
      daily: const [],
      onlineFraction: online,
      onlineHours: 0,
      coveredHours: 0,
      dailyOnline: const [],
      offlinePeriods: const [],
      lastSeen: lastSeen,
      lastEvent: lastEvent,
      lastHeartbeatHour: lastHeartbeatHour,
    );

void main() {
  group('device type overrides (ANA-08)', () {
    testWidgets('can be added, replaced case-insensitively and removed', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      expect(find.text('Device types for particular devices'), findsOneWidget);
      expect(find.textContaining('No overrides.'), findsOneWidget);

      // A key without a room and a slash is rejected in text.
      await tester.enterText(textField('Room and device'), 'Projector_1');
      await tester.tap(find.text('Add override'));
      await tester.pump();
      expect(find.textContaining('Use the form room/device'), findsOneWidget);
      expect(t.settings.analysisConfig.deviceTypeOverrides, isEmpty);

      await tester.enterText(textField('Room and device'), 'BSS_112/Projector_1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(t.settings.analysisConfig.deviceTypeOverrides, {'BSS_112/Projector_1': 'DISPLAY'});
      expect(find.text('BSS_112/Projector_1 is treated as Display'), findsOneWidget);
      expect(find.textContaining('Use the form room/device'), findsNothing);

      // Same device in another case with another type replaces the entry.
      final menu = find.byWidgetPredicate((w) => w is AppDropdownMenu<String> && w.label == 'Device type');
      tester.widget<AppDropdownMenu<String>>(menu).onSelected('CAMERA');
      await tester.pump();
      await tester.enterText(textField('Room and device'), 'bss_112/projector_1');
      await tester.tap(find.text('Add override'));
      await tester.pump();
      expect(t.settings.analysisConfig.deviceTypeOverrides, {'bss_112/projector_1': 'CAMERA'});

      await tester.tap(find.byTooltip('Remove override for bss_112/projector_1'));
      await tester.pump();
      expect(t.settings.analysisConfig.deviceTypeOverrides, isEmpty);
      expect(find.textContaining('No overrides.'), findsOneWidget);
    });

    testWidgets('removing an override by keyboard moves focus to the next row, then to the entry field',
        (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await t.settings.setAnalysisConfig(t.settings.analysisConfig
          .copyWith(deviceTypeOverrides: {'A_1/Projector_1': 'DISPLAY', 'B_1/Projector_1': 'DISPLAY'}));
      await pumpFrames(tester, 2);
      FocusNode node(String key) => tester
          .widget<IconButton>(
              find.ancestor(of: find.byTooltip('Remove override for $key'), matching: find.byType(IconButton)))
          .focusNode!;

      node('A_1/Projector_1').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.deviceTypeOverrides.keys, ['B_1/Projector_1']);
      expect(node('B_1/Projector_1').hasFocus, isTrue);
      expect(takeAnnouncementTexts(tester), contains('Override for A_1/Projector_1 removed.'));

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester, 2);
      expect(t.settings.analysisConfig.deviceTypeOverrides, isEmpty);
      final field = tester.widget<TextField>(textField('Room and device'));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('settings page with overrides meets accessibility guidelines', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      await t.settings.setAnalysisConfig(
          t.settings.analysisConfig.copyWith(deviceTypeOverrides: {'BSS_112/Projector_1': 'DISPLAY'}));
      await pumpFrames(tester, 2);
      expect(find.byTooltip('Remove override for BSS_112/Projector_1'), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);
    });

    testWidgets('Devices and Forecast explain Projector_N naming and link to Settings', (tester) async {
      final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.devices, size: tall);
      expect(find.text(ProjectorNamingNote.title), findsOneWidget);
      expect(find.textContaining('flat panels included, as Projector_N'), findsOneWidget);
      await tester.tap(find.text('Set device types in Settings'));
      await tester.pump();
      expect(t.navigation.current, AppDestination.settings);

      t.navigation.goTo(AppDestination.forecast);
      await settleWork(tester, t);
      expect(find.text(ProjectorNamingNote.title), findsOneWidget);
      expect(find.textContaining('No device type overrides are set yet.'), findsOneWidget);
    });

    test('the note is only for data with Projector_N devices', () {
      expect(hasProjectorNamedDevices(['Projector_1', 'Camera_1']), isTrue);
      expect(hasProjectorNamedDevices(['PROJECTOR2']), isTrue);
      expect(hasProjectorNamedDevices(['Display_1', 'Camera_1']), isFalse);
    });
  });

  group('settings explanations', () {
    testWidgets('navigation pattern exclusions and the 7-day session rule are explained (ANA-11, ANA-03)',
        (tester) async {
      await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      expect(find.textContaining('Btn_Start_Page (the power-on button)'), findsOneWidget);
      expect(find.textContaining('Btn_Std_Backlight) are deliberately left out'), findsOneWidget);
      expect(
        find.textContaining("A device's real off event up to ${SessionBuilder.deviceHardLimit.inDays} days after"),
        findsOneWidget,
      );
      // Long helper text wraps instead of being cut off at 200% text.
      for (final label in ['Longest believable session', 'Navigation button pattern', 'Room and device']) {
        final decoration = tester.widget<TextField>(textField(label)).decoration!;
        expect(decoration.helperMaxLines, settingsTextMaxLines, reason: label);
        expect(decoration.errorMaxLines, settingsTextMaxLines, reason: label);
      }
    });

    testWidgets('settings render without overflow in a narrow window at 200% text', (tester) async {
      await pumpApp(tester, size: const Size(400, 9000), textScale: 2.0, initial: AppDestination.settings);
      final t = find.text('Device types for particular devices');
      await tester.scrollUntilVisible(t, 400,
          scrollable: find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Add override'), findsOneWidget);
    });

    testWidgets('a non-blocking hint appears when "Device left on after" reaches the session limit', (tester) async {
      final t = await pumpApp(tester, size: settingsTall, initial: AppDestination.settings);
      const hint = 'is at or above "Longest believable session"';
      expect(find.textContaining(hint), findsNothing);

      await tester.enterText(textField('Device left on after'), '16');
      await pumpFrames(tester, 2);
      // Saved as entered (not blocked) and explained.
      expect(t.settings.analysisConfig.thresholds.deviceLeftOnHours, 16);
      expect(find.textContaining(hint), findsOneWidget);
      expect(find.text('Must be from 1 to 168.'), findsNothing);
      await expectMeetsA11yGuidelines(tester);

      await tester.enterText(textField('Longest believable session'), '24');
      await pumpFrames(tester, 2);
      expect(find.textContaining(hint), findsNothing);
    });
  });

  group('automatic startup input (ANA-01)', () {
    testWidgets('is left out of selections but kept in time on screen, and explained', (tester) async {
      final t = await pumpWithData(tester, dataset: startupDataset(), initial: AppDestination.inputs, size: tall);
      final a = t.app.analysis!;
      expect(automaticSelections(a, a.rooms), 1);
      final pc = a.inputs.campus.firstWhere((s) => s.key == 'pc');
      final hdmi = a.inputs.campus.firstWhere((s) => s.key == 'hdmi');
      expect(pc.selections, 0);
      expect(pc.hours, greaterThan(0.4));
      expect(hdmi.selections, 1);

      expect(find.textContaining('times someone chose an input; 1 startup default not counted'), findsOneWidget);
      await scrollTo(tester, find.text('How inputs are counted'));
      expect(find.textContaining('is not counted as a user selection'), findsOneWidget);
      expect(find.textContaining('It still counts toward time on screen.'), findsOneWidget);
      expect(find.textContaining('1 startup selection was left out of the selection counts'), findsOneWidget);
    });

    test('an empty selection chart says only the startup default was on screen', () {
      const shares = [
        InputShare(key: 'pc', label: 'PC', selections: 0, selectionShare: 0, hours: 2, timeShare: 1, roomCount: 1),
      ];
      expect(noInputMessage(shares, InputMeasure.selections, 'all rooms'), contains('Only the startup default'));
      expect(noInputMessage(const [], InputMeasure.selections, 'all rooms'), contains('No video input was selected'));
    });
  });

  group('rooms without heartbeats (ANA-04/13)', () {
    testWidgets('show "No heartbeats" in the chart, the table and the CSV, never 0%', (tester) async {
      final base = demoDataset(2);
      final silent = base.heartbeats.first.clientName;
      final t = await pumpWithData(tester,
          dataset: withoutHeartbeatsFor(base, silent), initial: AppDestination.connectivity, size: tall);
      final room = t.app.analysis!.connectivity.rooms.firstWhere((r) => r.room == silent);
      expect(room.onlineFraction, isNull);

      expect(find.textContaining('Each room is measured from its first heartbeat or event'), findsOneWidget);
      await scrollTo(tester, find.text('Processor online time per room'));
      final bars = tester.widget<LabeledBarList>(find.byType(LabeledBarList));
      final item = bars.items.singleWhere((i) => i.label == silent);
      expect(item.valueText, noHeartbeatsText);
      expect(item.fraction, 0);

      final card = tester.widget<AccessibleChartCard>(find.ancestor(
          of: find.text('Processor online time per room'), matching: find.byType(AccessibleChartCard)));
      expect(card.summary, contains('no heartbeats'));
      final row = card.table.rows.singleWhere((r) => r.first == silent);
      expect(row[2], noHeartbeatsText);
      final csvLine = card.table.toCsv().split('\n').singleWhere((l) => l.startsWith('$silent,'));
      expect(csvLine, contains(noHeartbeatsText));
      expect(card.table.toCsv().split('\n').first, contains('Last seen precision'));
      await expectMeetsA11yGuidelines(tester);
    });

    testWidgets('hour-granular last-seen times are labelled', (tester) async {
      final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.connectivity, size: tall);
      final rooms = t.app.analysis!.connectivity.rooms;
      expect(rooms.where(lastSeenIsHourly), isNotEmpty);
      await scrollTo(tester, find.text('Processor online time per room'));
      final card = tester.widget<AccessibleChartCard>(find.ancestor(
          of: find.text('Processor online time per room'), matching: find.byType(AccessibleChartCard)));
      final hourly = rooms.firstWhere(lastSeenIsHourly);
      final row = card.table.rows.singleWhere((r) => r.first == hourly.room);
      expect(row[6], startsWith('During the hour starting'));
      expect(row[7], 'Hour (heartbeat)');
    });

    test('last-seen wording follows the source of the time', () {
      final fmt = Fmt(utc: true);
      final ev = DateTime.utc(2026, 11, 2, 9, 41);
      final hb = DateTime.utc(2026, 11, 2, 10);
      final fromHeartbeat = roomConn(lastEvent: ev, lastHeartbeatHour: hb, lastSeen: hb);
      expect(lastSeenIsHourly(fromHeartbeat), isTrue);
      expect(lastSeenText(fromHeartbeat, fmt), startsWith('During the hour starting'));
      expect(lastSeenPrecision(fromHeartbeat), 'Hour (heartbeat)');

      final fromEvent = roomConn(lastEvent: ev, lastHeartbeatHour: DateTime.utc(2026, 11, 2, 9), lastSeen: ev);
      expect(lastSeenIsHourly(fromEvent), isFalse);
      expect(lastSeenText(fromEvent, fmt), isNot(contains('hour')));
      expect(lastSeenPrecision(fromEvent), 'Exact (event)');

      final never = roomConn();
      expect(lastSeenText(never, fmt), 'Never');
      expect(lastSeenPrecision(never), '');
    });
  });

  group('data quality on the Overview', () {
    testWidgets('warnings are shown near the top, notes at the end', (tester) async {
      const warning = 'Dates in this file are written day first (DD/MM/YYYY), as saved by a spreadsheet.';
      final t = await pumpWithData(tester,
          dataset: startupDataset(warnings: [warning]), initial: AppDestination.overview, size: tall);
      expect(t.app.analysis!.dataQuality.warnings, [warning]);
      expect(find.text(DataWarningsCard.title), findsOneWidget);
      expect(find.text(warning), findsOneWidget);
      await scrollTo(tester, find.text(DataQualityCard.title));
      expect(find.textContaining('1 warning is listed under'), findsOneWidget);
      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(t.navigation.current, AppDestination.settings);
    });

    testWidgets('a clean dataset says nothing had to be corrected', (tester) async {
      await pumpWithData(tester, dataset: startupDataset(), initial: AppDestination.overview, size: tall);
      expect(find.text(DataWarningsCard.title), findsNothing);
      await scrollTo(tester, find.text(DataQualityCard.title));
      expect(find.textContaining('nothing had to be skipped or corrected'), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);
    });
  });

  testWidgets('each page sets its own title (browser tab on the web)', (tester) async {
    final t = await pumpApp(tester, initial: AppDestination.settings);
    expect(tester.widget<Title>(find.byType(Title).last).title, 'Settings · AV Metrics Visualizer');
    t.navigation.goTo(AppDestination.about);
    await pumpFrames(tester, 2);
    expect(tester.widget<Title>(find.byType(Title).last).title, 'About · AV Metrics Visualizer');
    expect(find.byType(SettingsScreen), findsNothing);
  });
}
