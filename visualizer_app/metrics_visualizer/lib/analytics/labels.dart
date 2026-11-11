// Plain-language display labels for analytics enums, so every screen uses
// the same wording. Pure Dart.

import 'classifier.dart';
import 'forecast.dart';
import 'issues.dart';
import 'sessions.dart';
import 'usage.dart';

/// Display labels for [IssueType].
extension IssueTypeLabel on IssueType {
  String get label => switch (this) {
    IssueType.rapidPowerCycling => 'Repeated power cycling',
    IssueType.repeatedPresses => 'Repeated presses of one control',
    IssueType.rapidNavigation => 'Rapid navigation presses',
    IssueType.rapidSourceChanges => 'Rapid source changes',
    IssueType.connectionFlapping => 'Repeated connection changes',
    IssueType.longDeviceSession => 'Long device session',
    IssueType.heartbeatGap => 'Heartbeat gap',
    IssueType.helpEvents => 'Help-labelled events',
  };
}

/// Display labels for [IssueSeverity].
extension IssueSeverityLabel on IssueSeverity {
  String get label => switch (this) {
    IssueSeverity.info => 'Info',
    IssueSeverity.warning => 'Warning',
    IssueSeverity.critical => 'Critical',
  };
}

/// Display labels for [IssueArea] (which data a pattern comes from).
extension IssueAreaLabel on IssueArea {
  String get label => switch (this) {
    IssueArea.systemPower => 'System power',
    IssueArea.controls => 'Controls',
    IssueArea.sources => 'Sources',
    IssueArea.connectivity => 'Device communication',
    IssueArea.devices => 'Device power',
    IssueArea.reporting => 'Heartbeats',
    IssueArea.help => 'Help-labelled',
  };
}

/// Display labels for [OffReason].
extension OffReasonLabel on OffReason {
  String get label => switch (this) {
    OffReason.user => 'User',
    OffReason.inactivity => 'Inactivity',
    OffReason.scheduled => 'Schedule',
    OffReason.remote => 'Remote',
    OffReason.other => 'Other reason',
    OffReason.reinitialized => 'Program start',
    OffReason.capped => 'No off event (capped)',
    OffReason.truncated => 'Still on at end of data',
    OffReason.unknown => 'No reason logged',
  };
}

/// Display labels for [PowerSource].
extension PowerSourceLabel on PowerSource {
  String get label => switch (this) {
    PowerSource.user => 'User',
    PowerSource.inactivity => 'Inactivity',
    PowerSource.scheduled => 'Schedule',
    PowerSource.restore => 'Restore',
    PowerSource.remote => 'Remote',
    PowerSource.other => 'Other reason',
    PowerSource.unknown => 'No reason logged',
  };
}

/// Display labels for [TrendDirection].
extension TrendDirectionLabel on TrendDirection {
  String get label => switch (this) {
    TrendDirection.growing => 'Growing',
    TrendDirection.stable => 'Stable',
    TrendDirection.declining => 'Declining',
    TrendDirection.insufficientData => 'Not enough data',
  };
}

/// Display labels for [UnderuseKind].
extension UnderuseKindLabel on UnderuseKind {
  String get label => switch (this) {
    UnderuseKind.rarelyUsedCampus => 'Rarely used campus-wide',
    UnderuseKind.rarelyUsedInRoom => 'Rarely used in this room',
    UnderuseKind.neverUsedInRoom => 'Never used in this room',
  };
}

/// Display labels for [EventCategory].
extension EventCategoryLabel on EventCategory {
  String get label => switch (this) {
    EventCategory.input => 'Source',
    EventCategory.device => 'Device power',
    EventCategory.systemPower => 'System power',
    EventCategory.lifecycle => 'Processor lifecycle',
    EventCategory.help => 'Help-labelled',
    EventCategory.mute => 'Mute',
    EventCategory.volume => 'Volume',
    EventCategory.share => 'Wireless share',
    EventCategory.uiTrace => 'Control',
    EventCategory.connection => 'Device communication',
    EventCategory.adminLifecycle => 'Server maintenance',
    EventCategory.heartbeat => 'Heartbeat',
    EventCategory.other => 'Other',
  };
}

/// Weekday names, index 0 = Monday (matches [DateTime.weekday] - 1).
const List<String> weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Short weekday names, index 0 = Monday.
const List<String> weekdayShortNames = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];
