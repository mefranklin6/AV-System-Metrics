import 'package:flutter/material.dart';

import '../../analytics/analytics.dart';
import '../widgets/widgets.dart';
import 'parts/a_cards.dart';
import 'parts/a_charts.dart';
import 'parts/a_common.dart';

/// When rooms are turned on and off, how long sessions last, why they end
/// and how much of the teaching day each room is in use.
class SystemUsageScreen extends StatelessWidget {
  const SystemUsageScreen({super.key});

  @override
  Widget build(BuildContext context) => AnalysisPage(
    title: 'System usage',
    subtitle: 'Power-on times, session lengths, off reasons and room utilization.',
    builder: (context, analysis) {
      if (analysis.isEmpty) return noMatchingRooms(context);
      final s = analysis.system;
      final tz = analysis.timeZoneLabel;
      return [
        _SystemKpis(system: s),
        ResponsiveGrid(
          minChildWidth: 420,
          maxColumns: 2,
          children: [
            HourlyCountsCard(
              title: 'Power-on time of day',
              description:
                  'How many sessions started in each hour. Sessions already on when the data '
                  'begins are left out.',
              counts: s.powerOnByHour,
              noun: 'power-ons',
              timeZoneLabel: tz,
              seriesIndex: 0,
            ),
            HourlyCountsCard(
              title: 'Power-off time of day',
              description:
                  'How many sessions ended in each hour. Sessions still on at the end of the data '
                  'or closed by the session cap are left out.',
              counts: s.powerOffByHour,
              noun: 'power-offs',
              timeZoneLabel: tz,
              seriesIndex: 1,
            ),
          ],
        ),
        HeatmapCard(
          heatmap: s.occupancy,
          title: 'Rooms in use by weekday and hour',
          description: 'Average share of rooms with the system on in each hour of the week.',
          cellNoun: 'of rooms in use',
          timeZoneLabel: tz,
        ),
        ResponsiveGrid(
          minChildWidth: 420,
          maxColumns: 2,
          children: [
            _SessionLengthCard(system: s),
            _OffReasonCard(system: s),
          ],
        ),
        if (s.otherOffReasons.isNotEmpty) OtherOffReasonsCard(reasons: s.otherOffReasons),
        _UtilizationCard(system: s),
      ];
    },
  );
}

/// "Mon-Fri 7 AM to 10 PM".
String businessHoursLabel(BusinessHours b) {
  final days = {...b.weekdays.where((d) => d >= 1 && d <= 7)}.toList()..sort();
  final consecutive = days.length > 1 && days.last - days.first == days.length - 1;
  final dayText = days.isEmpty
      ? 'no days'
      : consecutive
      ? '${Fmt.weekday(days.first, short: true)}-${Fmt.weekday(days.last, short: true)}'
      : days.map((d) => Fmt.weekday(d, short: true)).join(', ');
  return '$dayText ${Fmt.hourOfDay(b.startHour.clamp(0, 23))} to ${Fmt.hourOfDay(b.endHour % 24)}';
}

class _SystemKpis extends StatelessWidget {
  const _SystemKpis({required this.system});

  final SystemUsage system;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final inUse = system.rooms.fold<double>(0, (s, r) => s + r.businessHoursInUse);
    final available = system.rooms.fold<double>(0, (s, r) => s + r.businessHoursAvailable);
    final afterHours = system.rooms.fold<double>(0, (s, r) => s + r.afterHoursHours);
    return ResponsiveGrid(
      minChildWidth: 220,
      maxColumns: 5,
      children: [
        KpiTile(
          label: 'Sessions',
          value: fmt.count(system.sessionCount),
          icon: Icons.power_settings_new,
          caption: 'times a room was turned on',
        ),
        KpiTile(
          label: 'System-on hours',
          value: fmt.hours(system.totalHours),
          icon: Icons.timer_outlined,
          caption: 'all rooms',
        ),
        KpiTile(
          label: 'Average session',
          value: fmt.hours(system.averageSessionHours),
          icon: Icons.av_timer,
          caption: 'median ${fmt.hours(system.medianSessionHours)}',
        ),
        KpiTile(
          label: 'Utilization',
          value: fmt.percent(available <= 0 ? 0 : inUse / available),
          icon: Icons.event_available_outlined,
          caption: 'of business hours (${businessHoursLabel(system.businessHours)})',
        ),
        KpiTile(
          label: 'After-hours use',
          value: fmt.hours(afterHours),
          icon: Icons.bedtime_outlined,
          caption: '${fmt.percent(system.totalHours <= 0 ? 0 : afterHours / system.totalHours)} of system-on time',
        ),
      ],
    );
  }
}

class _SessionLengthCard extends StatelessWidget {
  const _SessionLengthCard({required this.system});

