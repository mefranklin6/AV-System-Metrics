import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_charts.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_table.dart';

import 'screens_b_helpers.dart';

const Size tall = Size(1400, 4000);

void main() {
  testWidgets('shows the timeline, coverage with retention, online % and flapping callout', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.connectivity, size: tall);
    final c = t.app.analysis!.connectivity;
    expect(c.events, isNotEmpty);
    expect(c.hasHeartbeatCoverage, isTrue);

    expect(find.text('Connections and disconnections per day'), findsOneWidget);
    expect(find.byType(StackedBarChart), findsOneWidget);
    expect(find.text('What the online figures cover'), findsOneWidget);
    // Retention days from the data source are shown.
    expect(find.textContaining('keeps heartbeats for ${c.retentionDays} days'), findsWidgets);
    // Flapping devices are called out in words.
    expect(find.textContaining('unstable connection'), findsWidgets);
    await scrollTo(tester, find.text('Processor online time per room'));
    expect(find.byType(LabeledBarList), findsOneWidget);
    // The chart summary mentions the lowest room.
    final lowest = [...c.rooms.where((r) => r.onlineFraction != null)]
      ..sort((a, b) => a.onlineFraction!.compareTo(b.onlineFraction!));
    expect(find.textContaining('Lowest: ${lowest.first.room}'), findsOneWidget);
  });

  testWidgets('online % sorting and the event log view work', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.connectivity, size: tall);
    final c = t.app.analysis!.connectivity;

    await scrollTo(tester, find.text('Highest first'));
    await tester.tap(find.text('Highest first'));
    await tester.pump();
    final bars = tester.widget<LabeledBarList>(find.byType(LabeledBarList));
    final fractions = [for (final i in bars.items) i.fraction];
    expect(fractions, orderedEquals([...fractions]..sort((a, b) => b.compareTo(a))));

    await scrollTo(tester, find.text('Event log'));
    await tester.tap(find.text('Event log'));
    await tester.pump();
    final table = tester.widget<SortableTable>(find.byKey(const ValueKey('conn-log')));
    expect(table.rows.length, c.events.length);
  });

  testWidgets('copies the connection events as CSV', (tester) async {
    final clipboard = ClipboardSpy(tester);
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.connectivity, size: tall);
    final c = t.app.analysis!.connectivity;
    await scrollTo(tester, find.text('Event log'));
    await tester.tap(find.text('Event log'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Copy as CSV').first);
    await tester.pump();
    final lines = clipboard.text!.trim().split('\n');
    expect(lines.first, 'Time,Room,Device,Event');
    expect(lines.length, c.events.length + 1);
  });

  testWidgets('offline periods link to the room', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.connectivity, size: tall);
    final periods = [for (final r in t.app.analysis!.connectivity.rooms) ...r.offlinePeriods];
    expect(periods, isNotEmpty);
    final room = periods.first.room;
    final button = find.widgetWithText(TextButton, 'Open $room');
    await scrollTo(tester, button);
    await tester.tap(button.first);
    expect(t.navigation.current, AppDestination.rooms);
    expect(t.navigation.selectedRoom, room);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('explains missing heartbeats and connection events (${mode.name})', (tester) async {
      final t = await pumpWithData(tester,
          dataset: withoutConnectivity(demoDataset(2)),
          initial: AppDestination.connectivity,
          size: tall,
          themeMode: mode);
      final c = t.app.analysis!.connectivity;
      expect(c.events, isEmpty);
      // Room events still count as signs of life, but without heartbeats the
      // coverage is only what those events provide.
      expect(find.text('No connection events in this range'), findsOneWidget);
      expect(find.text('Connections and disconnections per day'), findsNothing);
      if (!c.hasHeartbeatCoverage) {
        expect(find.text('No heartbeat data in this range'), findsOneWidget);
        expect(find.text('Processor online time per room'), findsNothing);
      }
      await expectMeetsA11yGuidelines(tester);
      await scrollThroughPage(tester);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a quiet dataset without heartbeats renders both explanations', (tester) async {
    final t = await pumpWithData(tester, dataset: quietDataset(), initial: AppDestination.connectivity, size: tall);
    expect(t.app.analysis!.connectivity.hasHeartbeatCoverage, isFalse);
    expect(find.text('No heartbeat data in this range'), findsOneWidget);
    expect(find.text('No connection events in this range'), findsOneWidget);
    expect(find.text('No data'), findsWidgets);
    await expectMeetsA11yGuidelines(tester);
  });
}
