// Headline numbers, per-room summaries and data-quality notes. Pure Dart.

import 'issues.dart';
import 'series.dart';
import 'usage.dart';

/// Campus-wide headline numbers for the overview dashboard.
class OverviewStats {
  const OverviewStats({
    required this.roomCount,
    required this.buildingCount,
    required this.deviceCount,
    required this.eventCount,
    required this.heartbeatCount,
    required this.rangeStart,
    required this.rangeEnd,
    required this.systemSessionCount,
    required this.totalSystemHours,
    required this.averageDailyHoursPerRoom,
    required this.totalDeviceHours,
    required this.mostUsedInputByTime,
    required this.mostUsedInputBySelections,
    required this.issueCounts,
    required this.busiestWeekday,
    required this.busiestHour,
    required this.busiestOccupancy,
    required this.busiestDayOfWeek,
  });

  final int roomCount;
  final int buildingCount;
  final int deviceCount;

  /// Non-heartbeat events analysed (excluded clients not counted).
  final int eventCount;

  /// Heartbeats represented by the heartbeat buckets.
  final int heartbeatCount;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final int systemSessionCount;
  final double totalSystemHours;

  /// totalSystemHours / rooms / days in range.
  final double averageDailyHoursPerRoom;
  final double totalDeviceHours;
  final InputShare? mostUsedInputByTime;
  final InputShare? mostUsedInputBySelections;

  /// Count of issues per severity (every severity present).
  final Map<IssueSeverity, int> issueCounts;

  /// Weekday (1-7) and hour (0-23) of the busiest occupancy slot, or `null`
  /// when no room was ever on.
  final int? busiestWeekday;
  final int? busiestHour;

  /// Occupancy of that slot (fraction of rooms on, 0-1).
  final double busiestOccupancy;

  /// Weekday (1-7) with the highest average occupancy, or `null`.
  final int? busiestDayOfWeek;

  /// Length of the analysed range in days (fractional).
  double get days => rangeEnd.difference(rangeStart).inMicroseconds / 8.64e10;

  int get issueTotal => issueCounts.values.fold(0, (a, b) => a + b);
}

/// Everything about one room in one object, for the room list and the
/// first panel of the room drill-down.
class RoomSummary {
  const RoomSummary({
    required this.room,
    required this.building,
    required this.eventCount,
    required this.firstEvent,
    required this.lastEvent,
    required this.systemSessions,
    required this.systemHours,
    required this.utilization,
    required this.afterHoursHours,
    required this.averageSessionHours,
    required this.reboots,
    required this.deviceHours,
    required this.deviceIds,
    required this.topInput,
    required this.issueCounts,
    required this.onlineFraction,
    required this.helpEvents,
    required this.buttonPresses,
  });

  final String room;
  final String building;
  final int eventCount;
  final DateTime? firstEvent;
  final DateTime? lastEvent;
  final int systemSessions;
  final double systemHours;

  /// Business-hours utilization (0-1).
  final double utilization;
  final double afterHoursHours;
  final double averageSessionHours;

  /// Program start events (processor boots or program loads, such as
  /// `Program Start` or `Initialize`).
  final int reboots;
  final double deviceHours;

  /// Device ids seen in this room, sorted.
  final List<String> deviceIds;

  /// Input with the most time on screen here.
  final InputShare? topInput;

  /// Issues per severity (every severity present).
  final Map<IssueSeverity, int> issueCounts;

  /// Heartbeat online fraction (0-1), or `null` without coverage.
  final double? onlineFraction;
  /// Help-labelled events (metric contains the word `help`, any action).
  final int helpEvents;
  final int buttonPresses;

  int get issueTotal => issueCounts.values.fold(0, (a, b) => a + b);
}

/// Notes about the data itself, for transparency.
class DataQuality {
  const DataQuality({
    required this.skippedRows,
    required this.excludedEvents,
    required this.adminEvents,
    required this.unclassified,
    required this.unclassifiedTotal,
    required this.orphanStops,
    required this.duplicateStarts,
    required this.unterminatedSessions,
    required this.warnings,
  });

  /// Rows the importer could not parse.
  final int skippedRows;

  /// Events from excluded clients (such as `AVSM-System`).
  final int excludedEvents;

  /// `AVSM-System` events when that client is not excluded.
  final int adminEvents;

  /// Most frequent unrecognised (metric, action) pairs, up to 50.
  final List<MetricCount> unclassified;
  final int unclassifiedTotal;

  /// `Stopped` events with nothing to stop.
  final int orphanStops;

  /// Repeated `Started` events that were ignored.
  final int duplicateStarts;

  /// Sessions closed by [AnalysisConfig.maxSessionLength].
  final int unterminatedSessions;

  /// Configuration problems and other notes, for display.
  final List<String> warnings;
}