  final SystemUsage system;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    const title = 'Session length';
    final buckets = system.sessionLengths;
    final total = buckets.fold<int>(0, (s, b) => s + b.count);
    if (total == 0) {
      return const EmptyChartCard(title: title, message: 'No complete sessions in this period.');
    }
    final top = buckets.reduce((a, b) => b.count > a.count ? b : a);
    final short = buckets.where((b) => (b.maxMinutes ?? double.infinity) <= 5).fold<int>(0, (s, b) => s + b.count);
    final summary =
        'The most common session length is ${top.label} '
        '(${fmt.count(top.count)} of ${fmt.count(total)} sessions, ${fmt.percent(top.count / total)}). '
        'Median ${fmt.hours(system.medianSessionHours)}.'
        '${short > 0 ? ' ${fmt.count(short)} sessions lasted under 5 minutes.' : ''}';
    return AccessibleChartCard(
      title: title,
      description: 'How long rooms stay on once turned on.',
      summary: summary,
      chartHeight: 220,
      chart: ColumnChart(
        color: palette.colorAt(2),
        pattern: palette.patternAt(2),
        yFormat: (v) => fmt.compact(v),
        data: [
          for (final b in buckets)
            ColumnDatum(label: b.label, value: b.count.toDouble(), valueLabel: fmt.count(b.count)),
        ],
      ),
      table: ChartTable(
        columns: const [
          ChartColumn('Length'),
          ChartColumn('Sessions', numeric: true),
          ChartColumn('Share', numeric: true),
        ],
        rows: [
          for (final b in buckets) [b.label, fmt.count(b.count), fmt.percent(b.count / total)],
        ],
        rawRows: [
          for (final b in buckets) [b.label, b.count, b.count / total],
        ],
      ),
    );
  }
}

class _OffReasonCard extends StatelessWidget {
  const _OffReasonCard({required this.system});

  final SystemUsage system;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    const title = 'Why sessions ended';
    final entries = [
      for (final r in OffReason.values)
        if ((system.offReasons[r] ?? 0) > 0) (r, system.offReasons[r]!),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    final total = entries.fold<int>(0, (s, e) => s + e.$2);
    if (total == 0) {
      return const EmptyChartCard(title: title, message: 'No sessions ended in this period.');
    }
    final ended = entries.where((e) => e.$1 != OffReason.truncated).fold<int>(0, (s, e) => s + e.$2);
    final inactivity = system.offReasons[OffReason.inactivity] ?? 0;
    final scheduled = system.offReasons[OffReason.scheduled] ?? 0;
    final user = system.offReasons[OffReason.user] ?? 0;
    final other = system.offReasons[OffReason.other] ?? 0;
    final top = entries.first;
    final summary =
        'Most sessions ended as "${top.$1.label}": ${fmt.count(top.$2)} of ${fmt.count(total)} '
        '(${fmt.percent(top.$2 / total)}).';
    String sessions(int n) => '${fmt.count(n)} ${n == 1 ? 'session' : 'sessions'}';
    final insights = <String>[
      if (ended > 0 && inactivity > 0)
        '${sessions(inactivity)} (${fmt.percent(inactivity / ended)}) ended with an inactivity reason.',
      if (ended > 0 && scheduled > 0)
        '${sessions(scheduled)} (${fmt.percent(scheduled / ended)}) ended with a schedule reason.',
      if (ended > 0 && user > 0)
        '${sessions(user)} (${fmt.percent(user / ended)}) ended with a user reason.',
      if (other > 0)
        '${sessions(other)} ended with a reason outside the standard groups; the next card lists them as logged.',
    ];
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final e in entries)
            BarDatum(
              label: e.$1.label,
              value: e.$2.toDouble(),
              valueLabel: '${fmt.count(e.$2)} (${fmt.percent(e.$2 / total)})',
              color: palette.colorAt(e.$1.index % maxNamedSeries),
              pattern: palette.patternAt(e.$1.index % maxNamedSeries),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: 'How each system session ended. User, Schedule, Inactivity and Remote are the reason '
              'groups set under Settings > Event recognition; other reasons are grouped as "Other reason".',
          summary: '$summary ${insights.isEmpty ? '' : insights.first}',
          chartHeight: height,
          chart: RankedBarChart(stacked: stacked, items: items),
          footer: insights.isEmpty
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [for (final i in insights) Padding(padding: const EdgeInsets.only(top: 4), child: Text(i))],
                ),
          table: ChartTable(
            columns: const [
              ChartColumn('Off reason'),
              ChartColumn('Sessions', numeric: true),
              ChartColumn('Share', numeric: true),
            ],
            rows: [
              for (final e in entries) [e.$1.label, fmt.count(e.$2), fmt.percent(e.$2 / total)],
            ],
            rawRows: [
              for (final e in entries) [e.$1.label, e.$2, e.$2 / total],
            ],
          ),
        );
      },
    );
  }
}

/// Power-off reasons outside the standard groups, exactly as logged
/// ([SystemUsage.otherOffReasons]), most frequent first.
class OtherOffReasonsCard extends StatelessWidget {
  const OtherOffReasonsCard({super.key, required this.reasons});

  final Map<String, int> reasons;

