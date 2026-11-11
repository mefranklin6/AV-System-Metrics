// Result types for source, device, system, control and audio usage.
// Pure Dart.

import 'config.dart';
import 'series.dart';
import 'sessions.dart';

// ---------------------------------------------------------------- Inputs

/// Usage of one source within some scope (campus, building or room).
class InputShare {
  const InputShare({
    required this.key,
    required this.label,
    required this.selections,
    required this.hours,
    required this.selectionShare,
    required this.timeShare,
    required this.roomCount,
  });

  /// Normalised source key, such as `hdmi 1` or `pc`.
  final String key;

  /// Display label, such as `HDMI 1` or `PC`.
  final String label;

  /// Number of times the source was selected (`Started` or `Trace`; the
  /// automatic default source at power-on is not counted).
  final int selections;

  /// Time on screen in hours: from selection until another source, the
  /// source's `Stopped`, power-off, a program start, or the session cap.
  final double hours;

  /// [selections] / all selections in the scope (0-1).
  final double selectionShare;

  /// [hours] / all input hours in the scope (0-1).
  final double timeShare;

  /// Rooms in the scope where the input was selected at least once.
  final int roomCount;
}

/// Why an input is listed as a possible removal candidate.
enum UnderuseKind {
  /// Campus-wide share of both selections and time is below
  /// [InputUsage.underusedShareThreshold].
  rarelyUsedCampus,

  /// In this room the input's share of both selections and time is below
  /// [InputUsage.underusedShareThreshold] (room has enough data).
  rarelyUsedInRoom,

  /// Other rooms in the same building use this input but this room never
  /// selected it during the period. If it is installed, it went unused.
  neverUsedInRoom,
}

/// An input that is rarely or never used, as a design/budget hint.
class UnderusedInput {
  const UnderusedInput({
    required this.key,
    required this.label,
    required this.kind,
    required this.selections,
    required this.hours,
    required this.selectionShare,
    required this.timeShare,
    required this.reason,
    this.room,
    this.building,
  });

  final String key;
  final String label;
  final UnderuseKind kind;

  /// Room, for room-level kinds; `null` for campus-wide.
  final String? room;
  final String? building;
  final int selections;
  final double hours;
  final double selectionShare;
  final double timeShare;

  /// Plain-language reason, suitable for display.
  final String reason;
}

/// Video input popularity, campus-wide and broken down.
class InputUsage {
  const InputUsage({
    required this.campus,
    required this.byBuilding,
    required this.byRoom,
    required this.underused,
    required this.totalSelections,
    required this.totalHours,
  });

  /// A share below this (2 %) of both selections and time counts as
  /// "rarely used".
  static const double underusedShareThreshold = 0.02;

  /// Rooms need at least this many selections before room-level underuse
  /// is reported.
  static const int minRoomSelectionsForUnderuse = 20;

  /// All inputs, most time on screen first.
  final List<InputShare> campus;

  /// Building code -> inputs (most time first).
  final Map<String, List<InputShare>> byBuilding;

  /// Room -> inputs (most time first).
  final Map<String, List<InputShare>> byRoom;

  /// Removal candidates, campus-wide entries first.
  final List<UnderusedInput> underused;

  final int totalSelections;
  final double totalHours;

  /// Input with the most time on screen, if any.
  InputShare? get mostUsedByTime => campus.isEmpty ? null : campus.first;

  /// Input selected most often, if any.
  InputShare? get mostUsedBySelections {
    InputShare? best;
    for (final s in campus) {
      if (best == null || s.selections > best.selections) best = s;
    }
    return best;
  }
}

// ---------------------------------------------------------------- Devices

/// On-time statistics for one physical device (room + device id).
class DeviceStat {
  const DeviceStat({
    required this.room,
    required this.building,
    required this.deviceId,
    required this.deviceType,
    required this.sessions,
    required this.onHours,
    required this.averageSessionHours,
    required this.longestSessionHours,
    required this.leftOnSessions,
    required this.unterminatedSessions,
    required this.onAtEnd,
    required this.daily,
    required this.weekly,
  });

