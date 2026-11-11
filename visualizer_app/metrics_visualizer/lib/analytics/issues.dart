// Result types for pattern detection (the Issues view). Pure Dart.
//
// An issue is a pattern in the data worth reviewing. It states what the data
// shows; it does not say why it happened or what a control does, because
// the analytics engine does not know the room's control program.

import '../data/models.dart';

/// Kind of pattern.
enum IssueType {
  /// System power `Started` opened a session several times in a short
  /// window.
  rapidPowerCycling,

  /// One control was pressed many times in a few seconds.
  repeatedPresses,

  /// Many navigation-control presses in a short window.
  rapidNavigation,

  /// Many source selections in a short window across at least two sources.
  rapidSourceChanges,

  /// One metric changed between `Connected` and `Disconnected` repeatedly.
  connectionFlapping,

  /// A device power session longer than the configured limit.
  longDeviceSession,

  /// No heartbeats or events from a room for longer than the limit.
  heartbeatGap,

  /// Events whose metric contains the word `help`.
  helpEvents,
}

/// How urgent an issue is. Ordered: compare with [index].
enum IssueSeverity { info, warning, critical }

/// Which data an issue's pattern comes from. Used to group and filter
/// issues; it says nothing about the cause.
enum IssueArea {
  /// System power events.
  systemPower,

  /// Control (button, slider, keypad) traces.
  controls,

  /// Source selections.
  sources,

  /// Device `Connected` / `Disconnected` events.
  connectivity,

  /// Device power sessions.
  devices,

  /// Heartbeats and event reporting.
  reporting,

  /// Help-labelled events.
  help,
}

/// One detected pattern. Overlapping detection windows are merged, so a
/// single burst produces a single issue.
class Issue {
  const Issue({
    required this.id,
    required this.type,
    required this.severity,
    required this.area,
    required this.room,
    required this.building,
    required this.start,
    required this.end,
    required this.count,
    required this.title,
    required this.explanation,
    required this.suggestedAction,
    required this.evidence,
    this.subject,
  });

  /// Maximum number of evidence events kept per issue.
  static const int maxEvidence = 50;

  /// Stable, deterministic identifier.
  final String id;
  final IssueType type;
  final IssueSeverity severity;

  /// Which data the pattern comes from.
  final IssueArea area;
  final String room;
  final String building;

  /// Device, control, or connection metric involved, if any, as logged.
  final String? subject;

  /// First and last evidence time (UTC).
  final DateTime start;
  final DateTime end;

  /// Number of qualifying events (or hours, for [IssueType.heartbeatGap]
  /// and [IssueType.longDeviceSession], rounded down).
  final int count;

  /// Short headline, such as "Repeated power cycling in SCI-101".
  final String title;

  /// What the data shows: counts, durations, times and metric names quoted
  /// as logged. No interpretation of intent or of what a control does.
  final String explanation;

  /// Things worth checking when reviewing the pattern. Neutral follow-ups,
  /// not prescriptions.
  final String suggestedAction;

  /// Up to [maxEvidence] supporting events, time-ordered.
  final List<MetricEvent> evidence;

  Duration get duration => end.difference(start);
}
