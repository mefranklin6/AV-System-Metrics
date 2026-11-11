import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/inputs_screen.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_common.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_a_helpers.dart';

/// Captures text written to the clipboard.
List<String> captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

/// The segment labelled [label] of a `SegmentedButton<T>`.
Finder segment<T>(String label) => find.descendant(of: find.byType(SegmentedButton<T>), matching: find.text(label));

void main() {
  final dataset = demoDataset();

  group('Overview', () {
    testWidgets('shows KPIs, chart summaries, issues and insights', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, AppDestination.overview, dataset: dataset, size: extraWide);
      await fitWholePage(tester);

      expect(find.bySemanticsLabel(RegExp(r'^Rooms: 24\. in 6 buildings')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Potential issues: \d+\. \d+ critical, \d+ warning, \d+ info')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Top source: PC\.')), findsOneWidget);
      // Every chart is one node with a plain-language summary.
      expect(
        find.bySemanticsLabel(RegExp(r'^Source share\. PC accounts for \d+\.\d% of time on screen in all rooms')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp(r'^Busiest hours\. Rooms are busiest at')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Weekly system hours\. ')), findsOneWidget);
      // Top issues, most severe first.
      expect(find.textContaining('Critical: '), findsWidgets);
      // Insights in plain language, least used input first.
      expect(find.textContaining('Blu-ray was selected in 1 of 24 rooms'), findsOneWidget);
      expect(find.textContaining('ended with an inactivity power-off reason'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('table toggle swaps the chart for a data table and back', (tester) async {
      await pumpScreen(tester, AppDestination.overview, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.byType(DataTable), findsNothing);
      await tester.tap(find.text('View as table').first);
      await tester.pump();
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('Share of selections'), findsOneWidget);
      await tester.tap(find.text('View as chart'));
      await tester.pump();
      expect(find.byType(DataTable), findsNothing);
    });

    testWidgets('KPI tiles, issues and insights link to their pages', (tester) async {
      final h = await pumpScreen(tester, AppDestination.overview, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      await tester.tap(find.widgetWithText(KpiTile, 'Potential issues'));
      await tester.pump();
      expect(h.navigation.current, AppDestination.issues);

      h.navigation.goTo(AppDestination.overview);
      await settle(tester, h);
      await fitWholePage(tester);
      await tester.tap(find.text('View all issues'));
      await tester.pump();
      expect(h.navigation.current, AppDestination.issues);

      h.navigation.goTo(AppDestination.overview);
      await settle(tester, h);
      await fitWholePage(tester);
      await tester.tap(find.text('Open Sources').first);
      await tester.pump();
      expect(h.navigation.current, AppDestination.inputs);
    });
  });

  group('Sources', () {
    testWidgets('scope and measure change every chart', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpScreen(tester, AppDestination.inputs, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(
        find.bySemanticsLabel(
          RegExp(r'^Source share\. PC accounts for \d+\.\d% of selections in all rooms \(\d+ of'),
        ),
        findsOneWidget,
      );
      expect(find.text('Room by source matrix'), findsOneWidget);

      await tester.tap(segment<InputMeasure>('Time on screen'));
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Source share\. .* of time on screen in all rooms')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Sources ranked\. .*ranked by time on screen')), findsOneWidget);

      await tester.tap(segment<InputScope>('Building'));
      await tester.pump();
      expect(find.byKey(const ValueKey('building-menu')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Source share\. .* in building AJH')), findsOneWidget);
      // Choose another building from the searchable menu.
      tester.widget<AppDropdownMenu<String>>(find.byKey(const ValueKey('building-menu'))).onSelected('LIB');
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp(r'^Source share\. .* in building LIB')), findsOneWidget);
      expect(find.text('LIB_014'), findsOneWidget); // matrix row
      expect(find.text('BSS_245'), findsNothing);

      await tester.tap(segment<InputScope>('Room'));
      await tester.pump();
      await fitWholePage(tester);
      expect(find.byKey(const ValueKey('room-menu')), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'^Source share in AJH_125A|^Source share\. .* in room AJH_125A')),
        findsOneWidget,
      );
      expect(find.text('Room by source matrix'), findsNothing);
      handle.dispose();
    });

    testWidgets('least-used sources are listed with plain-language reasons', (tester) async {
      await pumpScreen(tester, AppDestination.inputs, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      expect(find.text('Least-used sources'), findsWidgets);
      expect(find.textContaining('(Rarely used campus-wide).'), findsWidgets);
      final showAll = find.textContaining(RegExp(r'^Show all \d+ sources$'));
      expect(showAll, findsOneWidget);
      await tester.tap(showAll);
      await tester.pump();
      expect(find.text('Show fewer'), findsOneWidget);
      expect(find.textContaining('(Never used in this room).'), findsWidgets);
    });

    testWidgets('matrix sorts by a column and copies as CSV', (tester) async {
      final copied = captureClipboard(tester);
      await pumpScreen(tester, AppDestination.inputs, dataset: dataset, size: extraWide);
      await fitWholePage(tester);
      final matrix = find.ancestor(of: find.text('Total selections'), matching: find.byType(DataTable));
      expect(tester.widget<DataTable>(matrix).sortColumnIndex, isNull);
      await tester.ensureVisible(find.text('Total selections'));
      await tester.pump();
      await tester.tap(find.text('Total selections'));
      await tester.pump();
      final table = tester.widget<DataTable>(matrix);
      expect(table.sortColumnIndex, table.columns.length - 1);

      await tester.tap(find.byTooltip('Copy the matrix as CSV'));
      await tester.pump();
      expect(copied, hasLength(1));
      final lines = copied.single.split('\n');
      expect(lines.first, startsWith('Room,PC,'));
      expect(lines.first, endsWith('Total selections'));
      expect(lines.where((l) => l.isNotEmpty), hasLength(25)); // header + 24 rooms
    });
  });
}
