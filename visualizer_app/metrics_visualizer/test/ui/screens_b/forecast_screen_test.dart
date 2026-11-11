import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/filters.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_charts.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_table.dart';
import 'package:metrics_visualizer/ui/widgets/accessible_chart_card.dart';

import 'screens_b_helpers.dart';

const Size tall = Size(1400, 4000);

void main() {
  testWidgets('shows the replacement table, projection chart and input trends', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.forecast, size: tall);
    final f = t.app.analysis!.forecast;
    expect(f.hasEnoughData, isTrue);
    expect(find.text('Not enough data for trends yet'), findsNothing);

    // Table rows = devices; the first row (soonest) shows a projected date.
    final table = tester.widget<SortableTable>(
        find.descendant(of: find.byType(Card), matching: find.byType(SortableTable)).first);
    expect(table.rows.length, f.devices.length);
    expect(table.rows.first[0], f.devices.first.deviceId);
    expect(table.rows.first[7], isNot(anyOf('Not enough data', 'No rated life set')));
    expect(table.rows.first[9], isIn(['High', 'Medium', 'Low']));

    // The chart defaults to the first device with a trend.
    final first = f.devices.firstWhere((d) => d.fit != null);
    expect(find.text('Cumulative hours: ${first.deviceId} in ${first.room}'), findsOneWidget);
    expect(find.byType(TrendLineChart), findsWidgets);
    expect(find.textContaining('rated life'), findsWidgets);

    // Horizon switch changes the summary.
    final card = find.ancestor(
        of: find.text('Cumulative hours: ${first.deviceId} in ${first.room}'),
        matching: find.byType(AccessibleChartCard));
    String summary() => tester.widget<AccessibleChartCard>(card).summary;
    expect(summary(), contains('in 3 years'));
    await tester.tap(find.text('5 years'));
    await tester.pump();
    expect(summary(), contains('in 5 years'));

    // Source trends: a chart and statements in words, grouped by direction.
    await scrollTo(tester, find.text('Source selections per week'));
    expect(find.textContaining('Weekly selections of the'), findsOneWidget);
    await scrollTo(tester, find.text('Source usage trends'));
    expect(find.text(f.inputs.first.explanation), findsOneWidget);
    expect(find.textContaining('Growing ('), findsOneWidget);
  });

  testWidgets('choosing another device updates the chart', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.forecast, size: tall);
    final f = t.app.analysis!.forecast;
    final other = f.devices.lastWhere((d) => d.fit != null);
    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('${other.deviceId} in ${other.room}').last);
    await tester.pumpAndSettle();
    expect(find.text('Cumulative hours: ${other.deviceId} in ${other.room}'), findsOneWidget);
    expect(takeAnnouncementTexts(tester), contains('Chart shows ${other.deviceId} in ${other.room}.'));
  });

  testWidgets('explains the minimum data and offers to widen the range', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.forecast, size: tall);
    t.app.setDatePreset(DatePreset.last7);
    await settleWork(tester, t);
    expect(t.app.analysis!.forecast.hasEnoughData, isFalse);
    expect(find.text('Not enough data for trends yet'), findsOneWidget);
    expect(find.textContaining('at least 3 complete weeks'), findsWidgets);
    await expectMeetsA11yGuidelines(tester);

    await tester.tap(find.text('Analyse all loaded data'));
    await settleWork(tester, t);
    expect(t.app.filters.preset, DatePreset.all);
    expect(find.text('Not enough data for trends yet'), findsNothing);
  });

  testWidgets('methodology links to the rated life settings', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.forecast, size: tall);
    await scrollTo(tester, find.text('Edit rated life in Settings'));
    for (final a in t.app.analysis!.forecast.assumptions) {
      expect(find.text(a), findsOneWidget);
    }
    expect(find.textContaining('Projector: '), findsOneWidget);
    await tester.tap(find.text('Edit rated life in Settings'));
    await tester.pump();
    expect(t.navigation.current, AppDestination.settings);
  });

  testWidgets('a dataset without devices or inputs explains what is missing', (tester) async {
    await pumpWithData(tester, dataset: quietDataset(), initial: AppDestination.forecast, size: tall);
    expect(find.text('No device power events in this data'), findsOneWidget);
    expect(find.text('Not enough data for trends yet'), findsOneWidget);
    await expectMeetsA11yGuidelines(tester);
  });

  testWidgets('copies the device forecasts as CSV', (tester) async {
    final clipboard = ClipboardSpy(tester);
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.forecast, size: tall);
    await tester.tap(find.widgetWithText(TextButton, 'Copy as CSV').first);
    await tester.pump();
    final lines = clipboard.text!.trim().split('\n');
    expect(lines.first, startsWith('device,room,building,type,observed_hours'));
    expect(lines.length, t.app.analysis!.forecast.devices.length + 1);
  });
}
