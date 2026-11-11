import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/ui/theme/app_theme.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

Widget host(Widget child, {bool reduceMotion = false, Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      home: MotionPreferences(
        reduceMotion: reduceMotion,
        child: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child))),
      ),
    );

const table = ChartTable(
  columns: [ChartColumn('Input'), ChartColumn('Selections', numeric: true)],
  rows: [
    ['PC', '1,204'],
    ['HDMI', '511'],
    ['=cmd|calc', '3'],
  ],
  rawRows: [
    ['PC', 1204],
    ['HDMI', 511],
    ['=cmd|calc', 3],
  ],
);

AccessibleChartCard card() => const AccessibleChartCard(
      title: 'Video input share',
      description: 'All rooms',
      summary: 'PC was selected most often: 70% of selections.',
      chart: ColoredBox(color: Colors.teal),
      table: table,
    );

void main() {
  group('ChartTable', () {
    test('CSV export uses raw values, quotes when needed and blocks formula injection', () {
      final csv = table.toCsv();
      final lines = csv.trim().split('\n');
      expect(lines.first, 'Input,Selections');
      expect(lines[1], 'PC,1204');
      expect(lines[3], startsWith("'=cmd|calc"));
      const negative = ChartTable(columns: [ChartColumn('Change')], rows: [['-3.5']]);
      expect(negative.toCsv().trim().split('\n').last, '-3.5');
      const comma = ChartTable(columns: [ChartColumn('Room')], rows: [['A, B']]);
      expect(comma.toCsv(), contains('"A, B"'));
    });
  });

  group('AccessibleChartCard', () {
    testWidgets('exposes the summary to screen readers and toggles a real table', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(card()));
      expect(find.bySemanticsLabel(RegExp('Video input share. PC was selected most often')), findsOneWidget);
      expect(find.byType(DataTable), findsNothing);

      await tester.tap(find.text('View as table'));
      await tester.pumpAndSettle();
      expect(find.byType(DataTable), findsOneWidget);
      expect(find.text('1,204'), findsOneWidget);
      expect(find.text('View as chart'), findsOneWidget);

      // Sorting by the numeric column puts the largest last when ascending.
      await tester.tap(find.text('Selections'));
      await tester.pumpAndSettle();
      final cells = tester.widgetList<Text>(find.descendant(of: find.byType(DataTable), matching: find.byType(Text)));
      final texts = cells.map((t) => t.data).toList();
      expect(texts.indexOf('3'), lessThan(texts.indexOf('1,204')));

      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('copy as CSV writes the clipboard and confirms', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(host(card()));
      await tester.tap(find.byTooltip('Copy the data as CSV'));
      await tester.pump();
      expect(copied, table.toCsv());
      expect(find.text('Table copied to the clipboard as CSV.'), findsOneWidget);
    });

    testWidgets('large tables are paged', (tester) async {
      final big = ChartTable(
        columns: const [ChartColumn('Room'), ChartColumn('Hours', numeric: true)],
        rows: [for (var i = 0; i < 450; i++) ['R$i', '$i']],
      );
      await tester.pumpWidget(host(AccessibleChartCard(
        title: 'Big',
        summary: 'Many rooms.',
        chart: const SizedBox(),
        table: big,
        initiallyShowTable: true,
      )));
      expect(find.text('Show more rows (250 remaining)'), findsOneWidget);
      await tester.ensureVisible(find.text('Show more rows (250 remaining)'));
      await tester.tap(find.text('Show more rows (250 remaining)'));
      await tester.pump();
      expect(find.text('Show more rows (50 remaining)'), findsOneWidget);
    });

    testWidgets('dark theme meets contrast guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host(card(), brightness: Brightness.dark));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  testWidgets('KpiTile reads as one phrase and can be a button', (tester) async {
    final handle = tester.ensureSemantics();
    var tapped = 0;
    await tester.pumpWidget(host(KpiTile(
      label: 'Rooms in use',
      value: '18',
      caption: 'of 24 rooms',
      trend: KpiTrend.up,
      trendLabel: 'Up 12% on last week',
      icon: Icons.meeting_room,
      onTap: () => tapped++,
    )));
    final node = find.bySemanticsLabel('Rooms in use: 18. of 24 rooms. Up 12% on last week');
    expect(node, findsOneWidget);
    expect(tester.getSemantics(node).flagsCollection.isButton, isTrue);
    await tester.tap(find.text('18'));
    expect(tapped, 1);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });

  testWidgets('PatternLegend names pattern and value, not just colour', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(Builder(builder: (context) {
      final palette = ChartPalette.of(context);
      return PatternLegend(items: [
        LegendItem.fromPalette(palette, 0, 'PC', value: '70%'),
        LegendItem.fromPalette(palette, 1, 'HDMI', value: '30%'),
      ]);
    })));
    expect(find.bySemanticsLabel('PC, 70%'), findsOneWidget);
    expect(find.bySemanticsLabel('HDMI, 30%, Diagonal lines pattern'), findsOneWidget);
    expect(find.byType(PatternBox), findsNWidgets(2));
    handle.dispose();
  });

  testWidgets('SectionHeader and EmptyState headings are marked as headers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(const Column(children: [
      SectionHeader(title: 'Inputs', subtitle: 'Sub'),
      EmptyState(title: 'Nothing here', message: 'Try another range.'),
    ])));
    expect(tester.getSemantics(find.text('Inputs')).flagsCollection.isHeader, isTrue);
    expect(tester.getSemantics(find.text('Nothing here')).flagsCollection.isHeader, isTrue);
    handle.dispose();
  });

  testWidgets('ErrorBanner is a live region with text, suggestion and actions', (tester) async {
    final handle = tester.ensureSemantics();
    var retried = false;
    await tester.pumpWidget(host(ErrorBanner(
      title: 'Could not import',
      message: 'Missing column.',
      suggestion: 'Export again.',
      onRetry: () => retried = true,
      onDismiss: () {},
    )));
    expect(find.text('Suggestion: Export again.'), findsOneWidget);
    final live = find.byWidgetPredicate((w) => w is Semantics && w.properties.liveRegion == true);
    expect(live, findsOneWidget);
    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('LoadingOverlay exposes progress and hides stale content', (tester) async {
    final handle = tester.ensureSemantics();
    var cancelled = false;
    await tester.pumpWidget(host(
      SizedBox(
        height: 400,
        child: LoadingOverlay(
          isLoading: true,
          message: 'Downloading events',
          progress: 0.45,
          onCancel: () => cancelled = true,
          child: const Text('Stale content'),
        ),
      ),
      reduceMotion: true,
    ));
    final progress = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Downloading events' && w.properties.value == '45%');
    expect(progress, findsOneWidget);
    expect(find.bySemanticsLabel('Stale content'), findsNothing);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, isTrue);
    handle.dispose();
  });

  group('Motion', () {
    testWidgets('setting and platform flag both reduce motion to zero', (tester) async {
      late Motion motion;
      Widget probe() => Builder(builder: (context) {
            motion = Motion.of(context);
            return const SizedBox();
          });
      await tester.pumpWidget(host(probe()));
      expect(motion.reduced, isFalse);
      expect(motion.medium, const Duration(milliseconds: 300));

      await tester.pumpWidget(host(probe(), reduceMotion: true));
      expect(motion.reduced, isTrue);
      for (final d in [motion.short, motion.medium, motion.long, motion.chart, motion.duration(const Duration(seconds: 3))]) {
        expect(d, Duration.zero);
      }

      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: probe(),
        ),
      ));
      expect(motion.reduced, isTrue);
    });
  });

  test('ResponsiveGrid column count', () {
    expect(ResponsiveGrid.columnsFor(320, 360, 16, 4), 1);
    expect(ResponsiveGrid.columnsFor(736, 360, 16, 4), 2);
    expect(ResponsiveGrid.columnsFor(3000, 360, 16, 4), 4);
    expect(ResponsiveGrid.columnsFor(double.infinity, 360, 16, 4), 1);
  });

  testWidgets('ResponsiveGrid reflows to one column at 320 px', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResponsiveGrid(
          minChildWidth: 200,
          children: [
            for (var i = 0; i < 3; i++) SizedBox(key: ValueKey(i), height: 50, child: Text('Card $i')),
            const GridSpan(columns: 2, child: SizedBox(key: ValueKey('span'), height: 50)),
          ],
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(const ValueKey(0))).width, 320);
    expect(tester.getTopLeft(find.byKey(const ValueKey(1))).dy, greaterThan(tester.getTopLeft(find.byKey(const ValueKey(0))).dy));
    expect(tester.getSize(find.byKey(const ValueKey('span'))).width, 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MultiSelectDialog filters, selects and returns the choice', (tester) async {
    Set<String>? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await showMultiSelectDialog(
                context: context, title: 'Rooms', options: const ['BSS_245', 'HOLT_155', 'ARTS_107'], selected: const {}),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('None selected: all are included.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'holt');
    await tester.pumpAndSettle();
    expect(find.text('BSS_245'), findsNothing);
    await tester.tap(find.text('Select matches'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected.'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(result, {'HOLT_155'});
  });

  testWidgets('Fmt formats numbers, durations and UTC times', (tester) async {
    final utc = Fmt(utc: true);
    expect(utc.count(1234567), '1,234,567');
    expect(utc.percent(0.256), '25.6%');
    expect(utc.hours(1234.5), '1,234.5 h');
    expect(utc.duration(const Duration(hours: 2, minutes: 5)), '2 h 05 min');
    expect(utc.duration(const Duration(seconds: 45)), '45 s');
    expect(utc.duration(const Duration(days: 3)), '3.0 days');
    // intl separates AM/PM with a narrow no-break space.
    String plain(String s) => s.replaceAll('\u202f', ' ');
    expect(plain(utc.time(DateTime.utc(2026, 11, 10, 15, 31))), '3:31 PM UTC');
    expect(Fmt.weekday(1), 'Monday');
    expect(plain(Fmt.hourOfDay(8)), '8 AM');
  });
}