  static const String title = 'Other power-off reasons, as logged';

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    final entries = reasons.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final total = entries.fold<int>(0, (s, e) => s + e.value);
    final idx = OffReason.other.index % maxNamedSeries;
    final top = entries.first;
    final summary =
        '${fmt.count(total)} ${total == 1 ? 'session' : 'sessions'} ended with ${entries.length} '
        '${entries.length == 1 ? 'reason' : 'different reasons'} outside the standard groups. Most common: '
        '"${top.key}" (${fmt.count(top.value)}).';
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final e in entries)
            BarDatum(
              label: e.key,
              value: e.value.toDouble(),
              valueLabel: '${fmt.count(e.value)} (${fmt.percent(e.value / total)})',
              color: palette.colorAt(idx),
              pattern: palette.patternAt(idx),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: 'The text after the dash of a system power Stopped event, for reasons that are in none '
              'of the reason groups. Add a reason to a group under Settings > Event recognition to count it there.',
          summary: summary,
          chartHeight: height,
          chart: RankedBarChart(stacked: stacked, items: items),
          table: ChartTable(
            columns: const [
              ChartColumn('Reason as logged'),
              ChartColumn('Sessions', numeric: true),
              ChartColumn('Share', numeric: true),
            ],
            rows: [
              for (final e in entries) [e.key, fmt.count(e.value), fmt.percent(e.value / total)],
            ],
            rawRows: [
              for (final e in entries) [e.key, e.value, e.value / total],
            ],
          ),
        );
      },
    );
  }
}

/// Business-hours utilization per room, most or least used first.
class _UtilizationCard extends StatefulWidget {
  const _UtilizationCard({required this.system});

  final SystemUsage system;

  @override
  State<_UtilizationCard> createState() => _UtilizationCardState();
}

class _UtilizationCardState extends State<_UtilizationCard> {
  static const int _bars = 15;
  bool _most = true;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    final rooms = [...widget.system.rooms]
      ..sort((a, b) {
        final c = b.utilization.compareTo(a.utilization);
        return c != 0 ? c : a.room.compareTo(b.room);
      });
    const title = 'Utilization by room';
    if (rooms.isEmpty) {
      return const EmptyChartCard(title: title, message: 'No rooms in this period.');
    }
    final window = businessHoursLabel(widget.system.businessHours);
    final ordered = _most ? rooms : rooms.reversed.toList();
    final shown = ordered.take(_bars).toList();
    final avg = rooms.fold<double>(0, (s, r) => s + r.utilization) / rooms.length;
    final summary =
        'Average utilization is ${fmt.percent(avg)} of business hours. '
        'Highest: ${rooms.first.room} at ${fmt.percent(rooms.first.utilization)}. '
        'Lowest: ${rooms.last.room} at ${fmt.percent(rooms.last.utilization)}.'
        '${rooms.length > _bars ? ' The chart shows the ${_most ? 'most' : 'least'} used $_bars; the table lists all ${rooms.length}.' : ''}';
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final r in shown)
            BarDatum(
              label: r.room,
              value: r.utilization,
              valueLabel: fmt.percent(r.utilization),
              color: palette.colorAt(4),
              pattern: palette.patternAt(4),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: 'Share of business hours ($window) each room had its system on.',
          summary: summary,
          chartHeight: height,
          actions: [
            if (rooms.length > _bars)
              Semantics(
                label: 'Show',
                container: true,
                explicitChildNodes: true,
                child: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Most used')),
                    ButtonSegment(value: false, label: Text('Least used')),
                  ],
                  selected: {_most},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => _most = s.first),
                ),
              ),
          ],
          chart: RankedBarChart(stacked: stacked, maxValue: 1, items: items),
          table: ChartTable(
            columns: const [
              ChartColumn('Room'),
              ChartColumn('Building'),
              ChartColumn('Utilization', numeric: true),
              ChartColumn('Business hours in use', numeric: true),
              ChartColumn('Business hours available', numeric: true),
              ChartColumn('After-hours use', numeric: true),
              ChartColumn('Sessions', numeric: true),
              ChartColumn('System-on hours', numeric: true),
              ChartColumn('Average session', numeric: true),
            ],
            rows: [
              for (final r in rooms)
                [
                  r.room,
                  r.building,
                  fmt.percent(r.utilization),
                  fmt.hours(r.businessHoursInUse),
                  fmt.hours(r.businessHoursAvailable),
                  fmt.hours(r.afterHoursHours),
                  fmt.count(r.sessions),
                  fmt.hours(r.hours),
                  fmt.hours(r.averageSessionHours),
                ],
            ],
            rawRows: [
              for (final r in rooms)
                [
                  r.room,
                  r.building,
                  r.utilization,
                  r.businessHoursInUse,
                  r.businessHoursAvailable,
                  r.afterHoursHours,
                  r.sessions,
                  r.hours,
                  r.averageSessionHours,
                ],
            ],
          ),
        );
      },
    );
  }
}
