import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_room_detail.dart';
import 'package:metrics_visualizer/ui/screens/rooms_screen.dart';

import 'screens_a_helpers.dart';

RoomListEntry entry(
  String room,
  String building, {
  double hours = 0,
  int sessions = 0,
  int issues = 0,
  DateTime? seen,
}) => RoomListEntry(
  RoomSummary(
    room: room,
    building: building,
    eventCount: 0,
    firstEvent: null,
    lastEvent: null,
    systemSessions: sessions,
    systemHours: hours,
    utilization: 0,
    afterHoursHours: 0,
    averageSessionHours: 0,
    reboots: 0,
    deviceHours: 0,
    deviceIds: const [],
    topInput: null,
    issueCounts: {IssueSeverity.info: issues, IssueSeverity.warning: 0, IssueSeverity.critical: 0},
    onlineFraction: null,
    helpRequests: 0,
    buttonPresses: 0,
  ),
  seen,
);

/// Text of the room tiles, in order.
List<String> tileRooms(WidgetTester tester) => [
  for (final t in tester.widgetList<ListTile>(find.byType(ListTile)))
    if (t.title is Text) (t.title! as Text).data!,
];

void main() {
  final dataset = demoDataset();

  group('filterAndSortRooms', () {
    final entries = [
      entry('bss_10', 'BSS', hours: 5, sessions: 2, issues: 1, seen: DateTime.utc(2026, 1, 2)),
      entry('ARTS_1', 'ARTS', hours: 9, sessions: 1, issues: 3),
      entry('BSS_2', 'BSS', hours: 9, sessions: 7, issues: 0, seen: DateTime.utc(2026, 1, 3)),
    ];
    List<String> names(List<RoomListEntry> l) => [for (final e in l) e.summary.room];

    test('searches room and building names, ignoring case', () {
      expect(names(filterAndSortRooms(entries, query: ' bss ', sort: RoomSort.name, ascending: true)), [
        'bss_10',
        'BSS_2',
      ]);
      expect(names(filterAndSortRooms(entries, query: 'arts', sort: RoomSort.name, ascending: true)), ['ARTS_1']);
      expect(filterAndSortRooms(entries, query: 'zzz', sort: RoomSort.name, ascending: true), isEmpty);
    });

    test('sorts by every key with a stable name tie-break', () {
      List<String> by(RoomSort s, bool asc) => names(filterAndSortRooms(entries, query: '', sort: s, ascending: asc));
      expect(by(RoomSort.name, true), ['ARTS_1', 'bss_10', 'BSS_2']);
      expect(by(RoomSort.hours, false), ['ARTS_1', 'BSS_2', 'bss_10']);
      expect(by(RoomSort.sessions, false), ['BSS_2', 'bss_10', 'ARTS_1']);
      expect(by(RoomSort.issues, false), ['ARTS_1', 'bss_10', 'BSS_2']);
      expect(by(RoomSort.lastSeen, false), ['BSS_2', 'bss_10', 'ARTS_1']);
      expect(by(RoomSort.building, true), ['ARTS_1', 'bss_10', 'BSS_2']);
    });
  });

  group('Rooms screen', () {
    testWidgets('wide: search, sort and master/detail selection', (tester) async {
      final h = await pumpScreen(tester, AppDestination.rooms, dataset: dataset, size: extraWide);
      expect(find.text('24 rooms'), findsOneWidget);
      expect(find.text('Choose a room'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Search rooms'), 'bss');
      await tester.pump();
      expect(find.text('Showing 5 of 24 rooms'), findsOneWidget);
      expect(tileRooms(tester), ['BSS_108', 'BSS_112', 'BSS_238', 'BSS_241', 'BSS_245']);

      tester.widget<DropdownMenu<RoomSort>>(find.byType(DropdownMenu<RoomSort>)).onSelected!(RoomSort.issues);
      await tester.pump();
      // Issues sort largest first (ties by name).
      final bss = h.app.analysis!.roomSummaries.where((s) => s.building == 'BSS').toList()
        ..sort((a, b) {
          final c = b.issueTotal.compareTo(a.issueTotal);
          return c != 0 ? c : a.room.toLowerCase().compareTo(b.room.toLowerCase());
        });
      expect(tileRooms(tester), [for (final s in bss) s.room]);
      await tester.tap(find.byTooltip('Sorted descending; switch to ascending'));
      await tester.pump();
      expect(tileRooms(tester).last, bss.first.room);

      await tester.enterText(find.widgetWithText(TextField, 'Search rooms'), 'zzz');
      await tester.pump();
      expect(find.text('No rooms match your search'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(find.text('24 rooms'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, 'Search rooms'), 'holt');
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'HOLT_155'));
      await tester.pump();
      expect(h.navigation.selectedRoom, 'HOLT_155');
      expect(find.text('Room HOLT_155'), findsOneWidget);
      expect(find.text('Rapid power cycling'), findsNothing); // titles carry the severity prefix
      expect(find.textContaining('Rapid power cycling'), findsWidgets);
      final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, 'HOLT_155'));
      expect(tile.selected, isTrue);
    });

    testWidgets('narrow: list, then detail with Back and Escape', (tester) async {
      final h = await pumpScreen(tester, AppDestination.rooms, dataset: dataset, size: narrow);
      expect(find.text('Room BSS_108'), findsNothing);
      await tester.ensureVisible(find.widgetWithText(ListTile, 'BSS_108'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'BSS_108'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Room BSS_108'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'BSS_112'), findsNothing);

      expect(FocusManager.instance.primaryFocus?.debugLabel, 'All rooms');
      await tester.tap(find.text('All rooms'));
      await tester.pump();
      await tester.pump();
      // Focus returns to the room that was open.
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Last opened room');
      expect(h.navigation.selectedRoom, isNull);
      expect(find.widgetWithText(ListTile, 'BSS_112'), findsOneWidget);
      expect(tester.takeAnnouncements().map((a) => a.message), contains('Back to the room list.'));

      await tester.ensureVisible(find.widgetWithText(ListTile, 'BSS_112'));
      await tester.pump();
      await tester.tap(find.widgetWithText(ListTile, 'BSS_112'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Room BSS_112'), findsOneWidget);
      // The Back button takes focus, so Escape works straight away.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(h.navigation.selectedRoom, isNull);
    });

    testWidgets('drill-down from another page opens the room detail', (tester) async {
      final h = await pumpScreen(
        tester,
        AppDestination.rooms,
        dataset: dataset,
        size: extraWide,
        room: DemoScenario.deviceLeftOn,
      );
      await fitWholePage(tester);
      expect(find.text('Room ${DemoScenario.deviceLeftOn}'), findsOneWidget);
      expect(find.text('Video input share in ${DemoScenario.deviceLeftOn}'), findsOneWidget);
      expect(find.text('Device on-hours in ${DemoScenario.deviceLeftOn}'), findsOneWidget);
      expect(find.text('When ${DemoScenario.deviceLeftOn} is in use'), findsOneWidget);
      expect(find.text('Recent issues in ${DemoScenario.deviceLeftOn}'), findsOneWidget);
      final newest = [...h.app.analysis!.issuesForRoom(DemoScenario.deviceLeftOn)]
        ..sort((a, b) => b.start.compareTo(a.start));
      if (newest.isNotEmpty) expect(find.textContaining(newest.first.title), findsWidgets);
    });

    testWidgets('a room outside the filters explains itself', (tester) async {
      final h = await pumpScreen(tester, AppDestination.rooms, dataset: dataset, size: extraWide, room: 'NOPE_1');
      expect(find.text('Room NOPE_1 is not in the current filters'), findsOneWidget);
      await tester.tap(find.text('Back to the room list'));
      await tester.pump();
      expect(h.navigation.selectedRoom, isNull);
    });

    testWidgets('event timeline is virtualized, filterable and keyboard scrollable', (tester) async {
      final handle = tester.ensureSemantics();
      final h = await pumpScreen(
        tester,
        AppDestination.rooms,
        dataset: dataset,
        size: extraWide,
        room: DemoScenario.buttonMashing,
      );
      await fitWholePage(tester);
      final total = h.app.filteredDataset!.events.where((e) => e.clientName == DemoScenario.buttonMashing).length;
      expect(total, greaterThan(500));
      final count = NumberFormatHelper.count(total);
      expect(find.text('$count events'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^Event timeline for ${DemoScenario.buttonMashing}, $total events')),
        findsOneWidget,
      );

      final timeline = find.byType(EventTimeline);
      final list = find.descendant(of: timeline, matching: find.byType(ListView));
      // Virtualized: only a screenful of rows is built.
      final built = find.descendant(of: list, matching: find.byType(MergeSemantics)).evaluate().length;
      expect(built, lessThan(60));

      final scrollable = find.descendant(of: list, matching: find.byType(Scrollable));
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, 0);
      // Tab stop: focus the list, then Page Down / End / Home.
      final focus = tester.widget<Focus>(find.byKey(EventTimeline.focusKey));
      focus.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(position.pixels, greaterThan(0));
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(position.pixels, position.maxScrollExtent);
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(position.pixels, 0);

      // Filter to touch-panel traces only.
      tester.widget<DropdownMenu<EventCategory?>>(find.byType(DropdownMenu<EventCategory?>)).onSelected!(
        EventCategory.uiTrace,
      );
      await tester.pump();
      expect(find.textContaining(RegExp(r'^[\d,]+ events in Touch panel$')), findsOneWidget);
      expect(find.textContaining('· Touch panel'), findsWidgets);
      expect(find.textContaining('· Video input'), findsNothing);
      handle.dispose();
    });

    testWidgets('hundreds of rooms are paged on narrow screens', (tester) async {
      await pumpScreen(tester, AppDestination.rooms, dataset: manyRoomsDataset(), size: narrow);
      await fitWholePage(tester);
      expect(find.text('320 rooms'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(50));
      await tester.tap(find.text('Show more rooms (270 remaining)'));
      await tester.pump();
      expect(find.byType(ListTile), findsNWidgets(100));
    });

    testWidgets('hundreds of rooms stay virtualized on wide screens', (tester) async {
      await pumpScreen(tester, AppDestination.rooms, dataset: manyRoomsDataset(), size: extraWide);
      expect(find.text('320 rooms'), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(40));
    });
  });
}

/// Formats counts like the app (en_US grouping).
abstract final class NumberFormatHelper {
  static String count(int n) => n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
}
