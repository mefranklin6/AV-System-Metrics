import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_issue_widgets.dart';

import 'screens_b_helpers.dart';

const Size tall = Size(1400, 2600);

int visibleTiles(WidgetTester tester) => find.byType(IssueTile).evaluate().length;

void main() {
  testWidgets('lists issues with counts and severity shown as icon and text', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final issues = t.app.analysis!.issues;
    expect(issues, isNotEmpty);
    expect(find.text('Showing ${issues.length} of ${issues.length} issues'), findsOneWidget);
    expect(find.text('Find issues'), findsOneWidget);
    // Severity is labelled in words on every badge, never by colour alone.
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'Severity: (Info|Warning|Critical)')), findsWidgets);
    handle.dispose();
  });

  testWidgets('filtering by type, severity, room and search narrows the list', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final all = t.app.analysis!.issues;
    final help = all.where((i) => i.type == IssueType.helpRequest).toList();
    expect(help.length, lessThan(all.length));

    await tester.tap(find.widgetWithText(FilterChip, 'Help requested (${help.length})'));
    await tester.pump();
    expect(find.text('Showing ${help.length} of ${all.length} issues'), findsOneWidget);
    expect(takeAnnouncementTexts(tester), contains('Showing ${help.length} of ${all.length} issues.'));
    // Every visible tile is a help request.
    for (final e in find.byType(IssueTile).evaluate()) {
      expect((e.widget as IssueTile).issue.type, IssueType.helpRequest);
    }

    // Severity chips combine with the type filter.
    final helpWarnings = help.where((i) => i.severity == IssueSeverity.warning).length;
    final warnings = all.where((i) => i.severity == IssueSeverity.warning).length;
    await tester.tap(find.widgetWithText(FilterChip, 'Warning ($warnings)'));
    await tester.pump();
    expect(find.text('Showing $helpWarnings of ${all.length} issues'), findsOneWidget);

    // Clear filters restores everything.
    await tester.tap(find.widgetWithText(TextButton, 'Clear filters'));
    await tester.pump();
    expect(find.text('Showing ${all.length} of ${all.length} issues'), findsOneWidget);

    // Room dropdown.
    final room = all.first.room;
    final inRoom = all.where((i) => i.room == room).length;
    await tester.tap(find.byWidgetPredicate((w) => w is DropdownButtonFormField<String?> && w.key == const ValueKey('room-null-null')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(room).last);
    await tester.pumpAndSettle();
    expect(find.text('Showing $inRoom of ${all.length} issues'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Clear filters'));
    await tester.pump();

    // Search matches the room name.
    takeAnnouncementTexts(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), room.toLowerCase());
    await tester.pump();
    // Typing is not announced on every keystroke, only after a pause.
    expect(takeAnnouncementTexts(tester), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    final matching = all
        .where((i) =>
            i.room.toLowerCase().contains(room.toLowerCase()) ||
            i.title.toLowerCase().contains(room.toLowerCase()) ||
            i.explanation.toLowerCase().contains(room.toLowerCase()) ||
            (i.subject?.toLowerCase().contains(room.toLowerCase()) ?? false) ||
            i.building.toLowerCase().contains(room.toLowerCase()))
        .length;
    expect(find.text('Showing $matching of ${all.length} issues'), findsOneWidget);
    expect(takeAnnouncementTexts(tester), ['Showing $matching of ${all.length} issues.']);

    // A search with no matches shows the empty message with a way out.
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'zzz-no-such-thing');
    await tester.pump();
    expect(find.text('No issues match these filters'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pump();
    expect(find.text('Showing ${all.length} of ${all.length} issues'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Search'), findsOneWidget);
    expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Search')).controller!.text, isEmpty);
  });

  testWidgets('a severity KPI tile filters to that severity', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final all = t.app.analysis!.issues;
    final info = all.where((i) => i.severity == IssueSeverity.info).length;
    await tester.tap(find.byTooltip('Show only info issues'));
    await tester.pump();
    expect(find.text('Showing $info of ${all.length} issues'), findsOneWidget);
  });

  testWidgets('an issue expands to explanation, action, evidence and opens its room', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final all = t.app.analysis!.issues;
    // Show only the button-mashing issue (it has evidence events).
    final mash = all.firstWhere((i) => i.type == IssueType.buttonMashing);
    await tester.tap(find.widgetWithText(FilterChip, 'Repeated button presses (1)'));
    await tester.pump();
    expect(visibleTiles(tester), 1);

    await tester.tap(find.text(mash.title));
    await tester.pump();
    expect(find.text('What happened'), findsOneWidget);
    expect(find.text(mash.explanation), findsOneWidget);
    expect(find.text(mash.suggestedAction), findsOneWidget);
    expect(find.text(mash.evidence.first.metric), findsWidgets);

    await scrollTo(tester, find.text('Open room ${mash.room}'));
    await tester.tap(find.text('Open room ${mash.room}'));
    // Navigation is synchronous; the Rooms page itself is tested elsewhere.
    expect(t.navigation.current, AppDestination.rooms);
    expect(t.navigation.selectedRoom, mash.room);
  });

  testWidgets('keyboard focus inside an issue card shows a strong focus ring', (tester) async {
    await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final tile = find.byType(IssueTile).first;
    Card card() => tester.widget<Card>(find.descendant(of: tile, matching: find.byType(Card)).first);
    expect((card().shape! as RoundedRectangleBorder).side, BorderSide.none);
    final title = find.descendant(of: tile, matching: find.byType(ListTile));
    Focus.of(tester.element(find.descendant(of: title, matching: find.byType(Text)).first)).requestFocus();
    await tester.pump();
    await tester.pump();
    expect((card().shape! as RoundedRectangleBorder).side.width, 3);
    // Space toggles the focused tile open.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('What happened'), findsOneWidget);
  });

  testWidgets('copies the filtered issues as CSV', (tester) async {
    final clipboard = ClipboardSpy(tester);
    final t = await pumpWithData(tester, dataset: demoDataset(2), initial: AppDestination.issues, size: tall);
    final all = t.app.analysis!.issues;
    final offline = all.where((i) => i.type == IssueType.offlineRoom).toList();
    await tester.tap(find.widgetWithText(FilterChip, 'Room offline (${offline.length})'));
    await tester.pump();
    await tester.tap(find.text('Copy ${offline.length} as CSV'));
    await tester.pump();
    final csv = clipboard.text!;
    final lines = csv.trim().split('\n');
    expect(lines.first, startsWith('id,severity,type,likely_cause,building,room'));
    expect(lines.length, offline.length + 1);
    expect(csv, contains('Room offline'));
    expect(takeAnnouncementTexts(tester), contains('${offline.length} issues copied to the clipboard as CSV.'));
  });

  testWidgets('shows more issues on request', (tester) async {
    final t = await pumpWithData(tester, dataset: demoDataset(10), initial: AppDestination.issues);
    final all = t.app.analysis!.issues;
    expect(all.length, greaterThan(25));
    final more = find.textContaining('Show more issues');
    await scrollTo(tester, more);
    expect(find.text('Show more issues (${all.length - 25} remaining)'), findsOneWidget);
    await tester.tap(more);
    await tester.pump();
    expect(find.byType(IssueTile), findsWidgets);
    if (all.length > 50) {
      await scrollTo(tester, find.text('Show more issues (${all.length - 50} remaining)'));
    }
  });

  testWidgets('shows a friendly empty state when nothing was flagged', (tester) async {
    final t = await pumpWithData(tester, dataset: quietDataset(), initial: AppDestination.issues);
    expect(t.app.analysis!.issues, isEmpty);
    expect(find.text('No potential issues found'), findsOneWidget);
    await expectMeetsA11yGuidelines(tester);
    await tester.tap(find.text('Detection thresholds'));
    await tester.pump();
    expect(t.navigation.current, AppDestination.settings);
  });
}