  final String room;
  final String building;

  /// Device metric, such as `Projector 1`.
  final String deviceId;

  /// Upper-case type, such as `PROJECTOR`.
  final String deviceType;

  /// `room/deviceId`, unique across the campus.
  String get key => '$room/$deviceId';

  final int sessions;

  /// Observed on-hours in the period.
  final double onHours;
  final double averageSessionHours;
  final double longestSessionHours;

  /// Sessions longer than [IssueThresholds.deviceLeftOnHours].
  final int leftOnSessions;

  /// Sessions closed by the session cap (no `Stopped` seen).
  final int unterminatedSessions;

  /// Still on when the data ends.
  final bool onAtEnd;

  /// On-hours per calendar day (dense, every day of the range).
  final List<SeriesPoint> daily;

  /// On-hours per Monday-based week (dense).
  final List<SeriesPoint> weekly;
}

/// Totals for one device type (all projectors, all cameras, ...).
class DeviceTypeStat {
  const DeviceTypeStat({
    required this.type,
    required this.deviceCount,
    required this.sessions,
    required this.onHours,
    required this.averageHoursPerDevice,
    required this.leftOnSessions,
    required this.daily,
    required this.weekly,
  });

  final String type;
  final int deviceCount;
  final int sessions;
  final double onHours;
  final double averageHoursPerDevice;
  final int leftOnSessions;
  final List<SeriesPoint> daily;
  final List<SeriesPoint> weekly;
}

/// Device on-hours, per device and per type.
class DeviceUsage {
  const DeviceUsage({
    required this.devices,
    required this.types,
    required this.hoursByRoom,
    required this.totalOnHours,
    required this.leftOnSessions,
  });

  /// Sorted by room, then device id.
  final List<DeviceStat> devices;

  /// Sorted by on-hours, highest first.
  final List<DeviceTypeStat> types;

  /// Room -> total device on-hours.
  final Map<String, double> hoursByRoom;

  final double totalOnHours;
  final int leftOnSessions;
}

// ---------------------------------------------------------------- System

/// Utilization of one room.
class RoomUtilization {
  const RoomUtilization({
    required this.room,
    required this.building,
    required this.sessions,
    required this.hours,
    required this.averageSessionHours,
    required this.businessHoursInUse,
    required this.businessHoursAvailable,
    required this.afterHoursHours,
    required this.occupancy,
  });

  final String room;
  final String building;
  final int sessions;

  /// Total system-on hours.
  final double hours;
  final double averageSessionHours;

  /// System-on hours inside [AnalysisConfig.businessHours].
  final double businessHoursInUse;

  /// Business-window hours in the dataset range.
  final double businessHoursAvailable;

  /// System-on hours outside the business window (energy insight).
  final double afterHoursHours;

  /// Fraction of each weekday/hour slot this room was on (0-1).
  final HourWeekdayHeatmap occupancy;

  /// [businessHoursInUse] / [businessHoursAvailable] (0-1), or 0 when there
  /// is no business time in range.
  double get utilization => businessHoursAvailable <= 0
      ? 0
      : (businessHoursInUse / businessHoursAvailable).clamp(0.0, 1.0);
}

/// System power-session statistics.
class SystemUsage {
  const SystemUsage({
    required this.sessionCount,
    required this.totalHours,
    required this.averageSessionHours,
    required this.medianSessionHours,
    required this.powerOnByHour,
    required this.powerOffByHour,
    required this.powerOnByWeekday,
    required this.occupancy,
    required this.sessionLengths,
    required this.offReasons,
    this.otherOffReasons = const {},
    required this.rooms,
    required this.daily,
    required this.weekly,
    required this.businessHours,
    required this.roomCount,
  });

  final int sessionCount;
  final double totalHours;
  final double averageSessionHours;
  final double medianSessionHours;

  /// 24 counts of power-on time (sessions that began before the range are
  /// excluded).
  final List<int> powerOnByHour;

  /// 24 counts of power-off time (sessions still on at the end or closed by
  /// the cap are excluded).
  final List<int> powerOffByHour;

