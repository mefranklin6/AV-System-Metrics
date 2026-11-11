// Test helpers for the analytics engine. Pure Dart.

import 'dart:io';

import 'package:metrics_visualizer/analytics/analytics.dart';

/// Monday 2026-01-05 00:00 UTC: a convenient week-aligned origin.
final DateTime monday = DateTime.utc(2026, 1, 5);

/// Config bucketing in UTC (tests must not depend on the machine zone).
const AnalysisConfig utcConfig = AnalysisConfig(useLocalTime: false);

int _seq = 0;

/// Builds an event. Each gets a unique, increasing event id so ordering of
/// same-timestamp events is deterministic and follows creation order.
MetricEvent ev(String room, DateTime t, String metric, String action) {
  _seq++;
  return MetricEvent(
    clientName: room,
    timestamp: t,
    metric: metric,
    action: action,
    eventId: 'e${_seq.toString().padLeft(9, '0')}',
  );
}

/// Builds a dataset over `[start, end)` (defaults: first/last event).
Dataset ds(
  List<MetricEvent> events, {
  DateTime? start,
  DateTime? end,
  List<HeartbeatBucket> heartbeats = const [],
  int? retentionDays,
}) {
  final sorted = List.of(events)..sort();
  return Dataset(
    events: events,
    heartbeats: heartbeats,
    rangeStart: start ?? (sorted.isEmpty ? monday : sorted.first.timestamp),
    rangeEnd:
        end ??
        (sorted.isEmpty
            ? monday.add(const Duration(days: 1))
            : sorted.last.timestamp.add(const Duration(seconds: 1))),
    origin: DatasetOrigin.demo,
    description: 'test',
    heartbeatRetentionDays: retentionDays,
  );
}

/// Shorthand for `Duration(minutes: m)`.
Duration min(int m) => Duration(minutes: m);

/// Shorthand for `Duration(hours: h)`.
Duration hrs(num h) => Duration(microseconds: (h * 3.6e9).round());

/// Rows of `test/fixtures/production_sample.csv` (heartbeats included) as
/// maps keyed by header name. Minimal parser: the fixture has no quoted
/// fields.
List<Map<String, String>> readProductionSample() {
  final lines = File('test/fixtures/production_sample.csv')
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  final header = lines.first.split(',');
  return [
    for (final line in lines.skip(1))
      () {
        final cells = line.split(',');
        return {
          for (var i = 0; i < header.length; i++)
            header[i]: i < cells.length ? cells[i] : '',
        };
      }(),
  ];
}

/// The production sample as a [Dataset] (heartbeats as hourly buckets).
Dataset productionSampleDataset() {
  final events = <MetricEvent>[];
  final hb = <String, int>{};
  for (final row in readProductionSample()) {
    final t = DateTime.parse(row['event_timestamp']!).toUtc();
    if (row['action'] == heartbeatAction) {
      final hour = DateTime.utc(t.year, t.month, t.day, t.hour);
      final key = '${row['clientname']}|${hour.toIso8601String()}';
      hb[key] = (hb[key] ?? 0) + 1;
      continue;
    }
    events.add(
      MetricEvent(
        clientName: row['clientname']!,
        timestamp: t,
        metric: row['metric']!,
        action: row['action']!,
        eventId: row['event_id'],
      ),
    );
  }
  final buckets = [
    for (final e in hb.entries)
      HeartbeatBucket(
        clientName: e.key.split('|').first,
        hourStart: DateTime.parse(e.key.split('|').last),
        count: e.value,
      ),
  ];
  return ds(events, heartbeats: buckets);
}
