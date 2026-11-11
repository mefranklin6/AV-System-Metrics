// Core data model shared by every data source (CSV import, Analytics API,
// demo data) and by the analytics engine. Keep this file free of Flutter
// imports so it can be used inside isolates and pure-Dart tests.

/// The action string the clients use for uptime pings.
const String heartbeatAction = 'Heartbeat';

/// One non-heartbeat row from `metric_events`.
///
/// Heartbeats are never stored as [MetricEvent]s; they are aggregated into
/// [HeartbeatBucket]s because they make up the large majority of rows.
class MetricEvent implements Comparable<MetricEvent> {
  const MetricEvent({
    required this.clientName,
    required this.timestamp,
    required this.metric,
    required this.action,
    this.eventId,
    this.receivedAt,
  });

  /// The sender, normally a room such as `BSS_245`.
  final String clientName;

  /// When the event happened on the control processor, always UTC.
  final DateTime timestamp;

  /// What was measured, such as `Projector 1`, `Source - HDMI 1` or `Volume Up Pressed`.
  final String metric;

  /// What happened, such as `Started`, `Stopped`, `Trace` or a custom action.
  final String action;

  /// Server-assigned UUID, when the source provides it.
  final String? eventId;

  /// When the server received the event (UTC), when the source provides it.
  final DateTime? receivedAt;

  @override
  int compareTo(MetricEvent other) {
    final byTime = timestamp.compareTo(other.timestamp);
    if (byTime != 0) return byTime;
    return (eventId ?? '').compareTo(other.eventId ?? '');
  }

  @override
  String toString() =>
      'MetricEvent($clientName, ${timestamp.toIso8601String()}, $metric, $action)';
}

/// Number of heartbeats a client sent during one UTC hour.
class HeartbeatBucket {
  const HeartbeatBucket({
    required this.clientName,
    required this.hourStart,
    required this.count,
  });

  final String clientName;

  /// Start of the UTC hour (minutes, seconds and sub-seconds are zero).
  final DateTime hourStart;

  final int count;
}

/// Where a [Dataset] came from, for display and accessibility announcements.
enum DatasetOrigin { csv, api, demo }

/// Everything the analytics engine needs. Immutable once built.
class Dataset {
  Dataset({
    required List<MetricEvent> events,
    required List<HeartbeatBucket> heartbeats,
    required this.rangeStart,
    required this.rangeEnd,
    required this.origin,
    required this.description,
    this.heartbeatRetentionDays,
    this.skippedRows = 0,
    List<String> warnings = const [],
  })  : events = List.unmodifiable(List.of(events)..sort()),
        heartbeats = List.unmodifiable(heartbeats),
        warnings = List.unmodifiable(warnings);

  /// Non-heartbeat events sorted by timestamp ascending.
  final List<MetricEvent> events;

  /// Hourly heartbeat counts. Empty when the source had no heartbeats.
  final List<HeartbeatBucket> heartbeats;

  /// Inclusive start of the period this dataset covers (UTC).
  final DateTime rangeStart;

  /// Exclusive end of the period this dataset covers (UTC).
  final DateTime rangeEnd;

  final DatasetOrigin origin;

  /// Human-readable source, such as a file name or server host.
  final String description;

  /// Server heartbeat retention, when known. Heartbeats older than this were
  /// purged, so missing heartbeats before that cutoff do not mean "offline".
  final int? heartbeatRetentionDays;

  /// Rows the importer could not parse.
  final int skippedRows;

  /// Plain-language notes from the importer that users should see, such
  /// as how ambiguous spreadsheet dates were read.
  final List<String> warnings;

  /// All client names present in events or heartbeats, sorted.
  late final List<String> clientNames = {
    for (final e in events) e.clientName,
    for (final h in heartbeats) h.clientName,
  }.toList()
    ..sort();

  bool get isEmpty => events.isEmpty && heartbeats.isEmpty;

  /// Returns a dataset restricted to [clients] (null = all) and to the
  /// half-open window [from, to) (null = keep the current bound).
  Dataset filter({Set<String>? clients, DateTime? from, DateTime? to}) {
    final start = from ?? rangeStart;
    final end = to ?? rangeEnd;
    bool keepClient(String c) => clients == null || clients.contains(c);
    return Dataset(
      events: [
        for (final e in events)
          if (keepClient(e.clientName) &&
              !e.timestamp.isBefore(start) &&
              e.timestamp.isBefore(end))
            e,
      ],
      heartbeats: [
        for (final h in heartbeats)
          if (keepClient(h.clientName) &&
              !h.hourStart.isBefore(start.subtract(const Duration(hours: 1))) &&
              h.hourStart.isBefore(end))
            h,
      ],
      rangeStart: start,
      rangeEnd: end,
      origin: origin,
      description: description,
      heartbeatRetentionDays: heartbeatRetentionDays,
      skippedRows: skippedRows,
      warnings: warnings,
    );
  }
}
