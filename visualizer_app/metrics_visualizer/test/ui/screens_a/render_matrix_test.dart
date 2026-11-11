// Every screen in this group renders without exceptions or overflow at
// 100% and 200% text, 320 and 360 dp and wide, light and dark, with the
// demo campus loaded and analysed by the real engine. The whole page is
// scrolled through so lazily built cards are laid out too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/state/navigation_state.dart';
import 'package:metrics_visualizer/ui/screens/devices_screen.dart';
import 'package:metrics_visualizer/ui/screens/inputs_screen.dart';
import 'package:metrics_visualizer/ui/screens/overview_screen.dart';
import 'package:metrics_visualizer/ui/screens/rooms_screen.dart';
import 'package:metrics_visualizer/ui/screens/system_usage_screen.dart';
import 'package:metrics_visualizer/ui/widgets/widgets.dart';

import 'screens_a_helpers.dart';

const screens = {
  AppDestination.overview: OverviewScreen,
  AppDestination.inputs: InputsScreen,
  AppDestination.devices: DevicesScreen,
  AppDestination.systemUsage: SystemUsageScreen,
  AppDestination.rooms: RoomsScreen,
};

typedef Variant = ({Size size, ThemeMode mode, double scale});

const List<Variant> variants = [
  (size: wide, mode: ThemeMode.light, scale: 1.0),
  (size: wide, mode: ThemeMode.dark, scale: 2.0),
  (size: narrow, mode: ThemeMode.light, scale: 2.0),
  (size: narrow, mode: ThemeMode.dark, scale: 1.0),
  // WCAG 1.4.10 reflow: 320 CSS px wide.
  (size: Size(320, 640), mode: ThemeMode.light, scale: 1.0),
];

void main() {
  final dataset = demoDataset();

  for (final entry in screens.entries) {
    for (final v in variants) {
      testWidgets('${entry.key.name} renders (${v.size.width.toInt()} wide, ${v.mode.name}, text ${v.scale}x)', (
        tester,
      ) async {
        await pumpScreen(tester, entry.key, dataset: dataset, size: v.size, themeMode: v.mode, textScale: v.scale);
        expect(find.byType(entry.value), findsOneWidget);
        expect(find.byType(AnalysisPage), findsOneWidget);
        expect(find.text('No data loaded'), findsNothing);
        await scrollThroughPage(tester);
      });
    }
  }

  for (final v in variants) {
    testWidgets('room drill-down renders (${v.size.width.toInt()} wide, ${v.mode.name}, text ${v.scale}x)', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        AppDestination.rooms,
        dataset: dataset,
        size: v.size,
        themeMode: v.mode,
        textScale: v.scale,
        room: 'BSS_245',
      );
      // Built, though at 200% text on a phone it may start below the fold.
      expect(find.text('Room BSS_245', skipOffstage: false), findsOneWidget);
      await scrollThroughPage(tester);
    });
  }
}
