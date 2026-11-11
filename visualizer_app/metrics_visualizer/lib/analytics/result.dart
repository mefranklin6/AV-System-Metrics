// The complete output of `analyze()`. Pure Dart, isolate-sendable (no
// closures, regular expressions or other unsendable objects inside).

import 'connectivity.dart';
import 'forecast.dart';
import 'issues.dart';
import 'overview.dart';
import 'sessions.dart';
import 'usage.dart';

/// Everything the dashboards show, computed once per dataset/filter/config.
class AnalysisResult {
  const AnalysisResult({
    required this.rangeStart,
    required this.rangeEnd,
    required this.useLocalTime,
    required this.timeZoneLabel,
    required this.rooms,
    required this.buildings,
    required this.roomBuildings,
    required this.overview,
    required this.inputs,
    required this.devices,
    required this.system,
    required this.connectivity,
    required this.ui,
    required this.audio,
    required this.issues,
    required this.forecast,
    required this.roomSummaries,
    required this.sessions,
    required this.dataQuality,
  });

  /// Effective analysed range (UTC, end exclusive). Widened to include every
  /// event if the dataset's declared range was narrower.
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Whether hour/weekday/day buckets use local time (else UTC).
  final bool useLocalTime;

  /// Display label for the bucketing zone, such as `UTC`.
  final String timeZoneLabel;

  /// Room (client) names, sorted.
  final List<String> rooms;

  /// Building codes, sorted.
  final List<String> buildings;

  /// Room -> building code.
  final Map<String, String> roomBuildings;

  final OverviewStats overview;
  final InputUsage inputs;
  final DeviceUsage devices;
  final SystemUsage system;
  final ConnectivityReport connectivity;
  final UiUsage ui;
  final AudioUsage audio;

  /// All detected issues, ordered by start time (newest last), then
  /// severity (most severe first).
  final List<Issue> issues;
  final ForecastReport forecast;

  /// One summary per room, sorted by room.
  final List<RoomSummary> roomSummaries;

  /// Reconstructed sessions per room.
  final Map<String, RoomSessions> sessions;
  final DataQuality dataQuality;

  /// Whether there is nothing to show.
  bool get isEmpty => rooms.isEmpty;

  /// Summary for [room], or `null`.
  RoomSummary? roomSummary(String room) {
    for (final r in roomSummaries) {
      if (r.room == room) return r;
    }
    return null;
  }

  /// Issues for [room].
  List<Issue> issuesForRoom(String room) => [
    for (final i in issues)
      if (i.room == room) i,
  ];

  /// Device stats for [room].
  List<DeviceStat> devicesForRoom(String room) => [
    for (final d in devices.devices)
      if (d.room == room) d,
  ];

  /// Rooms in [building], sorted.
  List<String> roomsInBuilding(String building) => [
    for (final r in rooms)
      if (roomBuildings[r] == building) r,
  ];
}
