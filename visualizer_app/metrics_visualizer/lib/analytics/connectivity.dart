// Result types for device connectivity and processor heartbeats. Pure Dart.

import 'series.dart';

/// One `Connected` / `Disconnected` event.
class ConnectionEventRecord {
  const ConnectionEventRecord({
    required this.room,
    required this.target,
    required this.time,
    required this.connected,
  });

  final String room;

  /// What (dis)connected: the event's metric, such as `Projector 1`.
  final String target;
  final DateTime time;

  /// `true` = Connected, `false` = Disconnected.
  final bool connected;
}

/// Connect/disconnect counts for one calendar day.
class ConnectionDay {
  const ConnectionDay(this.date, this.connects, this.disconnects);

  /// Calendar date in the analysis zone (UTC midnight encoding).
  final DateTime date;
  final int connects;
  final int disconnects;
}

/// Connect/disconnect counts for one target (device) in one room.
class TargetConnectivity {
  const TargetConnectivity({
    required this.target,
    required this.connects,
    required this.disconnects,
    required this.lastState,
    required this.lastChange,
    required this.flapBursts,
  });

  final String target;

  /// State changes to Connected / Disconnected. A repeated report of the
  /// same state (such as "Connected" twice in a row) is not counted; the
  /// first event for a target is.
  final int connects;
  final int disconnects;

  /// Bursts of at least [IssueThresholds.connectionFlapCount] changes within
  /// [IssueThresholds.connectionFlapWindow] (each is also an issue).
  final int flapBursts;

  /// `true` if the last event was Connected.
  final bool lastState;

  /// When the target last changed state.
  final DateTime lastChange;
}

/// A stretch of time inside heartbeat coverage with no sign of life from a
/// room's processor (no heartbeats and no events).
class OfflinePeriod {
  const OfflinePeriod({
    required this.room,
    required this.start,
    required this.end,
    required this.ongoing,
  });

  final String room;

  /// Start of the first silent hour (UTC).
  final DateTime start;

  /// End of the last silent hour (UTC, exclusive).
  final DateTime end;

  /// The silence lasts until the end of heartbeat coverage.
  final bool ongoing;

  /// Length. Heartbeats are counted per hour, so the true outage can be up
  /// to two hours longer than this.
  Duration get duration => end.difference(start);
  double get hours => duration.inMicroseconds / 3.6e9;
}

/// Connectivity and uptime of one room.
class RoomConnectivity {
  const RoomConnectivity({
    required this.room,
    required this.building,
    required this.connects,
    required this.disconnects,
    required this.targets,
    required this.daily,
    required this.onlineFraction,
    required this.onlineHours,
    required this.coveredHours,
    required this.dailyOnline,
    required this.offlinePeriods,
    required this.lastSeen,
    this.lastEvent,
    this.lastHeartbeatHour,
  });

  final String room;
  final String building;
  final int connects;
  final int disconnects;

  /// Sum of [TargetConnectivity.flapBursts] over [targets].
  int get flapBursts => targets.fold(0, (a, t) => a + t.flapBursts);

  /// Per target, sorted by name.
  final List<TargetConnectivity> targets;

  /// Days with at least one connection event, ascending.
  final List<ConnectionDay> daily;

  /// Online hours / covered hours (0-1); `null` without heartbeat coverage
  /// or when this room sent no heartbeats at all.
  final double? onlineFraction;
  final int onlineHours;

  /// Hours of heartbeat coverage this room is judged over: from its first
  /// heartbeat or event (or the coverage start, if later) to the coverage
  /// end. 0 when the room sent no heartbeats.
  final int coveredHours;

  /// Online fraction per day within coverage; [SeriesPoint.coverage] is the
  /// fraction of the day covered by heartbeat data.
  final List<SeriesPoint> dailyOnline;

  /// Silent periods longer than [IssueThresholds.offlineGap].
  final List<OfflinePeriod> offlinePeriods;

  /// Last sign of life: the exact time of the last event, or the start of
  /// the last hour with a heartbeat when that is later (heartbeats are only
  /// counted per hour). `null` when the room was never heard from.
  final DateTime? lastSeen;

  /// Exact time of the room's last (non-heartbeat) event, if any.
  final DateTime? lastEvent;

  /// Start of the last UTC hour in which the room sent a heartbeat, if any.
  final DateTime? lastHeartbeatHour;
}

/// Connectivity across the campus.
class ConnectivityReport {
  const ConnectivityReport({
    required this.events,
    required this.daily,
    required this.rooms,
    required this.coverageStart,
    required this.coverageEnd,
    required this.retentionDays,
    required this.coverageNote,
  });

  /// Every connection event, time-ordered.
  final List<ConnectionEventRecord> events;

  /// Campus connect/disconnect counts for every day of the range.
  final List<ConnectionDay> daily;

  /// One entry per room, sorted by room.
  final List<RoomConnectivity> rooms;

  /// Start of heartbeat coverage (UTC hour), or `null` without heartbeats.
  final DateTime? coverageStart;

  /// End of heartbeat coverage (UTC hour, exclusive).
  final DateTime? coverageEnd;

  /// Server heartbeat retention, when known.
  final int? retentionDays;

  /// Plain-language explanation of what the online figures cover.
  final String coverageNote;

  bool get hasHeartbeatCoverage => coverageStart != null;
}
