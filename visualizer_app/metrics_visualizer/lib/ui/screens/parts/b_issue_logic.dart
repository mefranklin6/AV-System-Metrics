// Filtering, sorting and CSV export for the Issues screen. No widgets here,
// so it is easy to unit test.

import 'package:flutter/foundation.dart';

import '../../../analytics/analytics.dart';
import '../../widgets/accessible_chart_card.dart' show ChartColumn, ChartTable;
import 'b_common.dart' show instantIso;

/// How far back (from the end of the analysed range) to show issues.
enum IssuePeriod {
  any('Any time', null),
  lastDay('Last 24 hours', 1),
  lastWeek('Last 7 days', 7),
  lastMonth('Last 30 days', 30);

  const IssuePeriod(this.label, this.days);

  final String label;
  final int? days;
}

/// Order of the issue list.
enum IssueSort {
  newest('Newest first'),
  oldest('Oldest first'),
  severity('Most severe first'),
  room('Room, A to Z');

  const IssueSort(this.label);

  final String label;
}

/// The Issues screen's local filters. Empty sets mean "all".
@immutable
class IssueFilter {
  const IssueFilter({
    this.types = const {},
    this.severities = const {},
    this.areas = const {},
    this.building,
    this.room,
    this.period = IssuePeriod.any,
    this.query = '',
    this.sort = IssueSort.newest,
  });

  final Set<IssueType> types;
  final Set<IssueSeverity> severities;
  final Set<IssueArea> areas;

  /// Building to show (null = all).
  final String? building;

  /// Room to show (null = all rooms of [building]).
  final String? room;
  final IssuePeriod period;

  /// Case-insensitive text matched against title, room, building, subject
  /// and explanation.
  final String query;
  final IssueSort sort;

  /// True when nothing narrows the list (sort order does not count).
  bool get isDefault =>
      types.isEmpty &&
      severities.isEmpty &&
      areas.isEmpty &&
      building == null &&
      room == null &&
      period == IssuePeriod.any &&
      query.trim().isEmpty;

  IssueFilter copyWith({
    Set<IssueType>? types,
    Set<IssueSeverity>? severities,
    Set<IssueArea>? areas,
    String? Function()? building,
    String? Function()? room,
    IssuePeriod? period,
    String? query,
    IssueSort? sort,
  }) =>
      IssueFilter(
        types: types ?? this.types,
        severities: severities ?? this.severities,
        areas: areas ?? this.areas,
        building: building != null ? building() : this.building,
        room: room != null ? room() : this.room,
        period: period ?? this.period,
        query: query ?? this.query,
        sort: sort ?? this.sort,
      );

  /// Clears every filter but keeps the sort order.
  IssueFilter cleared() => IssueFilter(sort: sort);

  /// Toggles [value] in [set] (helper for chip groups).
  static Set<T> toggle<T>(Set<T> set, T value) =>
      set.contains(value) ? ({...set}..remove(value)) : {...set, value};

