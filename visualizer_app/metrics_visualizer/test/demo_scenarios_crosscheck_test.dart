// Cross-check between the demo generator and the analytics engine: every
// room that DemoScenario says carries an injected pattern must be flagged
// with the matching issue type, and the burst detectors must not flag other
// rooms. Rooms using the recommended names and rooms using the legacy
// ("also recognized") names must both be fully recognized. The demo is what evaluators and screenshots use, so a detector or
// generator change that silently breaks a scenario should fail here.

import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';
import 'package:metrics_visualizer/data/demo_data.dart';

void main() {
  final end = DateTime.utc(2026, 11, 10);

  /// The issue each scenario room was generated to show.
  const expected = <String, IssueType>{
    DemoScenario.rapidPowerCycling: IssueType.rapidPowerCycling,
    DemoScenario.repeatedPresses: IssueType.repeatedPresses,
    DemoScenario.rapidNavigation: IssueType.rapidNavigation,
    DemoScenario.rapidSourceChanges: IssueType.rapidSourceChanges,
    DemoScenario.connectionFlapping: IssueType.connectionFlapping,
    DemoScenario.longDeviceSession: IssueType.longDeviceSession,
    DemoScenario.heartbeatGapRoom: IssueType.heartbeatGap,
    DemoScenario.outageRoom: IssueType.heartbeatGap,
    DemoScenario.helpEvents: IssueType.helpEvents,
  };

  /// Detectors for patterns that only the scenario room should show.
  const exclusive = {
    IssueType.rapidPowerCycling,
    IssueType.repeatedPresses,
    IssueType.rapidNavigation,
    IssueType.rapidSourceChanges,
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

      test('every demo event is recognized, in both naming styles', () {
        expect(result.dataQuality.unclassifiedTotal, 0);
        for (final room in [...demoLegacyRooms, 'SCI_101']) {
          final s = result.sessions[room]!;
          expect(s.system, isNotEmpty, reason: room);
          expect(s.devices, isNotEmpty, reason: room);
          expect(s.inputs, isNotEmpty, reason: room);
          expect(s.mutes, isNotEmpty, reason: room);
        }
        // Recommended-name rooms log an automatic default source.
        expect(result.sessions['SCI_101']!.automaticInputStarts, isNotEmpty);
        // The legacy "System - User Reset" Started while on is a marker only.
        expect(result.sessions[DemoScenario.startedWhileOnRoom]!.duplicateStarts, greaterThan(0));
        expect(result.system.offReasons[OffReason.remote], greaterThan(0));
      });

      test('the active learning room (four stations) shows no rapid source changes', () {
        final types = {for (final i in result.issuesForRoom(DemoScenario.activeLearningRoom)) i.type};
        expect(types, isNot(contains(IssueType.rapidSourceChanges)));
      });

      test('the help-labelled events room stands out', () {
        int helpIn(String room) =>
            result.issuesForRoom(room).where((i) => i.type == IssueType.helpEvents).length;
        final busiest = demoRooms.reduce((a, b) => helpIn(a) >= helpIn(b) ? a : b);
        expect(busiest, DemoScenario.helpEvents);
      });
    });
  }
}
