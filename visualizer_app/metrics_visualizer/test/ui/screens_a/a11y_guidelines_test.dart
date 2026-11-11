// WCAG checks (text contrast, labelled tap targets, 48 dp tap targets) on
// every screen of this group, light and dark, wide and narrow, with the
// window grown to fit the whole page so every card is checked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';

import 'screens_a_helpers.dart';

void main() {
  final dataset = demoDataset();
  const destinations = [
    AppDestination.overview,
    AppDestination.inputs,
    AppDestination.devices,
    AppDestination.systemUsage,
    AppDestination.rooms,
  ];

  for (final d in destinations) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final size in [wide, narrow]) {
        testWidgets('${d.name} meets guidelines (${mode.name}, ${size.width.toInt()} wide)', (tester) async {
          final handle = tester.ensureSemantics();
          await pumpScreen(tester, d, dataset: dataset, size: size, themeMode: mode);
          await fitWholePage(tester);
          await expectGuidelines(tester);
          handle.dispose();
        });
      }
    }
  }

  testWidgets('room detail meets guidelines (wide master/detail, dark)', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpScreen(
      tester,
      AppDestination.rooms,
      dataset: dataset,
      size: extraWide,
      themeMode: ThemeMode.dark,
      room: 'LIB_120',
    );
    expect(find.text('Room LIB_120'), findsOneWidget);
    await fitWholePage(tester);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('room detail meets guidelines (narrow, light)', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpScreen(tester, AppDestination.rooms, dataset: dataset, size: narrow, room: 'BSS_245');
    expect(find.text('Room BSS_245'), findsOneWidget);
    await fitWholePage(tester);
    await expectGuidelines(tester);
    handle.dispose();
  });

  testWidgets('high contrast theme meets guidelines on the overview', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpScreen(tester, AppDestination.overview, dataset: dataset, highContrast: true);
    await fitWholePage(tester);
    await expectGuidelines(tester);
    handle.dispose();
  });
}
