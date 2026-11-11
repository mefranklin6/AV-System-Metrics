import 'package:flutter_test/flutter_test.dart';
import 'package:metrics_visualizer/analytics/analytics.dart';

import 'helpers.dart';

const room = 'BSS_245';

DateTime at(int hour, [int minute = 0, int second = 0]) =>
    monday.add(Duration(hours: hour, minutes: minute, seconds: second));

List<Issue> issuesOf(
  List<MetricEvent> events, {
  AnalysisConfig config = utcConfig,
  List<HeartbeatBucket> heartbeats = const [],
  DateTime? start,
  DateTime? end,
}) {
  return analyze(
    ds(
      events,
      heartbeats: heartbeats,
      start: start ?? monday,
      end: end ?? monday.add(const Duration(days: 2)),
    ),
    config,
  ).issues;
}

List<Issue> ofType(List<Issue> all, IssueType t) =>
    all.where((i) => i.type == t).toList();

/// Power on/off pairs starting at [times]; each on lasts 30 s.
List<MetricEvent> cycles(List<DateTime> times) => [
  for (final t in times) ...[
    ev(room, t, 'System - User', 'Started'),
    ev(room, t.add(const Duration(seconds: 30)), 'System - User', 'Stopped'),
  ],
];

List<MetricEvent> presses(
  String control,
  DateTime start,
  int n,
  Duration step, {
  bool withTaps = false,
}) => [
  for (var i = 0; i < n; i++) ...[
    ev(room, start.add(step * i), '$control Pressed', 'Trace'),
    if (withTaps) ev(room, start.add(step * i), '$control Tapped', 'Trace'),
  ],
];

