// Non-happy paths and extremes: no data, analysis in progress, filters that
// match nothing, tiny and heartbeat-only datasets, large datasets and
// motion on/off.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_charts.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_a_helpers.dart';

const destinations = [
  AppDestination.overview,
  AppDestination.inputs,
  AppDestination.devices,
  AppDestination.systemUsage,
  AppDestination.rooms,
];

void main() {
  for (final d in destinations) {
    testWidgets('${d.name}: no data points to the data source page', (tester) async {
      final h = await pumpScreen(tester, d);
      expect(find.text('No data loaded'), findsWidgets);
      await tester.tap(find.text('Choose a data source'));
      await tester.pump();
      expect(h.navigation.current, AppDestination.dataSource);
    });

    testWidgets('${d.name}: shows progress while the first analysis runs', (tester) async {
      final pending = Completer<AnalysisOutcome>();
      await pumpScreen(tester, d, dataset: tinyDataset(), analysisRunner: (_) => pending.future);
      expect(find.text('Analysing data…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${d.name}: filters that match nothing offer to clear them', (tester) async {
      final h = await pumpScreen(tester, d, dataset: demoDataset());
      h.app.setCustomWindow(DateTime.utc(2020, 1, 1), DateTime.utc(2020, 1, 2));
      await settle(tester, h);
      expect(find.text('No rooms match the current filters'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(EmptyState), matching: find.text('Clear filters')));
      await settle(tester, h);
      expect(find.text('No rooms match the current filters'), findsNothing);
      expect(h.app.analysis!.rooms, hasLength(24));
    });

    for (final size in [wide, narrow]) {
      testWidgets('${d.name}: a one-room, one-session dataset renders (${size.width.toInt()} wide, 2x text)', (
        tester,
      ) async {
        await pumpScreen(tester, d, dataset: tinyDataset(), size: size, textScale: 2.0);
        expect(find.text('No rooms match the current filters'), findsNothing);
        await scrollThroughPage(tester);
      });
    }

    testWidgets('${d.name}: rooms with heartbeats only render explanations, not empty charts', (tester) async {
      await pumpScreen(tester, d, dataset: heartbeatOnlyDataset(), size: extraWide, room: 'HB_100');
      await fitWholePage(tester);
      expect(tester.takeException(), isNull);
      switch (d) {
        case AppDestination.devices:
          expect(find.text('No device activity in this period'), findsOneWidget);
        case AppDestination.inputs:
          expect(find.textContaining('No source selections were logged in all rooms'), findsWidgets);
        case AppDestination.systemUsage:
          expect(find.textContaining('No power-ons were recorded'), findsOneWidget);
        case AppDestination.overview:
          expect(find.textContaining('No patterns were found'), findsOneWidget);
        case _:
          expect(find.text('Room HB_100'), findsOneWidget);
      }
    });

    testWidgets('${d.name}: ten weeks of the demo campus render', (tester) async {
      await pumpScreen(tester, d, dataset: demoDataset(weeks: 10), size: extraWide);
      await scrollThroughPage(tester);
    });

    testWidgets('${d.name}: 320 rooms render on a narrow screen', (tester) async {
      await pumpScreen(tester, d, dataset: manyRoomsDataset(), size: narrow);
      await scrollThroughPage(tester);
    });
  }

  testWidgets('charts animate in when motion is allowed and settle without errors', (tester) async {
    await pumpScreen(tester, AppDestination.overview, dataset: demoDataset(), reduceMotion: false);
    expect(
      find.descendant(of: find.byType(ChartEntrance), matching: find.byType(TweenAnimationBuilder<double>)),
      findsWidgets,
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion shows charts in their final state with no animation', (tester) async {
    await pumpScreen(tester, AppDestination.overview, dataset: demoDataset(), reduceMotion: true);
    expect(find.byType(ChartEntrance), findsWidgets);
    expect(
      find.descendant(of: find.byType(ChartEntrance), matching: find.byType(TweenAnimationBuilder<double>)),
      findsNothing,
    );
  });

  testWidgets('hour-of-day charts name the analysis time zone', (tester) async {
    final h = await pumpScreen(tester, AppDestination.systemUsage, dataset: demoDataset(), size: extraWide);
    expect(h.app.analysis!.timeZoneLabel, 'UTC');
    await fitWholePage(tester);
    expect(find.textContaining('Times in UTC'), findsWidgets);
  });
}
