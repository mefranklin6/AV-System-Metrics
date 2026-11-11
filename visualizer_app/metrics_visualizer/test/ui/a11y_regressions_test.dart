// Regression tests for accessibility findings: reflow at 320 px / 400% zoom,
// heading semantics, focus visibility and focus management, names of
// controls on desktop platforms, and announcements of errors and re-sorts.

import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/app_state.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/parts/a_common.dart';
import 'package:metrics_visualizer/ui/screens/parts/b_issue_widgets.dart';
import 'package:metrics_visualizer/ui/shell.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'ui_test_helpers.dart';

/// Every semantics node in the tree.
List<SemanticsNode> allNodes(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode n) {
    nodes.add(n);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
  return nodes;
}

bool isHeader(SemanticsNode n) => n.getSemanticsData().flagsCollection.isHeader;

/// Whether [node]'s focus belongs to a widget inside [ancestor].
bool focusInside(FocusNode? node, Finder ancestor) {
  final ctx = node?.context;
  if (ctx == null) return false;
  final targets = ancestor.evaluate().toSet();
  var found = false;
  if (targets.contains(ctx)) return true;
  ctx.visitAncestorElements((e) {
    if (targets.contains(e)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Scrolls the current page (jumping, so lazily built items get built)
/// until [finder] exists, then brings it into view.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  final page = find.descendant(
    of: find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Main content'),
    matching: find.byType(Scrollable),
  );
  final pos = tester.state<ScrollableState>(page.first).position;
  pos.jumpTo(0);
  await tester.pump();
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    if (pos.pixels >= pos.maxScrollExtent - 1) break;
    pos.jumpTo((pos.pixels + 300).clamp(0, pos.maxScrollExtent).toDouble());
    await tester.pump();
  }
  expect(finder, findsWidgets);
  await tester.ensureVisible(finder.first);
  await tester.pump();
}

void main() {
  group('reflow (WCAG 1.4.10)', () {
    for (final (size, scale) in [(const Size(320, 256), 1.0), (const Size(320, 640), 2.0)]) {
      testWidgets('every analysis page keeps room for content at ${size.width.toInt()}x${size.height.toInt()}, '
          'text ${scale}x', (tester) async {
        final t = await pumpApp(tester, size: size, textScale: scale, loadDemo: true);
        for (final d in AppDestination.values.where((d) => d.isAnalysis)) {
          t.navigation.goTo(d);
          await pumpFrames(tester, 2);
          expect(tester.takeException(), isNull, reason: d.name);
          final page = find.byType(screenFor(d).runtimeType);
          expect(page, findsOneWidget, reason: d.name);
          expect(tester.getSize(page).height, greaterThan(150), reason: '${d.name} content height');
          // The filters are a single button at the top of the content.
          expect(find.byType(NavigationBar), findsNothing);
          expect(tester.widget<FilterBar>(find.byType(FilterBar)).compact, isTrue, reason: d.name);
        }
      });
    }

    testWidgets('the compact filter button opens every filter in a dialog', (tester) async {
      final t = await pumpApp(tester, size: const Size(320, 640), textScale: 2.0, loadDemo: true,
          initial: AppDestination.overview);
      expect(find.text('Dates: All data'), findsNothing);
      await reveal(tester, find.text('Filters'));
      await tester.tap(find.text('Filters'));
      await pumpFrames(tester, 2);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.widgetWithText(RadioListTile<DatePreset>, 'All data'), findsOneWidget);
      expect(find.textContaining('Buildings: '), findsOneWidget);
      final week = find.widgetWithText(RadioListTile<DatePreset>, 'Last 7 days');
      await tester.ensureVisible(week);
      await tester.pump();
      await tester.tap(week);
      await settleWork(tester, t);
      expect(t.app.window!.duration, const Duration(days: 7));
      await tester.tap(find.text('Done'));
      await pumpFrames(tester, 8);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Filters (1 active)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide windows keep the full filter bar and bottom bar rules', (tester) async {
      await pumpApp(tester, size: narrowSize, loadDemo: true, initial: AppDestination.overview);
      expect(tester.widget<FilterBar>(find.byType(FilterBar)).compact, isFalse);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('the multi-select dialog shows options at 320 x 256', (tester) async {
      tester.view.physicalSize = const Size(320, 256);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMultiSelectDialog(
              context: context,
              title: 'Choose rooms',
              options: [for (var i = 0; i < 30; i++) 'ROOM_$i'],
              selected: const {},
              subtitleOf: (_) => 'Building',
            ),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CheckboxListTile), findsWidgets);
      final first = find.widgetWithText(CheckboxListTile, 'ROOM_0');
      await tester.ensureVisible(first);
      await tester.pumpAndSettle();
      await tester.tap(first);
      await tester.pump();
      expect(find.text('1 selected.'), findsOneWidget);
    });
  });

  group('resize text (WCAG 1.4.4)', () {
    testWidgets('the app bar title follows the full text size', (tester) async {
      await pumpApp(tester, textScale: 2.0, loadDemo: true, initial: AppDestination.overview);
      final title = find.descendant(of: find.byType(AppBar), matching: find.text('Overview'));
      expect(MediaQuery.textScalerOf(tester.element(title)).scale(1), 2.0);
      expect(find.descendant(of: find.byType(AppBar), matching: find.textContaining('events')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow windows with large text use the drawer and move the dataset summary', (tester) async {
      await pumpApp(tester, size: narrowSize, textScale: 1.5, loadDemo: true, initial: AppDestination.overview);
      // Bottom bar labels are capped at 130% by Flutter: the drawer is used.
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.byTooltip('Open navigation menu'), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.textContaining('events')), findsNothing);
      expect(find.descendant(of: find.byType(FilterBar), matching: find.textContaining('events')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('headings (WCAG 1.3.1 / 2.4.6)', () {
    testWidgets('each heading is its own node named exactly by its text, with a level', (tester) async {
      final handle = tester.ensureSemantics();
      final t = await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
      for (final d in [AppDestination.overview, AppDestination.settings, AppDestination.dataSource]) {
        t.navigation.goTo(d);
        await pumpFrames(tester, 2);
        final headers = allNodes(tester).where(isHeader).toList();
        expect(headers, isNotEmpty, reason: d.name);
        final visible = {
          for (final e in find.byType(Text).evaluate())
            if ((e.widget as Text).data != null) (e.widget as Text).data!,
        };
        for (final h in headers) {
          final data = h.getSemanticsData();
          expect(visible, contains(data.label), reason: '${d.name}: heading "${data.label}"');
          expect(data.headingLevel, inInclusiveRange(1, 4), reason: '${d.name}: ${data.label}');
        }
        final level1 = headers.where((h) => h.getSemanticsData().headingLevel == 1).toList();
        expect(level1, hasLength(1), reason: '${d.name}: one page heading');
      }
      // The page title in the app bar is not a second page heading.
      t.navigation.goTo(AppDestination.overview);
      await pumpFrames(tester, 2);
      final overview = allNodes(tester).where(isHeader).map((n) => n.getSemanticsData()).toList();
      expect(overview.where((h) => h.label == 'Overview'), hasLength(1));
      expect(overview.firstWhere((h) => h.label == 'Overview').headingLevel, 1);
      expect(overview.firstWhere((h) => h.label == 'At a glance').headingLevel, 2);
      handle.dispose();
    });
  });

  group('focus (WCAG 2.4.3 / 2.4.7 / 4.1.2)', () {
    testWidgets('a focused KPI tile is reported as focused to assistive technology', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
      final kpi = find.bySemanticsLabel(RegExp(r'^Rooms: \d'));
      expect(kpi, findsOneWidget);
      expect(tester.getSemantics(kpi).getSemanticsData().flagsCollection.isFocused, Tristate.isFalse);
      final node = Focus.of(tester.element(find.descendant(of: find.byType(KpiTile), matching: find.text('Rooms'))));
      node.requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, node);
      await tester.pump();
      final data = tester.getSemantics(kpi).getSemanticsData();
      expect(data.flagsCollection.isFocused, Tristate.isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('a focus ring is drawn around list tiles and KPI tiles, not around buttons', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      await pumpApp(tester, initial: AppDestination.settings);
      final tileText = find.text('High contrast');
      await reveal(tester, tileText);
      Focus.of(tester.element(tileText)).requestFocus();
      await pumpFrames(tester, 2);
      expect(find.byKey(const ValueKey('focus-ring')), findsOneWidget);
      final ring = FocusRingOverlay.debugRingRect!;
      final tile = tester.getRect(find.ancestor(of: tileText, matching: find.byType(SwitchListTile)));
      expect(ring.contains(tile.center), isTrue);
      expect(ring.width, greaterThanOrEqualTo(tile.width));

      // Buttons draw the theme's own 3 px outline instead.
      final button = find.widgetWithText(OutlinedButton, 'Reset to defaults');
      await reveal(tester, button);
      Focus.of(tester.element(find.descendant(of: button, matching: find.text('Reset to defaults')))).requestFocus();
      await pumpFrames(tester, 2);
      expect(find.byKey(const ValueKey('focus-ring')), findsNothing);
    });

    testWidgets('navigation destinations get the focus ring', (tester) async {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      await pumpApp(tester, size: const Size(1000, 800));
      final label = find.descendant(of: find.byType(NavigationRail), matching: find.text('Settings'));
      Focus.of(tester.element(label)).requestFocus();
      await pumpFrames(tester, 2);
      expect(find.byKey(const ValueKey('focus-ring')), findsOneWidget);
      expect(FocusRingOverlay.debugRingRect!.contains(tester.getCenter(label)), isTrue);
    });

    testWidgets('the skip link is one tab stop and Tab after skipping enters the content', (tester) async {
      await pumpApp(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpFrames(tester, 2);
      expect(focusInside(FocusManager.instance.primaryFocus, find.byType(SkipToContentLink)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpFrames(tester, 2);
      expect(focusInside(FocusManager.instance.primaryFocus, find.byType(SkipToContentLink)), isFalse);
      // The content container is a skip target, not an invisible tab stop.
      for (var i = 0; i < 20; i++) {
        expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('Main content'));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }

      // Skip, then Tab: the first control inside the page, not the skip link.
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await pumpFrames(tester, 2);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Main content');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpFrames(tester, 2);
      final f = FocusManager.instance.primaryFocus;
      expect(focusInside(f, find.byType(SkipToContentLink)), isFalse);
      expect(focusInside(f, find.byWidgetPredicate((w) => w.runtimeType.toString() == 'DataSourceScreen')), isTrue);
    });

    testWidgets('the loading overlay puts focus on Cancel', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadingOverlay(
            isLoading: true,
            message: 'Downloading',
            onCancel: () {},
            child: const TextField(autofocus: true),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Cancel loading');
    });

    testWidgets('in-page navigation moves focus to the new page and announces it', (tester) async {
      final t = await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
      final link = find.text('View all issues');
      await reveal(tester, link);
      Focus.of(tester.element(link)).requestFocus();
      await tester.pump();
      tester.takeAnnouncements();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await pumpFrames(tester, 3);
      expect(t.navigation.current, AppDestination.issues);
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Main content');
      expect([for (final a in tester.takeAnnouncements()) a.message], contains('Issues page'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await pumpFrames(tester, 2);
      expect(focusInside(FocusManager.instance.primaryFocus, find.byType(SkipToContentLink)), isFalse);
    });

    testWidgets('an issue link opens that issue, filtered to its room and focused', (tester) async {
      final t = await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
      final tile = find.descendant(of: find.byType(IssueSummaryList), matching: find.byType(ListTile)).first;
      await reveal(tester, tile);
      final title = (tester.widget<ListTile>(tile).title! as Text).data!;
      final room = title.split(' in ').last;
      await tester.tap(tile);
      await pumpFrames(tester, 8);
      expect(t.navigation.current, AppDestination.issues);
      expect(find.byType(IssueTile), findsWidgets);
      for (final e in find.byType(IssueTile).evaluate()) {
        expect((e.widget as IssueTile).issue.room, room);
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Revealed issue');
      expect(tester.takeException(), isNull);
    });

    testWidgets('removing a chip keeps focus in the list and announces it', (tester) async {
      await pumpApp(tester, initial: AppDestination.settings);
      final chips = find.descendant(
        of: find.byWidgetPredicate((w) => w is StringListEditor && w.label == 'Video input names'),
        matching: find.byType(InputChip),
      );
      await reveal(tester, chips);
      final firstLabel = (tester.widget<InputChip>(chips.first).label as Text).data!;
      final secondLabel = (tester.widget<InputChip>(chips.at(1)).label as Text).data!;
      // The chip's delete button is its tab stop.
      Focus.of(tester.element(find.descendant(of: chips.first, matching: find.byType(IconTheme)).last)).requestFocus();
      await tester.pump();
      expect(focusInside(FocusManager.instance.primaryFocus, chips.first), isTrue);
      tester.takeAnnouncements();
      tester.widget<InputChip>(chips.first).onDeleted!();
      await pumpFrames(tester, 2);
      expect([for (final a in tester.takeAnnouncements()) a.message], contains('$firstLabel removed.'));
      final next = find.ancestor(of: find.text(secondLabel), matching: find.byType(InputChip));
      expect(focusInside(FocusManager.instance.primaryFocus, next), isTrue);
    });
  });

  group('desktop platforms (WCAG 4.1.2)', () {
    testWidgets('screens meet the guidelines with desktop semantics', (tester) async {
      final t = await pumpApp(tester, loadDemo: true, initial: AppDestination.rooms);
      for (final d in [AppDestination.rooms, AppDestination.inputs, AppDestination.devices, AppDestination.settings]) {
        t.navigation.goTo(d);
        await pumpFrames(tester, 2);
        await expectMeetsA11yGuidelines(tester);
      }
    }, variant: TargetPlatformVariant.desktop());

    testWidgets('dropdown arrow buttons are named on desktop', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, loadDemo: true, initial: AppDestination.rooms);
      expect(defaultTargetPlatform, TargetPlatform.windows);
      final unnamed = allNodes(tester).where((n) {
        final d = n.getSemanticsData();
        return d.flagsCollection.isButton && d.label.trim().isEmpty && d.tooltip.trim().isEmpty;
      });
      expect(unnamed, isEmpty);
      expect(find.bySemanticsLabel('Show the list'), findsWidgets);
      handle.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('announcements (WCAG 4.1.3)', () {
    testWidgets('a settings field error is announced where errors are not live regions', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(supportsAnnounce: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpApp(tester, initial: AppDestination.settings);
      final field = find.widgetWithText(TextField, 'Rapid power cycling: events');
      await reveal(tester, field);
      tester.takeAnnouncements();
      await tester.enterText(field, '99999');
      await tester.pump();
      expect([for (final a in tester.takeAnnouncements()) a.message],
          contains('Rapid power cycling: events: Must be from 2 to 1000.'));
      // The same error is not repeated on every keystroke.
      await tester.enterText(field, '999999');
      await tester.pump();
      expect(tester.takeAnnouncements(), isEmpty);
    });

    testWidgets('sorting a table announces the order and exposes it on the header', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
      final toggle = find.text('View as table').first;
      await reveal(tester, toggle);
      await tester.tap(toggle);
      await pumpFrames(tester, 2);
      final header = find.byType(SortableColumnLabel).first;
      final label = tester.widget<SortableColumnLabel>(header).label;
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}, not sorted')), findsWidgets);
      tester.takeAnnouncements();
      await tester.tap(header);
      await pumpFrames(tester, 2);
      expect([for (final a in tester.takeAnnouncements()) a.message], contains('Sorted by $label, ascending.'));
      expect(find.bySemanticsLabel(RegExp('^${RegExp.escape(label)}, sorted ascending')), findsWidgets);
      handle.dispose();
    });

    testWidgets('the text size slider is named "Text size"', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, initial: AppDestination.settings);
      final slider = find.bySemanticsLabel('Text size');
      expect(slider, findsOneWidget);
      final data = tester.getSemantics(slider).getSemanticsData();
      expect(data.flagsCollection.isSlider, isTrue);
      expect(data.value, '100 percent');
      handle.dispose();
    });
  });

  testWidgets('the operating system reduce-motion setting turns off ink effects', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpApp(tester, reduceMotion: false);
    final ctx = tester.element(find.byType(AppShell));
    expect(Theme.of(ctx).splashFactory, NoSplash.splashFactory);
  });
}

