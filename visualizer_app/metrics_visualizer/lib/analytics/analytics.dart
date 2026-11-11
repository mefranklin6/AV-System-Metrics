/// Pure-Dart analytics engine for AV System Metrics.
///
/// Import this one file. It exports every public analytics type and the
/// [analyze] entry point. Nothing here imports Flutter, so it runs inside
/// `Isolate.run` / `compute` and in plain Dart tests.
///
/// See `lib/analytics/README.md` for the API guide and the methodology.
library;

import '../data/models.dart';
import 'classifier.dart';
import 'config.dart';
import 'issues.dart';
import 'overview.dart';
import 'result.dart';
import 'series.dart';
import 'sessions.dart';
import 'src/connectivity_engine.dart';
import 'src/context.dart';
import 'src/forecast_engine.dart';
import 'src/issue_engine.dart';
import 'src/usage_engine.dart';
import 'time_bucketing.dart';

export '../data/models.dart';
export 'classifier.dart';
export 'config.dart';
export 'connectivity.dart';
export 'forecast.dart';
export 'issues.dart';
export 'labels.dart';
export 'overview.dart';
export 'result.dart';
export 'series.dart';
export 'sessions.dart';
export 'time_bucketing.dart';
export 'usage.dart';

/// Analyses [dataset] with [config] and returns every dashboard figure.
///
/// * Clients in [excludeClients] (compared case-insensitively) are ignored
///   entirely; by default the synthetic `AVSM-System` server client.
///   Clients that are server pseudo-clients but not excluded are counted in
///   [DataQuality.adminEvents] and never treated as rooms.
/// * Deterministic: the same inputs always produce the same result.
/// * Runs in O(n log n) time for n events. Safe to call in an isolate.
/// * Never throws for well-formed datasets, including empty ones.
AnalysisResult analyze(
  Dataset dataset,
  AnalysisConfig config, {
  Set<String> excludeClients = const {'AVSM-System'},
}) {
  final excluded = {for (final c in excludeClients) c.toLowerCase()};
  final classifier = MetricClassifier(config.classifier);
  final bucketer = TimeBucketer(useLocalTime: config.useLocalTime);

  // ---- effective range: the declared range widened to include all data.
  var startUs = dataset.rangeStart.toUtc().microsecondsSinceEpoch;
  var endUs = dataset.rangeEnd.toUtc().microsecondsSinceEpoch;
  if (dataset.events.isNotEmpty) {
    final first = dataset.events.first.timestamp.microsecondsSinceEpoch;
    final last = dataset.events.last.timestamp.microsecondsSinceEpoch + 1;
    if (first < startUs) startUs = first;
    if (last > endUs) endUs = last;
  }
  if (endUs <= startUs) endUs = startUs + 1;
  final rangeStart = DateTime.fromMicrosecondsSinceEpoch(startUs, isUtc: true);
  final rangeEnd = DateTime.fromMicrosecondsSinceEpoch(endUs, isUtc: true);

  // ---- classify and group by room (single pass).
  final eventsByRoom = <String, List<ClassifiedEvent>>{};
  final unclassified = <String, Map<String, int>>{};
  var excludedEvents = 0, adminEvents = 0, unclassifiedTotal = 0;
  var eventCount = 0;
  String? lastClient;
  var lastExcluded = false, lastAdmin = false;
  List<ClassifiedEvent>? lastList;
  for (final e in dataset.events) {
    if (e.clientName != lastClient) {
      lastClient = e.clientName;
      lastExcluded = excluded.contains(e.clientName.toLowerCase());
      lastAdmin = MetricClassifier.isAdminClient(e.clientName);
      lastList = (lastExcluded || lastAdmin)
          ? null
          : eventsByRoom.putIfAbsent(e.clientName, () => []);
    }
    if (lastExcluded) {
      excludedEvents++;
      continue;
    }
    if (lastAdmin) {
      adminEvents++;
      continue;
    }
    final m = classifier.classify(e.metric, e.action);
    if (m.category == EventCategory.heartbeat) continue;
    eventCount++;
    if (m.category == EventCategory.other) {
      unclassifiedTotal++;
      final byAction = unclassified.putIfAbsent(e.metric, () => {});
      byAction[e.action] = (byAction[e.action] ?? 0) + 1;
    }
    lastList!.add(ClassifiedEvent(e, m));
  }

  final heartbeatsByRoom = <String, List<HeartbeatBucket>>{};
  var heartbeatCount = 0;
  for (final h in dataset.heartbeats) {
    final lower = h.clientName.toLowerCase();
    if (excluded.contains(lower) || MetricClassifier.isAdminClient(lower)) {
      continue;
    }
    heartbeatsByRoom.putIfAbsent(h.clientName, () => []).add(h);
    heartbeatCount += h.count;
  }

  final rooms = {...eventsByRoom.keys, ...heartbeatsByRoom.keys}.toList()
    ..sort();
  final roomBuildings = {for (final r in rooms) r: classifier.buildingOf(r)};

  final ctx = AnalysisContext(
    config: config,
    classifier: classifier,
    bucketer: bucketer,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    rooms: rooms,
    roomBuildings: roomBuildings,
    eventsByRoom: eventsByRoom,
    heartbeatsByRoom: heartbeatsByRoom,
    heartbeatRetentionDays: dataset.heartbeatRetentionDays,
  );

  // ---- sessions
  for (final room in rooms) {
    ctx.sessions[room] = SessionBuilder.build(
      room: room,
      events: eventsByRoom[room] ?? const [],
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      maxSessionLength: config.maxSessionLength,
    );
  }

  // ---- aggregates
  final inputs = computeInputUsage(ctx);
  final devices = computeDeviceUsage(ctx);
  final system = computeSystemUsage(ctx);
  final ui = computeUiUsage(ctx);
  final audio = computeAudioUsage(ctx);
  final connectivity = computeConnectivity(ctx);
  final issues = detectIssues(ctx, connectivity.rooms);
  final forecast = computeForecast(ctx, devices, inputs);

  // ---- overview
  Map<IssueSeverity, int> countBySeverity(Iterable<Issue> list) {
    final m = {for (final s in IssueSeverity.values) s: 0};
    for (final i in list) {
      m[i.severity] = m[i.severity]! + 1;
    }
    return Map.unmodifiable(m);
  }

  int? busyWeekday, busyHour;
  var busyValue = 0.0;
  for (var d = 1; d <= 7; d++) {
    for (var h = 0; h < 24; h++) {
      final v = system.occupancy.valueAt(d, h);
      if (v > busyValue) {
        busyValue = v;
        busyWeekday = d;
        busyHour = h;
      }
    }
  }
  int? busyDay;
  var busyDayValue = 0.0;
  for (var d = 1; d <= 7; d++) {
    final v = system.occupancy.weekdayMean(d);
    if (v > busyDayValue) {
      busyDayValue = v;
      busyDay = d;
    }
  }
  final days = (endUs - startUs) / usPerDay;
  final overview = OverviewStats(
    roomCount: rooms.length,
    buildingCount: roomBuildings.values.toSet().length,
    deviceCount: devices.devices.length,
    eventCount: eventCount,
    heartbeatCount: heartbeatCount,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    systemSessionCount: system.sessionCount,
    totalSystemHours: system.totalHours,
    averageDailyHoursPerRoom: rooms.isEmpty || days <= 0
        ? 0
        : system.totalHours / rooms.length / days,
    totalDeviceHours: devices.totalOnHours,
    mostUsedInputByTime: inputs.mostUsedByTime,
    mostUsedInputBySelections: inputs.mostUsedBySelections,
    issueCounts: countBySeverity(issues),
    busiestWeekday: busyWeekday,
    busiestHour: busyHour,
    busiestOccupancy: busyValue,
    busiestDayOfWeek: busyDay,
  );

  // ---- room summaries
  final utilByRoom = {for (final u in system.rooms) u.room: u};
  final connByRoom = {for (final c in connectivity.rooms) c.room: c};
  final issuesByRoom = <String, List<Issue>>{};
  for (final i in issues) {
    issuesByRoom.putIfAbsent(i.room, () => []).add(i);
  }
  final uiByRoom = {for (final u in ui.rooms) u.room: u};
  final summaries = <RoomSummary>[];
  var orphanStops = 0, duplicateStarts = 0, unterminated = 0;
  for (final room in rooms) {
    final ev = eventsByRoom[room] ?? const <ClassifiedEvent>[];
    final s = ctx.sessions[room]!;
    orphanStops += s.orphanStops;
    duplicateStarts += s.duplicateStarts;
    for (final list in <List<Session>>[
      s.system,
      s.devices,
      s.inputs,
      s.mutes,
    ]) {
      for (final x in list) {
        if (x.unterminated) unterminated++;
      }
    }
    final u = utilByRoom[room]!;
    final roomInputs = inputs.byRoom[room];
    var help = 0;
    for (final ce in ev) {
      if (ce.meaning.category == EventCategory.help) {
        help++;
      }
    }
    summaries.add(
      RoomSummary(
        room: room,
        building: roomBuildings[room]!,
        eventCount: ev.length,
        firstEvent: ev.isEmpty ? null : ev.first.time,
        lastEvent: ev.isEmpty ? null : ev.last.time,
        systemSessions: u.sessions,
        systemHours: u.hours,
        utilization: u.utilization,
        afterHoursHours: u.afterHoursHours,
        averageSessionHours: u.averageSessionHours,
        reboots: s.reboots,
        deviceHours: devices.hoursByRoom[room] ?? 0,
        deviceIds: List.unmodifiable(
          {for (final d in s.devices) d.deviceId}.toList()..sort(),
        ),
        topInput: roomInputs == null || roomInputs.isEmpty
            ? null
            : roomInputs.first,
        issueCounts: countBySeverity(issuesByRoom[room] ?? const []),
        onlineFraction: connByRoom[room]?.onlineFraction,
        helpEvents: help,
        buttonPresses: uiByRoom[room]?.presses ?? 0,
      ),
    );
  }

  final unclassifiedList =
      <MetricCount>[
        for (final m in unclassified.entries)
          for (final a in m.value.entries) MetricCount(m.key, a.key, a.value),
      ]..sort((a, b) {
        final c = b.count.compareTo(a.count);
        if (c != 0) return c;
        final d = a.metric.compareTo(b.metric);
        return d != 0 ? d : a.action.compareTo(b.action);
      });

  return AnalysisResult(
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    useLocalTime: config.useLocalTime,
    timeZoneLabel: bucketer.zoneLabel(rangeEnd),
    rooms: List.unmodifiable(rooms),
    buildings: List.unmodifiable(roomBuildings.values.toSet().toList()..sort()),
    roomBuildings: Map.unmodifiable(roomBuildings),
    overview: overview,
    inputs: inputs,
    devices: devices,
    system: system,
    connectivity: connectivity,
    ui: ui,
    audio: audio,
    issues: issues,
    forecast: forecast,
    roomSummaries: List.unmodifiable(summaries),
    sessions: Map.unmodifiable(ctx.sessions),
    dataQuality: DataQuality(
      skippedRows: dataset.skippedRows,
      excludedEvents: excludedEvents,
      adminEvents: adminEvents,
      unclassified: List.unmodifiable(unclassifiedList.take(50)),
      unclassifiedTotal: unclassifiedTotal,
      orphanStops: orphanStops,
      duplicateStarts: duplicateStarts,
      unterminatedSessions: unterminated,
      warnings: List.unmodifiable([
        ...dataset.warnings,
        ...classifier.warnings,
      ]),
    ),
  );
}
