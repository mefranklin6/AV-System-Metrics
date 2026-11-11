import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/connectivity_screen.dart';
import 'package:metrics_visualizer/ui/screens/forecast_screen.dart';
import 'package:metrics_visualizer/ui/screens/issues_screen.dart';

import 'screens_b_helpers.dart';

/// A tall window so most of each page is on screen for the guideline checks.
const Size tallWide = Size(1400, 2600);

const Map<AppDestination, Type> screens = {
  AppDestination.connectivity: ConnectivityScreen,
  AppDestination.issues: IssuesScreen,
  AppDestination.forecast: ForecastScreen,
};

void main() {
  for (final entry in screens.entries) {
    final dest = entry.key;
    group('${dest.label} screen', () {
      for (final mode in [ThemeMode.light, ThemeMode.dark]) {
        testWidgets('meets accessibility guidelines (${mode.name})', (tester) async {
          await pumpWithData(tester, dataset: demoDataset(10), initial: dest, size: tallWide, themeMode: mode);
          expect(find.byType(entry.value), findsOneWidget);
          await expectMeetsA11yGuidelines(tester);
          await scrollThroughPage(tester);
          await expectMeetsA11yGuidelines(tester);
        });
      }

      testWidgets('meets accessibility guidelines in high contrast', (tester) async {
        await pumpWithData(tester,
            dataset: demoDataset(10), initial: dest, size: tallWide, themeMode: ThemeMode.dark, highContrast: true);
        await expectMeetsA11yGuidelines(tester);
      });

      for (final size in [narrowSize, wideSize]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('renders without overflow at ${size.width.toInt()} px, text ${scale}x', (tester) async {
            await pumpWithData(tester, dataset: demoDataset(10), initial: dest, size: size, textScale: scale);
            expect(find.byType(entry.value), findsOneWidget);
            await scrollThroughPage(tester);
            expect(tester.takeException(), isNull);
          });
        }
      }

      testWidgets('renders with animations enabled', (tester) async {
        await pumpWithData(tester, dataset: demoDataset(10), initial: dest, reduceMotion: false);
        await tester.pump(const Duration(seconds: 1));
        await scrollThroughPage(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      });

      testWidgets('renders a short range with every chart in table view', (tester) async {
        await pumpWithData(tester, dataset: demoDataset(2), initial: dest, size: tallWide);
        // Open every chart's table view that is built, then check again.
        for (var i = 0; i < 6; i++) {
          final toggles = find.text('View as table');
          if (toggles.evaluate().isEmpty) break;
          await tester.tap(toggles.first);
          await tester.pump();
        }
        await expectMeetsA11yGuidelines(tester);
        await scrollThroughPage(tester);
        expect(tester.takeException(), isNull);
      });
    });
  }
}
