// Cross-check between the demo generator and the analytics engine: every
// room that DemoScenario says carries an injected problem must be flagged
// with the matching issue type, and the burst detectors must not flag other
// rooms. The demo is what evaluators and screenshots use, so a detector or
// generator change that silently breaks a scenario should fail here.

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/data/demo_data.dart';

void main() {
  final end = DateTime.utc(2026, 11, 10);

  /// The issue each scenario room was generated to show.
  const expected = <String, IssueType>{
    DemoScenario.rapidPowerCycling: IssueType.rapidPowerCycling,
    DemoScenario.buttonMashing: IssueType.buttonMashing,
    DemoScenario.navigationThrash: IssueType.navigationThrash,
    DemoScenario.inputHunting: IssueType.inputHunting,
    DemoScenario.connectionFlapping: IssueType.connectionFlapping,
    DemoScenario.deviceLeftOn: IssueType.deviceLeftOn,
    DemoScenario.offlineRoom: IssueType.offlineRoom,
    DemoScenario.outageRoom: IssueType.offlineRoom,
    DemoScenario.helpRequests: IssueType.helpRequest,
  };

  /// Detectors for patterns that only the scenario room should show.
  const exclusive = {
    IssueType.rapidPowerCycling,
    IssueType.buttonMashing,
    IssueType.navigationThrash,
    IssueType.inputHunting,
    IssueType.connectionFlapping,
  };

  for (final useLocalTime in [false, true]) {
    group('demo dataset (${useLocalTime ? 'local time' : 'UTC'} buckets)', () {
      late AnalysisResult result;
      setUpAll(() {
        result = analyze(generateDemoDataset(end: end), AnalysisConfig(useLocalTime: useLocalTime));
      });

      for (final MapEntry(key: room, value: type) in expected.entries) {
        test('$room is flagged for ${type.name}', () {
          final types = {for (final i in result.issuesForRoom(room)) i.type};
          expect(types, contains(type), reason: '$room issues: $types');
        });
      }

      test('the burst detectors flag only their scenario room', () {
        for (final type in exclusive) {
          final rooms = {for (final i in result.issues) if (i.type == type) i.room};
          final scenarioRoom = expected.entries.firstWhere((e) => e.value == type).key;
          expect(rooms, {scenarioRoom}, reason: type.name);
        }
      });

      test('the active learning room (four stations) is not mistaken for input hunting', () {
        final types = {for (final i in result.issuesForRoom(DemoScenario.activeLearningRoom)) i.type};
        expect(types, isNot(contains(IssueType.inputHunting)));
      });

      test('the help request room stands out', () {
        int helpIn(String room) =>
            result.issuesForRoom(room).where((i) => i.type == IssueType.helpRequest).length;
        final busiest = demoRooms.reduce((a, b) => helpIn(a) >= helpIn(b) ? a : b);
        expect(busiest, DemoScenario.helpRequests);
      });
    });
  }
}