void main() {
  group('rapid power cycling', () {
    test('fires at exactly count within the window (inclusive)', () {
      final i = ofType(
        issuesOf(cycles([at(9), at(9, 5), at(9, 10)])),
        IssueType.rapidPowerCycling,
      );
      expect(i, hasLength(1));
      expect(i.single.count, 3);
      expect(i.single.severity, IssueSeverity.warning);
      expect(i.single.area, IssueArea.systemPower);
      expect(i.single.start, at(9));
      expect(i.single.end, at(9, 10));
      expect(i.single.evidence, isNotEmpty);
      expect(i.single.explanation, contains('3 times'));
    });

    test('does not fire one second outside the window', () {
      expect(
        ofType(
          issuesOf(cycles([at(9), at(9, 5), at(9, 10, 1)])),
          IssueType.rapidPowerCycling,
        ),
        isEmpty,
      );
    });

    test('does not fire below the count', () {
      expect(
        ofType(
          issuesOf(cycles([at(9), at(9, 1)])),
          IssueType.rapidPowerCycling,
        ),
        isEmpty,
      );
    });

    test('overlapping windows merge into one issue; critical at 2x', () {
      final i = ofType(
        issuesOf(cycles([for (var k = 0; k < 6; k++) at(9, k * 4)])),
        IssueType.rapidPowerCycling,
      );
      expect(i, hasLength(1));
      expect(i.single.count, 6);
      expect(i.single.severity, IssueSeverity.critical);
    });

    test('separate bursts are separate issues', () {
      final i = ofType(
        issuesOf(
          cycles([
            at(9), at(9, 1), at(9, 2), //
            at(14), at(14, 1), at(14, 2),
          ]),
        ),
        IssueType.rapidPowerCycling,
      );
      expect(i, hasLength(2));
      expect(i[0].id, isNot(i[1].id));
    });
  });

  group('repeated presses', () {
    test('fires at 6 presses of the same control in 10 s', () {
      final i = ofType(
        issuesOf(
          presses('Btn_Video_Mute', at(9), 6, const Duration(seconds: 2)),
        ),
        IssueType.repeatedPresses,
      );
      expect(i, hasLength(1));
      expect(i.single.subject, 'Btn_Video_Mute');
      expect(i.single.count, 6);
      expect(i.single.area, IssueArea.controls);
    });

    test('5 presses do not fire, and Tapped is not double counted', () {
      expect(
        ofType(
          issuesOf(
            presses(
              'Btn_Video_Mute',
              at(9),
              5,
              const Duration(seconds: 1),
              withTaps: true,
            ),
          ),
          IssueType.repeatedPresses,
        ),
        isEmpty,
      );
    });

    test('presses spread just beyond the window do not fire', () {
      // 6 presses spanning 10.5 s.
      expect(
        ofType(
          issuesOf(
            presses(
              'Btn_Video_Mute',
              at(9),
              6,
              const Duration(milliseconds: 2100),
            ),
          ),
          IssueType.repeatedPresses,
        ),
        isEmpty,
      );
    });

    test('different controls are not combined', () {
      expect(
        ofType(
          issuesOf([
            ...presses('Btn_A', at(9), 3, const Duration(seconds: 1)),
            ...presses('Btn_B', at(9), 3, const Duration(seconds: 1)),
          ]),
          IssueType.repeatedPresses,
        ),
        isEmpty,
      );
    });

    test('repeatable controls need 3x the presses', () {
      expect(
        ofType(
          issuesOf(
            presses(
              'Btn_Volume_Up',
              at(9),
              17,
              const Duration(milliseconds: 500),
            ),
          ),
          IssueType.repeatedPresses,
        ),
        isEmpty,
      );
      expect(
        ofType(
          issuesOf(
            presses(
              'Btn_Volume_Up',
              at(9),
              18,
              const Duration(milliseconds: 500),
            ),
          ),
          IssueType.repeatedPresses,
        ),
        hasLength(1),
      );
    });

    test('evidence is capped at 50 events', () {
      final i = ofType(
        issuesOf(
          presses(
            'Btn_Video_Mute',
            at(9),
            120,
            const Duration(milliseconds: 100),
          ),
        ),
        IssueType.repeatedPresses,
      );
      expect(i.single.count, 120);
      expect(i.single.evidence, hasLength(Issue.maxEvidence));
      expect(i.single.severity, IssueSeverity.critical);
    });
  });

  group('rapid navigation', () {
    test('8 navigation presses in 30 s fire; 7 do not', () {
      List<MetricEvent> nav(int n) => [
        for (var k = 0; k < n; k++)
          ev(
            room,
            at(9, 0, k * 4),
            k.isEven ? 'Btn_Back Pressed' : 'Btn_Cam_Nav Pressed',
            'Trace',
          ),
      ];
      final i = ofType(issuesOf(nav(8)), IssueType.rapidNavigation);
      expect(i, hasLength(1));
      expect(i.single.area, IssueArea.controls);
      expect(i.single.severity, IssueSeverity.info);
      expect(ofType(issuesOf(nav(7)), IssueType.rapidNavigation), isEmpty);
    });

    test('non-navigation presses do not count', () {
      final events = [
        for (var k = 0; k < 10; k++)
          ev(room, at(9, 0, k * 2), 'Btn_Source_$k Pressed', 'Trace'),
      ];
      expect(ofType(issuesOf(events), IssueType.rapidNavigation), isEmpty);
    });
  });

  group('rapid source changes', () {
    List<MetricEvent> inputs(List<String> keys, Duration step) => [
      for (var k = 0; k < keys.length; k++)
        ev(room, at(9).add(step * k), keys[k], 'Started'),
    ];

    test('5 changes across inputs within 2 minutes fire', () {
      final i = ofType(
        issuesOf(
          inputs([
            'pc',
            'hdmi',
            'pc',
            'usb',
            'hdmi',
          ], const Duration(seconds: 30)),
        ),
        IssueType.rapidSourceChanges,
      );
      expect(i, hasLength(1));
      expect(i.single.explanation, contains('HDMI'));
    });

    test('4 changes do not fire', () {
      expect(
        ofType(
          issuesOf(
            inputs(['pc', 'hdmi', 'pc', 'usb'], const Duration(seconds: 30)),
          ),
          IssueType.rapidSourceChanges,
        ),
        isEmpty,
      );
    });

    test('re-selecting the same input is not hunting', () {
      expect(
        ofType(
          issuesOf(inputs(List.filled(6, 'pc'), const Duration(seconds: 10))),
          IssueType.rapidSourceChanges,
        ),
        isEmpty,
      );
    });

    test('changes spread beyond the window do not fire', () {
      expect(
        ofType(
          issuesOf(
            inputs([
              'pc',
              'hdmi',
              'pc',
              'usb',
              'hdmi',
            ], const Duration(seconds: 31)),
          ),
          IssueType.rapidSourceChanges,
        ),
        isEmpty,
      );
    });
  });

  group('repeated connection changes', () {
    List<MetricEvent> flaps(String target, int n, Duration step) => [
      for (var k = 0; k < n; k++)
        ev(
          room,
          at(9).add(step * k),
          target,
          k.isEven ? 'Disconnected' : 'Connected',
        ),
    ];

    test('4 changes within 15 minutes fire', () {
      final i = ofType(
        issuesOf(flaps('Projector_1', 4, min(5))),
        IssueType.connectionFlapping,
      );
      expect(i, hasLength(1));
      expect(i.single.subject, 'Projector_1');
      expect(i.single.area, IssueArea.connectivity);
    });

    test('3 changes do not fire; targets are not combined', () {
      expect(
        ofType(
          issuesOf(flaps('Projector_1', 3, min(1))),
          IssueType.connectionFlapping,
        ),
        isEmpty,
      );
      expect(
        ofType(
          issuesOf([
            ...flaps('Projector_1', 2, min(1)),
            ...flaps('Switcher', 2, min(1)),
          ]),
          IssueType.connectionFlapping,
        ),
        isEmpty,
      );
    });
  });

  group('long device sessions', () {
    List<MetricEvent> session(Duration length) => [
      ev(room, at(1), 'Projector_1', 'Started'),
      ev(room, at(1).add(length), 'Projector_1', 'Stopped'),
    ];

    test('exactly the threshold does not fire; just over does', () {
      expect(
        ofType(issuesOf(session(hrs(12))), IssueType.longDeviceSession),
        isEmpty,
      );
      final i = ofType(
        issuesOf(session(hrs(12) + const Duration(seconds: 1))),
        IssueType.longDeviceSession,
      );
      expect(i, hasLength(1));
      expect(i.single.severity, IssueSeverity.warning);
      expect(i.single.area, IssueArea.devices);
      expect(i.single.evidence, hasLength(2));
    });

    test('twice the threshold is critical (when the cap allows it)', () {
      final i = ofType(
        issuesOf(
          session(hrs(25)),
          config: utcConfig.copyWith(maxSessionLength: hrs(48)),
          end: monday.add(const Duration(days: 3)),
        ),
        IssueType.longDeviceSession,
      );
      expect(i.single.severity, IssueSeverity.critical);
    });

    test('a capped session is reported as info', () {
      final i = ofType(
        issuesOf([ev(room, at(1), 'Projector_1', 'Started')]),
        IssueType.longDeviceSession,
      );
      expect(i.single.severity, IssueSeverity.info);
      expect(i.single.explanation, contains('no Stopped was logged'));
    });

    test('a real Stopped after the session limit gives a critical issue', () {
      // Default limit 16 h; the projector really ran for 30 h.
      final i = ofType(
        issuesOf(session(hrs(30)), end: monday.add(const Duration(days: 3))),
        IssueType.longDeviceSession,
      );
      expect(i.single.severity, IssueSeverity.critical);
      expect(i.single.end, at(31));
      expect(i.single.explanation, contains('was on for 30 hours from Started to Stopped'));
    });

    test('20 hours with a real Stopped is a warning', () {
      final i = ofType(
        issuesOf(session(hrs(20))),
        IssueType.longDeviceSession,
      );
      expect(i.single.severity, IssueSeverity.warning);
    });
  });

  group('startup default source', () {
    test('is not part of input hunting', () {
      // Power-on selects PC automatically, then 4 real changes in 2 minutes.
      final i = ofType(
        issuesOf([
          ev(room, at(9), 'System - User', 'Started'),
          ev(room, at(9, 0, 3), 'pc', 'Started'),
          ev(room, at(9, 0, 5), 'System Startup Sequence Complete', 'Trace'),
          ev(room, at(9, 0, 30), 'hdmi', 'Started'),
          ev(room, at(9, 1), 'usb', 'Started'),
          ev(room, at(9, 1, 30), 'hdmi', 'Started'),
          ev(room, at(9, 2), 'pc', 'Started'),
        ]),
        IssueType.rapidSourceChanges,
      );
      expect(i, isEmpty);
    });
  });

  group('connection flapping with repeated reports', () {
    test('a repeated state is not counted as a change', () {
      // Two touch panel drops: Disconnected, Connected, Connected (the
      // template reports "Online" twice). 6 events but 4 changes.
      final events = [
        for (final m in [0, 5])
          ...[
            ev(room, at(9, m), 'TouchPanel_1', 'Disconnected'),
            ev(room, at(9, m + 1), 'TouchPanel_1', 'Connected'),
            ev(room, at(9, m + 1, 10), 'TouchPanel_1', 'Connected'),
          ],
      ];
      final r = analyze(
        ds(events, start: monday, end: monday.add(const Duration(days: 1))),
        utcConfig,
      );
      final flaps = ofType(r.issues, IssueType.connectionFlapping);
      expect(flaps.single.count, 4);
      expect(flaps.single.severity, IssueSeverity.warning);
      final target = r.connectivity.rooms.single.targets.single;
      expect(target.connects, 2);
      expect(target.disconnects, 2);
      expect(target.lastChange, at(9, 6));
      expect(r.connectivity.events, hasLength(6));
    });
  });

  group('heartbeat gaps', () {
    List<HeartbeatBucket> hb(String client, Set<int> missing, int hours) => [
      for (var h = 0; h < hours; h++)
        if (!missing.contains(h))
          HeartbeatBucket(
            clientName: client,
            hourStart: monday.add(Duration(hours: h)),
            count: 12,
          ),
    ];

    test('a gap longer than the threshold fires; equal does not', () {
      final end = monday.add(const Duration(hours: 24));
      final fired = ofType(
        issuesOf(
          const [],
          heartbeats: [
            ...hb('A_1', {}, 24),
            ...hb('B_1', {5, 6, 7}, 24),
          ],
          end: end,
        ),
        IssueType.heartbeatGap,
      );
      expect(fired, hasLength(1));
      expect(fired.single.room, 'B_1');
      expect(fired.single.start, monday.add(const Duration(hours: 5)));
      expect(fired.single.end, monday.add(const Duration(hours: 8)));
      expect(fired.single.severity, IssueSeverity.warning);
      final notFired = ofType(
        issuesOf(
          const [],
          heartbeats: [
            ...hb('A_1', {}, 24),
            ...hb('B_1', {5, 6}, 24),
          ],
          end: end,
        ),
        IssueType.heartbeatGap,
      );
      expect(notFired, isEmpty);
    });

    test('silence until the end of coverage is critical', () {
      final i = ofType(
        issuesOf(
          const [],
          heartbeats: [
            ...hb('A_1', {}, 24),
            ...hb('B_1', {for (var h = 20; h < 24; h++) h}, 24),
          ],
          end: monday.add(const Duration(hours: 24)),
        ),
        IssueType.heartbeatGap,
      );
      expect(i.single.severity, IssueSeverity.critical);
      expect(i.single.title, contains('No heartbeats from'));
    });

    test('events count as signs of life', () {
      final i = ofType(
        issuesOf(
          [ev('B_1', at(6, 10), 'pc', 'Started')],
          heartbeats: [
            ...hb('A_1', {}, 24),
            ...hb('B_1', {5, 6, 7}, 24),
          ],
          end: monday.add(const Duration(hours: 24)),
        ),
        IssueType.heartbeatGap,
      );
      expect(i, isEmpty);
    });
  });

  group('help-labelled events', () {
    test('single request is info; three within an hour is one warning', () {
      final single = ofType(
        issuesOf([ev(room, at(9), 'Help', 'Started')]),
        IssueType.helpEvents,
      );
      expect(single.single.severity, IssueSeverity.info);
      final three = ofType(
        issuesOf([
          ev(room, at(9), 'Help', 'Started'),
          ev(room, at(9, 1), 'Help', 'Stopped'),
          ev(room, at(9, 20), 'Help', 'Started'),
          ev(room, at(9, 50), 'Help', 'Started'),
        ]),
        IssueType.helpEvents,
      );
      expect(three, hasLength(1));
      expect(three.single.count, 4);
      expect(three.single.severity, IssueSeverity.warning);
    });

    test('requests two hours apart are separate issues', () {
      expect(
        ofType(
          issuesOf([
            ev(room, at(9), 'Help', 'Started'),
            ev(room, at(11), 'Help', 'Started'),
          ]),
          IssueType.helpEvents,
        ),
        hasLength(2),
      );
    });
  });

  group('help-labelled events (any action, word "help" in the metric)', () {
    test('Trace presses, custom actions and Started all count', () {
      final i = ofType(
        issuesOf([
          ev(room, at(9), 'Help Pressed', 'Trace'),
          ev(room, at(9, 5), 'Btn_Help', 'Trace'),
          ev(room, at(9, 10), 'Room Help', 'Requested'),
        ]),
        IssueType.helpEvents,
      );
      expect(i.single.count, 3);
      expect(i.single.area, IssueArea.help);
      expect(i.single.explanation, contains('"Help Pressed" Trace x1'));
    });

    test('words that only contain "help" do not count', () {
      expect(
        ofType(
          issuesOf([ev(room, at(9), 'Helper Display', 'Trace')]),
          IssueType.helpEvents,
        ),
        isEmpty,
      );
    });
  });

  test('issue text states data only, without assumptions', () {
    final issues = issuesOf(
      [
        ...cycles([at(9), at(9, 1), at(9, 2)]),
        ...presses('Btn_Video_Mute', at(10), 8, const Duration(seconds: 1)),
        for (var k = 0; k < 9; k++)
          ev(room, at(11).add(Duration(seconds: k * 2)), 'Btn_Back Pressed', 'Trace'),
        for (var k = 0; k < 6; k++)
          ev(room, at(12).add(Duration(seconds: k * 10)), k.isEven ? 'pc' : 'hdmi', 'Started'),
        for (var k = 0; k < 6; k++)
          ev(room, at(13).add(Duration(minutes: k)), 'Projector_1', k.isEven ? 'Disconnected' : 'Connected'),
        ev(room, at(14), 'Help', 'Started'),
        ev(room, at(15), 'Projector_1', 'Started'),
        ev(room, at(40), 'Projector_1', 'Stopped'),
      ],
      config: utcConfig.copyWith(maxSessionLength: hrs(48)),
      end: monday.add(const Duration(days: 3)),
    );
    expect(
      {for (final i in issues) i.type},
      containsAll([
        IssueType.rapidPowerCycling,
        IssueType.repeatedPresses,
        IssueType.rapidNavigation,
        IssueType.rapidSourceChanges,
        IssueType.connectionFlapping,
        IssueType.helpEvents,
        IssueType.longDeviceSession,
      ]),
    );
    final banned = RegExp(
      r'help ?desk|service desk|ticket|training|confus|struggl|lost|'
      r'stuck|frustrat|could not find|did not know|users? (are|were)|'
      r'unresponsive|requested help|help page|people usually',
      caseSensitive: false,
    );
    for (final i in issues) {
      for (final text in [i.title, i.explanation, i.suggestedAction]) {
        expect(banned.hasMatch(text), isFalse, reason: '${i.type}: $text');
      }
    }
  });

  test('custom thresholds are honoured', () {
    final cfg = utcConfig.copyWith(
      thresholds: const IssueThresholds(buttonMashCount: 3),
    );
    expect(
      ofType(
        issuesOf(
          presses('Btn_X', at(9), 3, const Duration(seconds: 1)),
          config: cfg,
        ),
        IssueType.repeatedPresses,
      ),
      hasLength(1),
    );
  });

  test('issue counts flow into overview and room summaries', () {
    final r = analyze(
      ds(
        [
          ...cycles([at(9), at(9, 1), at(9, 2)]),
          ev(room, at(10), 'Help', 'Started'),
        ],
        start: monday,
        end: monday.add(const Duration(days: 1)),
      ),
      utcConfig,
    );
    expect(r.overview.issueCounts[IssueSeverity.warning], 1);
    expect(r.overview.issueCounts[IssueSeverity.info], 1);
    expect(r.overview.issueTotal, 2);
    expect(r.roomSummary(room)!.issueTotal, 2);
    expect(r.issuesForRoom(room), hasLength(2));
  });
}
