import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_charts.dart';

import 'screens_a_helpers.dart';

Finder segment<T>(String label) => find.descendant(of: find.byType(SegmentedButton<T>), matching: find.text(label));

void main() {
  final dataset = demoDataset();

  group('Devices', () {
    testWidgets('KPIs, type chart and per-device table', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, AppDestination.devices, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Devices: 54\. 3 types')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Left on: 2\. sessions longer than 12 h')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^On-hours by device type\. Projector devices ran')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^On-hours by device\. .*the top 15 are drawn and the table lists all')),
        findsOneWidget,
      );
      // The device table lists all 54 devices (sortable DataTable).
      final card = find.ancestor(of: find.text('On-hours by device'), matching: find.byType(Card)).first;
      await tester.tap(find.descendant(of: card, matching: find.text('View as table')));
      await tester.pump();
      final table = tester.widget<DataTable>(find.descendant(of: card, matching: find.byType(DataTable)));
      expect(table.rows, hasLength(54));
      handle.dispose();
    });

    testWidgets('left-on sessions open the room; weekly/daily toggle', (tester) async {
      final h = await pumpScreen(tester, AppDestination.devices, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.text('Devices left on'), findsOneWidget);
      final leftOn = find.textContaining(RegExp('^${DemoScenario.deviceLeftOn} · .*: on for '));
      expect(leftOn, findsWidgets);

      await tester.tap(segment<bool>('Daily'));
      await tester.pump();
      expect(find.textContaining('Daily on-hours of the'), findsOneWidget);

      await tester.tap(leftOn.first);
      await tester.pump();
      expect(h.navigation.current, AppDestination.rooms);
      expect(h.navigation.selectedRoom, DemoScenario.deviceLeftOn);
    });

    testWidgets('device detail follows the chosen device', (tester) async {
      final h = await pumpScreen(tester, AppDestination.devices, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      final devices = h.app.analysis!.devices.devices;
      final busiest = devices.reduce((a, b) => b.onHours > a.onHours ? b : a);
      expect(find.text('Daily on-hours: ${busiest.room} · ${busiest.deviceId}'), findsOneWidget);
      final other = devices.firstWhere((d) => d.key != busiest.key && d.onHours > 0);
      tester.widget<DropdownMenu<String>>(find.byType(DropdownMenu<String>)).onSelected!(other.key);
      await tester.pump();
      expect(find.text('Daily on-hours: ${other.room} · ${other.deviceId}'), findsOneWidget);
      await tester.tap(find.text('Open room ${other.room}'));
      await tester.pump();
      expect(h.navigation.selectedRoom, other.room);
    });
  });

  group('System usage', () {
    testWidgets('heat map cells each have a label; table has every value', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, AppDestination.systemUsage, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.byType(HeatmapGrid), findsOneWidget);
      // 7 x 24 labelled cells.
      expect(
        find.bySemanticsLabel(
          RegExp(r'^(Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day \d+\s(AM|PM): \d+\.\d% of rooms in use$'),
        ),
        findsNWidgets(168),
      );
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Rooms in use by weekday and hour\. Busiest: \w+day at \d+\s(AM|PM), \d+\.\d% of rooms in use'),
        ),
        findsOneWidget,
      );

      final card = find.ancestor(of: find.text('Rooms in use by weekday and hour'), matching: find.byType(Card)).first;
      await tester.tap(find.descendant(of: card, matching: find.text('View as table')));
      await tester.pump();
      final table = tester.widget<DataTable>(find.descendant(of: card, matching: find.byType(DataTable)));
      expect(table.rows, hasLength(7));
      expect(table.columns, hasLength(25));
      expect(find.byType(HeatmapGrid), findsNothing);
      handle.dispose();
    });

    testWidgets('off reasons explain inactivity; utilization toggles most/least used', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, AppDestination.systemUsage, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.textContaining('were ended by the inactivity auto-off'), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp(r'^Why sessions ended\. Most sessions ended as "Turned off by user"')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Power-on time of day\. Most power-ons happen at')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Session length\. The most common session length is')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Utilization by room\. .*most used 15')), findsOneWidget);
      await tester.tap(segment<bool>('Least used'));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Utilization by room\. .*least used 15')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('heat map turns so hours run down the page on narrow screens', (tester) async {
      await pumpScreen(tester, AppDestination.systemUsage, dataset: dataset, size: narrow);
      await fitWholePage(tester);
      final grid = tester.getSize(find.byType(HeatmapGrid));
      expect(grid.height, greaterThan(grid.width));
    });
  });
}
