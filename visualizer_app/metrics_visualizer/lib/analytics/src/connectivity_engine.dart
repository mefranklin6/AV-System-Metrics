// Internal: connection events and heartbeat uptime. Not exported.

import 'dart:typed_data';

import '../classifier.dart';
import '../connectivity.dart';
import '../series.dart';
import '../time_bucketing.dart';
import 'context.dart';
import 'window.dart';

DateTime _hourInstant(int hour) =>
    DateTime.fromMicrosecondsSinceEpoch(hour * usPerHour, isUtc: true);

/// The exact time of the last event, or the start of the last heartbeat
/// hour when that is later (heartbeats are only known per hour).
DateTime? _lastSeen(DateTime? lastEvent, int? lastHeartbeatHour) {
  final hb = lastHeartbeatHour == null ? null : _hourInstant(lastHeartbeatHour);
  if (lastEvent == null) return hb;
  if (hb == null) return lastEvent;
  return hb.isAfter(lastEvent) ? hb : lastEvent;
}

/// Connectivity report: connection timeline, flapping inputs, heartbeat
/// online percentage and offline periods.
ConnectivityReport computeConnectivity(AnalysisContext ctx) {
  final b = ctx.bucketer;
  final events = <ConnectionEventRecord>[];
  final campusConnects = List.filled(ctx.dayCount, 0);
  final campusDisconnects = List.filled(ctx.dayCount, 0);

  // ---- heartbeat coverage (global, in UTC hours)
  int? minHb, maxHb;
  for (final room in ctx.rooms) {
    for (final h in ctx.heartbeatsByRoom[room] ?? const []) {
      if (h.count <= 0) continue;
      final hour = floorDiv(h.hourStart.microsecondsSinceEpoch, usPerHour);
      if (minHb == null || hour < minHb) minHb = hour;
      if (maxHb == null || hour > maxHb) maxHb = hour;
    }
  }
  int? covStart, covEnd;
  if (minHb != null && maxHb != null) {
    final rangeStartHour = floorDiv(
      ctx.rangeStart.microsecondsSinceEpoch,
      usPerHour,
    );
    final rangeEndHour = -floorDiv(
      -ctx.rangeEnd.microsecondsSinceEpoch,
      usPerHour,
    );
    var s = minHb > rangeStartHour ? minHb : rangeStartHour;
    final retention = ctx.heartbeatRetentionDays;
    if (retention != null && retention > 0) {
      final cutoff = -floorDiv(
        -(ctx.rangeEnd.microsecondsSinceEpoch - retention * usPerDay),
        usPerHour,
      );
      if (cutoff > s) s = cutoff;
    }
    var e = maxHb + 1;
    if (e > rangeEndHour) e = rangeEndHour;
    if (e > s) {
      covStart = s;
      covEnd = e;
    }
  }
  final covHours = covStart == null ? 0 : covEnd! - covStart;
  final offlineGapUs = ctx.config.thresholds.offlineGap.inMicroseconds;

  // Day index per coverage hour (analysis zone).
  final hourDay = covStart == null
      ? Int32List(0)
      : Int32List.fromList([
          for (var i = 0; i < covHours; i++)
            b.dayOf(_hourInstant(covStart + i)) - ctx.firstDay,
        ]);
  final rooms = <RoomConnectivity>[];
  var roomsWithoutHeartbeats = 0;
  for (final room in ctx.rooms) {
    final targetConnects = <String, int>{};
    final targetDisconnects = <String, int>{};
    final targetLast = <String, ConnectionEventRecord>{};
    final targetTimes = <String, List<int>>{};
    final dailyC = <int, int>{};
    final dailyD = <int, int>{};
    final online = Uint8List(covHours);
    int? firstEventHour;
    DateTime? lastEventTime;
    for (final ce in ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[]) {
      final hour = floorDiv(ce.time.microsecondsSinceEpoch, usPerHour);
      firstEventHour ??= hour;
      if (lastEventTime == null || ce.time.isAfter(lastEventTime)) {
        lastEventTime = ce.time;
      }
      if (covStart != null && hour >= covStart && hour < covEnd!) {
        online[hour - covStart] = 1;
      }
      final m = ce.meaning;
      if (m.category != EventCategory.connection) continue;
      final rec = ConnectionEventRecord(
        room: room,
        target: m.connectionTarget!,
        time: ce.time,
        connected: m.connected!,
      );
      // The timeline keeps every event; counts and flapping use only state
      // changes, because programs often repeat the same state (a touch
      // panel reports "Online" at once and again 10 seconds later).
      events.add(rec);
      final previous = targetLast[rec.target];
      if (previous != null && previous.connected == rec.connected) continue;
      targetLast[rec.target] = rec;
      targetTimes
          .putIfAbsent(rec.target, () => [])
          .add(ce.time.microsecondsSinceEpoch);
      final day = ctx.bucketer.dayOf(ce.time) - ctx.firstDay;
      if (rec.connected) {
        targetConnects[rec.target] = (targetConnects[rec.target] ?? 0) + 1;
        dailyC[day] = (dailyC[day] ?? 0) + 1;
        if (day >= 0 && day < ctx.dayCount) campusConnects[day]++;
      } else {
        targetDisconnects[rec.target] =
            (targetDisconnects[rec.target] ?? 0) + 1;
        dailyD[day] = (dailyD[day] ?? 0) + 1;
        if (day >= 0 && day < ctx.dayCount) campusDisconnects[day]++;
      }
    }
    int? firstHbHour, lastHbHour;
    for (final h in ctx.heartbeatsByRoom[room] ?? const []) {
      if (h.count <= 0) continue;
      final hour = floorDiv(h.hourStart.microsecondsSinceEpoch, usPerHour);
      if (firstHbHour == null || hour < firstHbHour) firstHbHour = hour;
      if (lastHbHour == null || hour > lastHbHour) lastHbHour = hour;
      if (covStart != null && hour >= covStart && hour < covEnd!) {
        online[hour - covStart] = 1;
      }
    }

    // This room's own coverage: a room that never sent a heartbeat (its
    // program has heartbeats turned off) is not judged at all, and a room
    // is judged only from its first sign of life (heartbeat or event), so a
    // room commissioned or renamed mid-range has no leading "offline" time.
    // Coverage still runs to the global end, so a room that stopped
    // reporting is flagged as offline.
    var roomStart = covHours; // index into the global coverage hours
    if (covStart != null && firstHbHour != null) {
      var first = firstHbHour;
      if (firstEventHour != null && firstEventHour < first) {
        first = firstEventHour;
      }
      roomStart = (first - covStart).clamp(0, covHours);
    } else if (covStart != null) {
      roomsWithoutHeartbeats++;
    }
    final roomCovered = covHours - roomStart;
    final dayCoveredHours = List.filled(ctx.dayCount, 0);
    for (var i = roomStart; i < covHours; i++) {
      final d = hourDay[i];
      if (d >= 0 && d < ctx.dayCount) dayCoveredHours[d]++;
    }

    // Online fraction, daily online, offline periods.
    var onlineHours = 0;
    final dayOnline = List.filled(ctx.dayCount, 0);
    final offline = <OfflinePeriod>[];
    int? runStart;
    void closeRun(int endIdx) {
      final s = runStart!;
      if ((endIdx - s) * usPerHour > offlineGapUs) {
        offline.add(
          OfflinePeriod(
            room: room,
            start: _hourInstant(covStart! + s),
            end: _hourInstant(covStart + endIdx),
            ongoing: endIdx == covHours,
          ),
        );
      }
      runStart = null;
    }

    for (var i = roomStart; i < covHours; i++) {
      if (online[i] == 1) {
        onlineHours++;
        final d = hourDay[i];
        if (d >= 0 && d < ctx.dayCount) dayOnline[d]++;
        if (runStart != null) closeRun(i);
      } else {
        runStart ??= i;
      }
    }
    if (runStart != null) closeRun(covHours);

    final dailyOnline = <SeriesPoint>[
      if (roomCovered > 0)
        for (var d = 0; d < ctx.dayCount; d++)
          if (dayCoveredHours[d] > 0)
            SeriesPoint(
              TimeBucketer.dateOfDay(ctx.firstDay + d),
              dayOnline[d] / dayCoveredHours[d],
              coverage: (dayCoveredHours[d] / (ctx.dayLengthUs[d] / usPerHour))
                  .clamp(0.0, 1.0),
            ),
    ];
    final days = {...dailyC.keys, ...dailyD.keys}.toList()..sort();
    final targets = (targetLast.keys.toList()..sort())
        .map(
          (t) => TargetConnectivity(
            target: t,
            connects: targetConnects[t] ?? 0,
            disconnects: targetDisconnects[t] ?? 0,
            lastState: targetLast[t]!.connected,
            lastChange: targetLast[t]!.time,
            flapBursts: findBursts(
              targetTimes[t]!,
              ctx.config.thresholds.connectionFlapWindow.inMicroseconds,
              ctx.config.thresholds.connectionFlapCount,
            ).length,
          ),
        )
        .toList(growable: false);
    rooms.add(
      RoomConnectivity(
        room: room,
        building: ctx.buildingOf(room),
        connects: targetConnects.values.fold(0, (a, b) => a + b),
        disconnects: targetDisconnects.values.fold(0, (a, b) => a + b),
        targets: List.unmodifiable(targets),
        daily: List.unmodifiable([
          for (final d in days)
            ConnectionDay(
              TimeBucketer.dateOfDay(ctx.firstDay + d),
              dailyC[d] ?? 0,
              dailyD[d] ?? 0,
            ),
        ]),
        onlineFraction: roomCovered == 0 ? null : onlineHours / roomCovered,
        onlineHours: onlineHours,
        coveredHours: roomCovered,
        dailyOnline: List.unmodifiable(dailyOnline),
        offlinePeriods: List.unmodifiable(offline),
        lastSeen: _lastSeen(lastEventTime, lastHbHour),
        lastEvent: lastEventTime,
        lastHeartbeatHour: lastHbHour == null ? null : _hourInstant(lastHbHour),
      ),
    );
  }
  events.sort((a, b) {
    final c = a.time.compareTo(b.time);
    if (c != 0) return c;
    final r = a.room.compareTo(b.room);
    return r != 0 ? r : a.target.compareTo(b.target);
  });

  final retention = ctx.heartbeatRetentionDays;
  final String note;
  if (covStart == null) {
    note =
        'No heartbeat data is available for this period, so online '
        'percentages and offline periods cannot be calculated.';
  } else {
    note =
        'Online figures use hourly heartbeat counts from '
        '${_hourInstant(covStart).toIso8601String()} to '
        '${_hourInstant(covEnd!).toIso8601String()} (UTC). An hour counts as '
        'online when the room sent at least one heartbeat or event. Each '
        'room is measured from its first heartbeat or event in that period. '
        '${retention != null ? 'The server keeps heartbeats for $retention '
                  'days, so older periods are not covered. ' : 'The server deletes '
                  'old heartbeats (30 days by default), so older periods may not be '
                  'covered. '}'
        '${roomsWithoutHeartbeats == 0 ? '' : '$roomsWithoutHeartbeats '
                  '${roomsWithoutHeartbeats == 1 ? 'room sent' : 'rooms sent'} no '
                  'heartbeats at all (heartbeats may be turned off in its '
                  'program), so no online figure is shown for '
                  '${roomsWithoutHeartbeats == 1 ? 'it' : 'them'}. '}'
        'Offline periods are measured in whole hours; the real outage can be '
        'up to two hours longer.';
  }

  return ConnectivityReport(
    events: List.unmodifiable(events),
    daily: List.unmodifiable([
      for (var d = 0; d < ctx.dayCount; d++)
        ConnectionDay(
          TimeBucketer.dateOfDay(ctx.firstDay + d),
          campusConnects[d],
          campusDisconnects[d],
        ),
    ]),
    rooms: List.unmodifiable(rooms),
    coverageStart: covStart == null ? null : _hourInstant(covStart),
    coverageEnd: covEnd == null ? null : _hourInstant(covEnd),
    retentionDays: retention,
    coverageNote: note,
  );
}
