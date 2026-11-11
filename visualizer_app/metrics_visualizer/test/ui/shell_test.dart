import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/about_screen.dart';
import 'package:metrics_visualizer/ui/screens/data_source_screen.dart';
import 'package:metrics_visualizer/ui/screens/overview_screen.dart';
import 'package:metrics_visualizer/ui/screens/settings_screen.dart';
import 'package:metrics_visualizer/ui/shell.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'ui_test_helpers.dart';

void main() {
  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final size in [wideSize, narrowSize]) {
      testWidgets('start page meets accessibility guidelines (${mode.name}, ${size.width.toInt()} wide)',
          (tester) async {
        await pumpApp(tester, themeMode: mode, size: size);
        expect(find.byType(DataSourceScreen), findsOneWidget);
        expect(find.text('No data loaded'), findsOneWidget);
        await expectMeetsA11yGuidelines(tester);
      });
    }

    testWidgets('analysis page with data meets guidelines (${mode.name})', (tester) async {
      await pumpApp(tester, themeMode: mode, loadDemo: true, initial: AppDestination.overview);
      expect(find.byType(OverviewScreen), findsOneWidget);
      expect(find.byType(FilterBar), findsOneWidget);
      await expectMeetsA11yGuidelines(tester);
    });

    testWidgets('high contrast ${mode.name} theme meets guidelines', (tester) async {
      await pumpApp(tester, themeMode: mode, highContrast: true, initial: AppDestination.about);
      await expectMeetsA11yGuidelines(tester);
    });
  }

  testWidgets('medium layout uses a navigation rail; it meets guidelines', (tester) async {
    final t = await pumpApp(tester, size: const Size(1000, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await expectMeetsA11yGuidelines(tester);
    await tester.tap(find.descendant(of: find.byType(NavigationRail), matching: find.text('Settings')));
    await pumpFrames(tester);
    expect(t.navigation.current, AppDestination.settings);
  });

  testWidgets('wide layout uses a permanent drawer that reaches every page', (tester) async {
    final t = await pumpApp(tester);
    expect(find.byType(NavigationDrawer), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await tester.tap(find.descendant(of: find.byType(NavigationDrawer), matching: find.text('Settings')));
    await pumpFrames(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(t.navigation.current, AppDestination.settings);
    for (final d in AppDestination.values) {
      t.navigation.goTo(d);
      await pumpFrames(tester, 2);
      expect(find.byType(screenFor(d).runtimeType), findsOneWidget, reason: d.name);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('narrow layout: bottom bar plus a drawer behind "More"', (tester) async {
    final t = await pumpApp(tester, size: narrowSize);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('More'));
    await pumpFrames(tester);
    expect(find.byType(NavigationDrawer), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(NavigationDrawer), matching: find.text('About')));
    await pumpFrames(tester);
    expect(t.navigation.current, AppDestination.about);
    expect(find.byType(AboutScreen), findsOneWidget);
    await tester.tap(find.text('Sources'));
    await pumpFrames(tester);
    expect(t.navigation.current, AppDestination.inputs);
  });

  testWidgets('keyboard shortcuts navigate and open the file picker', (tester) async {
    final t = await pumpApp(tester);
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await pumpFrames(tester, 2);
    }

    await press(LogicalKeyboardKey.comma);
    expect(t.navigation.current, AppDestination.settings);
    await press(LogicalKeyboardKey.digit1);
    expect(t.navigation.current, AppDestination.overview);
    await press(LogicalKeyboardKey.digit7);
    expect(t.navigation.current, AppDestination.issues);
    await press(LogicalKeyboardKey.keyD);
    expect(t.navigation.current, AppDestination.dataSource);
    t.navigation.goTo(AppDestination.about);
    await pumpFrames(tester, 2);
    await press(LogicalKeyboardKey.keyO);
    expect(t.navigation.current, AppDestination.dataSource);
    expect(t.filePicks, 1);
  });

  testWidgets('skip link is first in tab order and moves focus to the content', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester);
    expect(find.text('Skip to main content (Enter)'), findsNothing);
    expect(find.bySemanticsLabel('Skip to main content'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await pumpFrames(tester, 2);
    expect(find.text('Skip to main content (Enter)'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpFrames(tester, 2);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Main content');
    handle.dispose();
  });

  testWidgets('loading demo data from the start page opens the overview', (tester) async {
    final t = await pumpApp(tester);
    final button = find.ancestor(
        of: find.text('Explore demo data'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
    await tester.dragUntilVisible(
        button.hitTestable(),
        find.descendant(of: find.byType(DataSourceScreen), matching: find.byType(Scrollable)).first,
        const Offset(0, -300));
    await tester.tap(button);
    await settleWork(tester, t);
    expect(t.app.hasData, isTrue);
    expect(t.navigation.current, AppDestination.overview);
    expect(find.byType(FilterBar), findsOneWidget);
    expect(find.textContaining('Demo campus'), findsWidgets);
    expect(t.announcements.any((a) => a.startsWith('Loaded ')), isTrue);
  });

  testWidgets('filter bar presets update the analysed window', (tester) async {
    final t = await pumpApp(tester, loadDemo: true, initial: AppDestination.overview);
    await tester.tap(find.text('Dates: All data'));
    await pumpFrames(tester);
    await tester.tap(find.text('Last 7 days'));
    await settleWork(tester, t);
    expect(find.text('Dates: Last 7 days'), findsOneWidget);
    expect(t.app.window!.duration, const Duration(days: 7));
    await tester.tap(find.text('Clear filters'));
    await settleWork(tester, t);
    expect(t.app.filters.isDefault, isTrue);
  });

  testWidgets('reduce motion makes every shell animation instantaneous', (tester) async {
    await pumpApp(tester, reduceMotion: true);
    final ctx = tester.element(find.byType(AppShell));
    expect(Motion.of(ctx).reduced, isTrue);
    expect(Motion.of(ctx).medium, Duration.zero);
    final pageSwitcher = tester.widget<AnimatedSwitcher>(
        find.byWidgetPredicate((w) => w is AnimatedSwitcher && w.child?.key is ValueKey<AppDestination>));
    expect(pageSwitcher.duration, Duration.zero);
    final overlayFade =
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('loading-overlay-fade')));
    expect(overlayFade.duration, Duration.zero);
  });

  testWidgets('animations run normally when motion is allowed', (tester) async {
    await pumpApp(tester, reduceMotion: false);
    final ctx = tester.element(find.byType(AppShell));
    expect(Motion.of(ctx).medium, greaterThan(Duration.zero));
  });

  testWidgets('platform "disable animations" is honoured without the setting', (tester) async {
    await pumpApp(tester, reduceMotion: false);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpFrames(tester, 2);
    final ctx = tester.element(find.byType(AppShell));
    expect(Motion.of(ctx).medium, Duration.zero);
  });

  for (final size in [narrowSize, wideSize]) {
    testWidgets('200% text: no overflow on any page (${size.width.toInt()} wide)', (tester) async {
      final t = await pumpApp(tester, size: size, textScale: 2.0, loadDemo: true);
      final ctx = tester.element(find.byType(AppShell));
      expect(MediaQuery.textScalerOf(ctx).scale(10), 20);
      for (final d in AppDestination.values) {
        t.navigation.goTo(d);
        await pumpFrames(tester, 2);
        expect(tester.takeException(), isNull, reason: d.name);
        // Scroll through long pages to lay out everything.
        final scrollables = find.byType(Scrollable);
        if (scrollables.evaluate().isNotEmpty) {
          await tester.drag(scrollables.last, const Offset(0, -2000), warnIfMissed: false);
          await pumpFrames(tester, 2);
          expect(tester.takeException(), isNull, reason: '${d.name} after scrolling');
        }
      }
    });
  }
}
