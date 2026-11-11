import 'package:flutter/foundation.dart';

import '../data/models.dart';

/// Date range shortcuts. "Last N days" ranges end at the end of the loaded
/// data (not "now"), so an older export still shows its most recent period.
enum DatePreset {
  last7('Last 7 days', 7),
  last30('Last 30 days', 30),
  last90('Last 90 days', 90),
  semester('Semester (16 weeks)', 112),
  all('All data', null),
  custom('Custom range', null);

  const DatePreset(this.label, this.days);

  final String label;
  final int? days;
}

/// A half-open UTC time window [start, end).
@immutable
class TimeWindow {
  const TimeWindow(this.start, this.end);

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);

  @override
  bool operator ==(Object other) =>
      other is TimeWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TimeWindow(${start.toIso8601String()}, ${end.toIso8601String()})';
}

/// The dashboard filters the user has chosen.
@immutable
class DashboardFilters {
  const DashboardFilters({
    this.preset = DatePreset.all,
    this.customWindow,
    this.buildings = const {},
    this.rooms = const {},
  });

  final DatePreset preset;

  /// Used when [preset] is [DatePreset.custom].
  final TimeWindow? customWindow;

  /// Selected buildings (empty = all).
  final Set<String> buildings;

  /// Selected rooms (empty = all rooms of the selected buildings).
  final Set<String> rooms;

  bool get isDefault =>
      preset == DatePreset.all && buildings.isEmpty && rooms.isEmpty;

  DashboardFilters copyWith({
    DatePreset? preset,
    TimeWindow? customWindow,
    Set<String>? buildings,
    Set<String>? rooms,
  }) =>
      DashboardFilters(
        preset: preset ?? this.preset,
        customWindow: customWindow ?? this.customWindow,
        buildings: buildings ?? this.buildings,
        rooms: rooms ?? this.rooms,
      );

  /// The time window for [dataset].
  TimeWindow windowFor(Dataset dataset) {
    final full = TimeWindow(dataset.rangeStart, dataset.rangeEnd);
    switch (preset) {
      case DatePreset.all:
        return full;
      case DatePreset.custom:
        final c = customWindow;
        if (c == null) return full;
        return c;
      case DatePreset.last7:
      case DatePreset.last30:
      case DatePreset.last90:
      case DatePreset.semester:
        final start = dataset.rangeEnd.subtract(Duration(days: preset.days!));
        return TimeWindow(
            start.isBefore(dataset.rangeStart) ? dataset.rangeStart : start,
            dataset.rangeEnd);
    }
  }
}

/// Derives the building of a client name with the configured pattern
/// (capture group 1, upper-cased). Clients that do not match are grouped
/// under "Other".
class BuildingClassifier {
  BuildingClassifier(String pattern)
      : _re = _compile(pattern);

  static const String other = 'Other';

  final RegExp? _re;
  final Map<String, String> _cache = {};

  static RegExp? _compile(String pattern) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } on FormatException {
      return null;
    }
  }

  String buildingOf(String client) => _cache.putIfAbsent(client, () {
        final m = _re?.firstMatch(client);
        if (m == null || m.groupCount < 1) return other;
        final g = m.group(1);
        if (g == null || g.isEmpty) return other;
        return g.toUpperCase();
      });
}