  /// Returns the issues that pass the filters, in [sort] order. Building
  /// and room values that no longer exist (after the data changed) are
  /// ignored rather than hiding everything.
  List<Issue> apply(
    List<Issue> issues, {
    required DateTime rangeEnd,
    Set<String> knownBuildings = const {},
    Set<String> knownRooms = const {},
  }) {
    final b = building != null && (knownBuildings.isEmpty || knownBuildings.contains(building))
        ? building
        : null;
    final r = room != null && (knownRooms.isEmpty || knownRooms.contains(room)) ? room : null;
    final since = period.days == null ? null : rangeEnd.subtract(Duration(days: period.days!));
    final q = query.trim().toLowerCase();
    final out = <Issue>[
      for (final i in issues)
        if ((types.isEmpty || types.contains(i.type)) &&
            (severities.isEmpty || severities.contains(i.severity)) &&
            (areas.isEmpty || areas.contains(i.area)) &&
            (b == null || i.building == b) &&
            (r == null || i.room == r) &&
            (since == null || !i.end.isBefore(since)) &&
            (q.isEmpty || _matches(i, q)))
          i,
    ];
    int byTime(Issue a, Issue b) => a.start.compareTo(b.start);
    int byId(Issue a, Issue b) => a.id.compareTo(b.id);
    switch (sort) {
      case IssueSort.newest:
        out.sort((a, b) {
          final c = byTime(b, a);
          return c != 0 ? c : byId(a, b);
        });
      case IssueSort.oldest:
        out.sort((a, b) {
          final c = byTime(a, b);
          return c != 0 ? c : byId(a, b);
        });
      case IssueSort.severity:
        out.sort((a, b) {
          final s = b.severity.index.compareTo(a.severity.index);
          if (s != 0) return s;
          final c = byTime(b, a);
          return c != 0 ? c : byId(a, b);
        });
      case IssueSort.room:
        out.sort((a, b) {
          final s = a.room.toLowerCase().compareTo(b.room.toLowerCase());
          if (s != 0) return s;
          final c = byTime(b, a);
          return c != 0 ? c : byId(a, b);
        });
    }
    return out;
  }

  static bool _matches(Issue i, String q) =>
      i.title.toLowerCase().contains(q) ||
      i.room.toLowerCase().contains(q) ||
      i.building.toLowerCase().contains(q) ||
      (i.subject?.toLowerCase().contains(q) ?? false) ||
      i.type.label.toLowerCase().contains(q) ||
      i.explanation.toLowerCase().contains(q);

  @override
  bool operator ==(Object other) =>
      other is IssueFilter &&
      setEquals(other.types, types) &&
      setEquals(other.severities, severities) &&
      setEquals(other.areas, areas) &&
      other.building == building &&
      other.room == room &&
      other.period == period &&
      other.query == query &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(types),
        Object.hashAllUnordered(severities),
        Object.hashAllUnordered(areas),
        building,
        room,
        period,
        query,
        sort,
      );
}

/// Columns of the issues CSV export.
const List<ChartColumn> issueCsvColumns = [
  ChartColumn('id'),
  ChartColumn('severity'),
  ChartColumn('type'),
  ChartColumn('area'),
  ChartColumn('building'),
  ChartColumn('room'),
  ChartColumn('subject'),
  ChartColumn('start_utc'),
  ChartColumn('end_utc'),
  ChartColumn('count', numeric: true),
  ChartColumn('title'),
  ChartColumn('explanation'),
  ChartColumn('worth_checking'),
  ChartColumn('evidence_events', numeric: true),
];

/// RFC 4180 CSV of [issues] (header row included). Text cells that start
/// with a spreadsheet formula character are neutralised (see
/// [ChartTable.toCsv]), because room names and subjects come from the
/// monitored systems and must not run as formulas when opened in Excel.
String issuesToCsv(List<Issue> issues) {
  final rows = <List<Object?>>[
    for (final i in issues)
      [
        i.id,
        i.severity.label,
        i.type.label,
        i.area.label,
        i.building,
        i.room,
        i.subject ?? '',
        instantIso(i.start),
        instantIso(i.end),
        i.count,
        i.title,
        i.explanation,
        i.suggestedAction,
        i.evidence.length,
      ],
  ];
  return ChartTable(
    columns: issueCsvColumns,
    rows: [for (final r in rows) [for (final c in r) '$c']],
    rawRows: rows,
  ).toCsv();
}

/// Counts issues per key, in enum order, leaving out zero counts.
Map<K, int> countIssuesBy<K extends Enum>(Iterable<Issue> issues, K Function(Issue) key, List<K> order) {
  final counts = {for (final k in order) k: 0};
  for (final i in issues) {
    final k = key(i);
    counts[k] = (counts[k] ?? 0) + 1;
  }
  return {for (final k in order) if (counts[k]! > 0) k: counts[k]!};
}