  /// 7 counts of power-ons per weekday, index 0 = Monday.
  final List<int> powerOnByWeekday;

  /// Average fraction of rooms with the system on, per weekday/hour slot.
  final HourWeekdayHeatmap occupancy;

  /// Session length histogram.
  final List<DurationBucket> sessionLengths;

  /// Count of sessions per off reason (every reason present, zero if none).
  final Map<OffReason, int> offReasons;

  /// Sessions closed with [OffReason.other], by the reason text exactly as
  /// logged (such as `User Reset`).
  final Map<String, int> otherOffReasons;

  /// Per room, sorted by room name.
  final List<RoomUtilization> rooms;

  /// Campus system-on hours per day.
  final List<SeriesPoint> daily;

  /// Campus system-on hours per week.
  final List<SeriesPoint> weekly;

  /// Window used for [RoomUtilization.utilization].
  final BusinessHours businessHours;

  /// Number of rooms used as the occupancy denominator.
  final int roomCount;
}

// ---------------------------------------------------------------- UI

/// Usage of one touch-panel control.
class ButtonStat {
  const ButtonStat({
    required this.control,
    required this.presses,
    required this.taps,
    required this.holds,
    required this.repeats,
    required this.isNavigation,
    required this.isSlider,
    required this.roomCount,
  });

  /// Control name as logged, such as `Volume Up`.
  final String control;

  /// `Pressed` events: the count to show as "presses".
  final int presses;
  final int taps;
  final int holds;
  final int repeats;
  final bool isNavigation;
  final bool isSlider;
  final int roomCount;
}

/// Touch-panel usage for one room.
class RoomUiStat {
  const RoomUiStat({
    required this.room,
    required this.presses,
    required this.navigationPresses,
    required this.topButtons,
  });

  final String room;
  final int presses;
  final int navigationPresses;

  /// Up to 10 most-pressed controls in this room (room-only counts).
  final List<ButtonStat> topButtons;

  double get navigationShare => presses == 0 ? 0 : navigationPresses / presses;
}

/// Wireless presentation shares (action `Share`) per metric.
class ShareStat {
  const ShareStat({
    required this.station,
    required this.count,
    required this.roomCount,
  });

  /// The share event's metric exactly as logged.
  final String station;
  final int count;
  final int roomCount;
}

/// Touch-panel and sharing usage.
class UiUsage {
  const UiUsage({
    required this.totalPresses,
    required this.navigationPresses,
    required this.buttons,
    required this.rooms,
    required this.shares,
  });

  /// `Pressed` events across all controls.
  final int totalPresses;
  final int navigationPresses;

  /// All controls, most pressed first.
  final List<ButtonStat> buttons;

  /// Rooms with at least one UI event, sorted by room.
  final List<RoomUiStat> rooms;

  /// Shares by metric, most used first.
  final List<ShareStat> shares;

  double get navigationShare =>
      totalPresses == 0 ? 0 : navigationPresses / totalPresses;
}

// ---------------------------------------------------------------- Audio

/// One mute channel (such as `Program Audio`) across the campus.
class MuteStat {
  const MuteStat({
    required this.name,
    required this.muteCount,
    required this.mutedHours,
    required this.roomCount,
  });
  final String name;

  /// Times the mute was switched on.
  final int muteCount;

  /// Hours muted while the system was on.
  final double mutedHours;
  final int roomCount;
}

/// One volume control (such as `Program Audio Volume`).
class VolumeStat {
  const VolumeStat({
    required this.name,
    required this.changes,
    required this.averageLevel,
    required this.minLevel,
    required this.maxLevel,
    required this.levelHistogram,
  });
  final String name;

  /// Logged level changes.
  final int changes;
  final double averageLevel;
  final int minLevel;
  final int maxLevel;

  /// 10 counts: levels 0-9, 10-19, ..., 90-100.
  final List<int> levelHistogram;
}

/// Mute and volume behaviour.
class AudioUsage {
  const AudioUsage({required this.mutes, required this.volumes});
  final List<MuteStat> mutes;
  final List<VolumeStat> volumes;
}
