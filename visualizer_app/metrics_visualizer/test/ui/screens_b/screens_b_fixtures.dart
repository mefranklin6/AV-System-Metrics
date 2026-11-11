import 'package:metrics_visualizer/data/demo_data.dart';
import 'package:metrics_visualizer/data/models.dart';

// Datasets shared by the screens_b tests. No Flutter app imports here, so
// pure logic tests can use them without compiling the whole app.

/// Fixed end so every run sees the same demo campus.
final DateTime demoEnd = DateTime.utc(2026, 11, 10);

final Map<int, Dataset> _demoCache = {};

/// The deterministic demo campus for [weeks] weeks (cached per run).
Dataset demoDataset(int weeks) =>
    _demoCache.putIfAbsent(weeks, () => generateDemoDataset(end: demoEnd, weeks: weeks));

/// A copy of [ds] without heartbeats and without connection events.
Dataset withoutConnectivity(Dataset ds) => Dataset(
      events: [
        for (final e in ds.events)
          if (e.action != 'Connected' && e.action != 'Disconnected') e,
      ],
      heartbeats: const [],
      rangeStart: ds.rangeStart,
      rangeEnd: ds.rangeEnd,
      origin: ds.origin,
      description: 'Demo without connectivity',
    );

/// A tiny dataset with one quiet room: one normal session, no heartbeats,
/// so nothing is flagged.
Dataset quietDataset() {
  final start = DateTime.utc(2026, 11, 2, 14);
  MetricEvent ev(Duration offset, String metric, String action) => MetricEvent(
        clientName: 'QUIET_101',
        timestamp: start.add(offset),
        metric: metric,
        action: action,
      );
  return Dataset(
    events: [
      ev(Duration.zero, 'System - User', 'Started'),
      ev(const Duration(minutes: 1), 'pc', 'Started'),
      ev(const Duration(minutes: 50), 'System - User', 'Stopped'),
    ],
    heartbeats: const [],
    rangeStart: DateTime.utc(2026, 11, 2),
    rangeEnd: DateTime.utc(2026, 11, 3),
    origin: DatasetOrigin.csv,
    description: 'quiet.csv',
  );
}
