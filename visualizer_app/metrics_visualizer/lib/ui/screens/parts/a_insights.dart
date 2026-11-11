// Plain-language findings for the Overview screen. Pure functions of the
// analysis result (no BuildContext), so they are unit-testable and every
// figure quoted comes straight from the engine.
import '../../../analytics/analytics.dart';
import '../../../state/navigation_state.dart';
import '../../widgets/formatters.dart';
import 'a_common.dart';

/// Utilization below this share of business hours counts as "rarely used".
const double lowUtilizationThreshold = 0.05;

/// Share of power-offs by inactivity worth pointing out.
const double inactivityInsightThreshold = 0.10;

/// Share of system-on time outside business hours worth pointing out.
const double afterHoursInsightThreshold = 0.15;

/// Builds up to [max] findings, strongest patterns first. Each one states
/// what the data shows; none of them assumes why it happened.
///
/// [leftOnHours] is the long device session threshold from the settings, used
/// only in wording.
List<Insight> buildInsights(AnalysisResult a, {int max = 10, int leftOnHours = 12}) {
  if (a.isEmpty) return const [];
  final fmt = Fmt(utc: true);
  final out = <Insight>[];
  final roomTotal = a.rooms.length;

  // ---- worth reviewing
  final critical = a.overview.issueCounts[IssueSeverity.critical] ?? 0;
  if (critical > 0) {
    out.add(
      Insight(
        InsightKind.attention,
        '$critical critical ${critical == 1 ? 'pattern was' : 'patterns were'} found, most often '
        '${_mostCommonTitle(a.issues.where((i) => i.severity == IssueSeverity.critical))}. '
        'The Issues page lists each one with its evidence.',
        destination: AppDestination.issues,
      ),
    );
  }
  if (a.devices.leftOnSessions > 0) {
    final n = a.devices.leftOnSessions;
    out.add(
      Insight(
        InsightKind.attention,
        '${fmt.count(n)} device ${n == 1 ? 'session' : 'sessions'} lasted more than $leftOnHours hours. '
        'On-hours count toward rated lamp and panel life.',
        destination: AppDestination.devices,
      ),
    );
  }

  // ---- budget: least-used sources
  // Least used first.
  final campusRare =
      [
        for (final u in a.inputs.underused)
          if (u.kind == UnderuseKind.rarelyUsedCampus) u,
      ]..sort((x, y) {
        final c = (x.selectionShare + x.timeShare).compareTo(y.selectionShare + y.timeShare);
        return c != 0 ? c : x.label.compareTo(y.label);
      });
  final campusByKey = {for (final s in a.inputs.campus) s.key: s};
  for (final u in campusRare.take(2)) {
    final rooms = campusByKey[u.key]?.roomCount ?? 0;
    out.add(
      Insight(
        InsightKind.saving,
        '${u.label} was selected in $rooms of $roomTotal ${roomTotal == 1 ? 'room' : 'rooms'} '
        '(${fmt.percent(u.selectionShare)} of selections, ${fmt.percent(u.timeShare)} of time on screen): '
        'one of the least-used sources campus-wide.',
        destination: AppDestination.inputs,
      ),
    );
  }
  if (campusRare.length > 2) {
    final rest = campusRare.skip(2).map((u) => u.label).join(', ');
    out.add(
      Insight(
        InsightKind.saving,
        '${campusRare.length - 2} more ${campusRare.length - 2 == 1 ? 'source is' : 'sources are'} '
        'rarely used campus-wide: $rest.',
        destination: AppDestination.inputs,
      ),
    );
  }
  final neverUsed = [
    for (final u in a.inputs.underused)
      if (u.kind == UnderuseKind.neverUsedInRoom) u,
  ];
  if (neverUsed.isNotEmpty) {
    final e = neverUsed.first;
    out.add(
      Insight(
        InsightKind.saving,
        '${neverUsed.length} room and source ${neverUsed.length == 1 ? 'combination had' : 'combinations had'} '
        'no selections although other rooms in the same building selected those sources '
        '(for example ${e.label} in ${e.room}). The data only shows sources that were selected, '
        'so it cannot say whether these sources are installed in those rooms.',
        destination: AppDestination.inputs,
      ),
    );
  }

  // ---- budget: low utilization
  final measured = [
    for (final r in a.system.rooms)
      if (r.businessHoursAvailable > 0) r,
  ];
  final low = [
    for (final r in measured)
      if (r.utilization < lowUtilizationThreshold) r,
  ]..sort((x, y) => x.utilization.compareTo(y.utilization));
  if (low.isNotEmpty && measured.length >= 2) {
    final names = low.take(3).map((r) => r.room).join(', ');
    out.add(
      Insight(
        InsightKind.saving,
        '${low.length} of ${measured.length} rooms were in use less than '
        '${fmt.percent(lowUtilizationThreshold)} of business hours (lowest: $names).',
        destination: AppDestination.systemUsage,
      ),
    );
  }

  // ---- energy: inactivity power-offs and after-hours use
  final reasons = a.system.offReasons;
  final ended = reasons.entries.where((e) => e.key != OffReason.truncated).fold<int>(0, (s, e) => s + e.value);
  final inactivity = reasons[OffReason.inactivity] ?? 0;
  if (ended > 0 && inactivity >= 3 && inactivity / ended >= inactivityInsightThreshold) {
    out.add(
      Insight(
        InsightKind.energy,
        '${fmt.percent(inactivity / ended)} of sessions (${fmt.count(inactivity)}) ended with an '
        'inactivity power-off reason. How long a room stays on before that depends on each '
        "room's program.",
        destination: AppDestination.systemUsage,
      ),
    );
  }
  final afterHours = a.system.rooms.fold<double>(0, (s, r) => s + r.afterHoursHours);
  if (a.system.totalHours > 0 && afterHours / a.system.totalHours >= afterHoursInsightThreshold) {
    out.add(
      Insight(
        InsightKind.energy,
        '${fmt.percent(afterHours / a.system.totalHours)} of system-on time '
        '(${fmt.hours(afterHours)}) was outside business hours.',
        destination: AppDestination.systemUsage,
      ),
    );
  }

  // ---- patterns in controls, sources and help-labelled events
  final usage = a.issues.where((i) => const {IssueArea.controls, IssueArea.sources, IssueArea.help}.contains(i.area)).length;
  if (usage > 0) {
    out.add(
      Insight(
        InsightKind.pattern,
        '${fmt.count(usage)} ${usage == 1 ? 'pattern was' : 'patterns were'} found in control, source '
        'or help-labelled events. The Issues page lists each one with its evidence.',
        destination: AppDestination.issues,
      ),
    );
  }

  // ---- context
  final o = a.overview;
  if (o.busiestWeekday != null && o.busiestHour != null && o.busiestOccupancy > 0) {
    out.add(
      Insight(
        InsightKind.info,
        'The busiest time is ${Fmt.weekday(o.busiestWeekday!)} at ${Fmt.hourOfDay(o.busiestHour!)} '
        '(${a.timeZoneLabel}), when on average ${fmt.percent(o.busiestOccupancy)} of rooms are in use.',
        destination: AppDestination.systemUsage,
      ),
    );
  }
  final change = lastPeriodChange(a.system.weekly);
  if (change != null && change.abs() >= 0.05) {
    out.add(
      Insight(
        InsightKind.info,
        'System use was ${change > 0 ? 'up' : 'down'} ${fmt.percent(change.abs())} in the last '
        'complete week compared with the week before.',
        destination: AppDestination.systemUsage,
      ),
    );
  }
  return out.take(max).toList();
}

String _mostCommonTitle(Iterable<Issue> issues) {
  final counts = <String, int>{};
  for (final i in issues) {
    counts[i.type.label] = (counts[i.type.label] ?? 0) + 1;
  }
  if (counts.isEmpty) return 'unknown patterns';
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a).key;
  return best.toLowerCase();
}
