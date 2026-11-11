import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';
import 'parts/b_charts.dart';
import 'parts/b_common.dart';
import 'parts/b_table.dart';

/// Shown instead of an online percentage for a room that sent no heartbeats
/// ([RoomConnectivity.onlineFraction] is null): its online time is unknown,
/// not 0%.
const String noHeartbeatsText = 'No heartbeats';

/// Whether [r]'s last-seen time comes from a heartbeat and so is only known
/// to the hour (heartbeats are counted per hour).
bool lastSeenIsHourly(RoomConnectivity r) {
  final hb = r.lastHeartbeatHour, ev = r.lastEvent;
  return r.lastSeen != null && hb != null && (ev == null || hb.isAfter(ev));
}

/// The last-seen time as words: an exact time for an event, "During the
/// hour starting ..." for a heartbeat hour, or "Never".
String lastSeenText(RoomConnectivity r, Fmt fmt) {
  final seen = r.lastSeen;
  if (seen == null) return 'Never';
  if (lastSeenIsHourly(r)) return 'During the hour starting ${fmt.dateTime(r.lastHeartbeatHour!)}';
  return fmt.dateTime(seen);
}

/// "Exact" (an event), "Hour" (a heartbeat hour) or "" (never seen), for the
/// table and CSV.
String lastSeenPrecision(RoomConnectivity r) =>
    r.lastSeen == null ? '' : (lastSeenIsHourly(r) ? 'Hour (heartbeat)' : 'Exact (event)');

/// Device communication events, heartbeat coverage per room, heartbeat gaps
/// and devices whose communication state changed repeatedly.
class ConnectivityScreen extends StatefulWidget {
  const ConnectivityScreen({super.key});

  @override
  State<ConnectivityScreen> createState() => _ConnectivityScreenState();
}

enum _OnlineSort {
  lowest('Lowest first'),
  room('By room'),
  highest('Highest first');

  const _OnlineSort(this.label);
  final String label;
}

enum _EventView {
  byDevice('By device'),
  log('Event log');

  const _EventView(this.label);
  final String label;
}

class _ConnectivityScreenState extends State<ConnectivityScreen> {
  _OnlineSort _onlineSort = _OnlineSort.lowest;
  _EventView _eventView = _EventView.byDevice;
  static const int _offlinePage = 20;
  int _offlineVisible = _offlinePage;

  void _openRoom(String room) =>
      context.read<NavigationState>().goTo(AppDestination.rooms, room: room);

  @override
  Widget build(BuildContext context) {
    return AnalysisPage(
      title: 'Connectivity',
      subtitle: 'Device communication events, processor heartbeats and heartbeat gaps.',
      builder: (context, analysis) => _content(context, analysis),
    );
  }

  List<Widget> _content(BuildContext context, AnalysisResult analysis) {
    final c = analysis.connectivity;
    final fmt = Fmt.of(context);
    return [
      _kpis(context, c, fmt),
      _coverageCallout(context, analysis, fmt),
      if (c.rooms.any((r) => r.flapBursts > 0)) _flappingCallout(context, c),
      if (c.events.isEmpty) _noConnectionEvents(context) else ...[
        _timelineCard(context, c, fmt),
        _eventsCard(context, c, fmt),
      ],
      if (c.hasHeartbeatCoverage) ...[
        _onlineCard(context, c, fmt),
        _offlineCard(context, c, fmt),
      ],
    ];
  }

  // ------------------------------------------------------------------ KPIs

  Widget _kpis(BuildContext context, ConnectivityReport c, Fmt fmt) {
    final connects = c.events.where((e) => e.connected).length;
    final disconnects = c.events.length - connects;
    var online = 0, covered = 0;
    var withCoverage = 0;
    for (final r in c.rooms) {
      if (r.onlineFraction == null) continue;
      withCoverage++;
      online += r.onlineHours;
      covered += r.coveredHours;
    }
    final offline = [for (final r in c.rooms) ...r.offlinePeriods];
    final offlineRooms = {for (final o in offline) o.room}.length;
    final flapping = [
      for (final r in c.rooms)
        for (final t in r.targets)
          if (t.flapBursts > 0) t,
    ].length;
    return ResponsiveGrid(
      minChildWidth: 220,
      children: [
        KpiTile(
          label: 'Connection events',
          value: fmt.count(c.events.length),
          icon: Icons.cable_outlined,
          caption: '${fmt.count(connects)} connected · ${fmt.count(disconnects)} disconnected',
        ),
        KpiTile(
          label: 'Processors online',
          value: covered == 0 ? 'No data' : fmt.percent(online / covered),
          icon: Icons.monitor_heart_outlined,
          caption: covered == 0
              ? 'Needs heartbeat data'
              : 'of covered hours, ${fmt.count(withCoverage)} rooms with heartbeats'
                  '${c.rooms.length > withCoverage ? ', ${fmt.count(c.rooms.length - withCoverage)} without' : ''}',
        ),
        KpiTile(
          label: 'Heartbeat gaps',
          value: c.hasHeartbeatCoverage ? fmt.count(offline.length) : 'No data',
          icon: Icons.cloud_off_outlined,
          caption: c.hasHeartbeatCoverage
              ? 'in ${fmt.count(offlineRooms)} ${offlineRooms == 1 ? 'room' : 'rooms'}'
              : 'Needs heartbeat data',
        ),
        KpiTile(
          label: 'Repeated connection changes',
          value: fmt.count(flapping),
          icon: Icons.sync_problem_outlined,
          caption: flapping == 1 ? 'device changed state repeatedly' : 'devices changed state repeatedly',
        ),
      ],
    );
  }

  // -------------------------------------------------------------- coverage

  Widget _coverageCallout(BuildContext context, AnalysisResult analysis, Fmt fmt) {
    final c = analysis.connectivity;
    final retention = c.retentionDays;
    if (!c.hasHeartbeatCoverage) {
      return InfoCallout(
        tone: CalloutTone.warning,
        icon: Icons.monitor_heart_outlined,
        title: 'No heartbeat data in this range',
        message: 'Online percentages and heartbeat gaps are worked out from the heartbeats each room '
            'processor sends on a timer. This data has none for the selected rooms and dates.',
        children: [
          const BulletText('CSV exports: include the heartbeat rows (do not filter out action '
              "'Heartbeat'). They are most of the table, so a 30-day export is a good size."),
          const BulletText('Analytics API: heartbeats are loaded automatically for the requested range.'),
          BulletText(retention == null
              ? 'The server deletes heartbeats after its retention period (30 days by default), so older '
                  'ranges never have heartbeat data. Choose a recent date range.'
              : 'The server keeps heartbeats for $retention days, so older ranges never have heartbeat '
                  'data. Choose a recent date range.'),
        ],
      );
    }
    final start = c.coverageStart!, end = c.coverageEnd!;
    final coveredDays = end.difference(start).inMinutes / 1440;
    final rangeDays = analysis.rangeEnd.difference(analysis.rangeStart).inMinutes / 1440;
    final partial = rangeDays > 0 && coveredDays < rangeDays * 0.98;
    return InfoCallout(
      icon: Icons.history_toggle_off,
      title: 'What the online figures cover',
      message: 'Heartbeat data covers ${fmt.dateTime(start)} to ${fmt.dateTime(end)} '
          '(${fmt.decimal(coveredDays)} days). Online figures describe only this period.',
      children: [
        if (partial)
          BulletText('That is ${fmt.percent((coveredDays / rangeDays).clamp(0.0, 1.0))} of the selected '
              '${fmt.decimal(rangeDays)}-day range. Earlier dates have no heartbeats in this data, which says '
              'nothing about whether the rooms were reachable then.'),
        BulletText(retention == null
            ? 'The server\'s heartbeat retention is not known for this data source (the default is 30 days).'
            : 'The server keeps heartbeats for $retention days and deletes older ones.'),
        const BulletText('An hour counts as online when the room sent at least one heartbeat or event. '
            'A heartbeat gap is a run of hours with neither; gaps are measured in whole hours, so the real '
            'gap can be up to two hours longer. A gap shows only that nothing was received; the data does '
            'not say why.'),
        const BulletText('Each room is measured from its first heartbeat or event in this period, so a room '
            'that started reporting later has no gap before then. A room that sent no heartbeats at all '
            'shows "No heartbeats" instead of a percentage.'),
      ],
    );
  }

  // -------------------------------------------------------------- flapping

  Widget _flappingCallout(BuildContext context, ConnectivityReport c) {
    final fmt = Fmt.of(context);
    final flapping = <(String, TargetConnectivity)>[
      for (final r in c.rooms)
        for (final t in r.targets)
          if (t.flapBursts > 0) (r.room, t),
    ]..sort((a, b) => b.$2.flapBursts.compareTo(a.$2.flapBursts));
    final shown = flapping.take(8).toList();
    return InfoCallout(
      tone: CalloutTone.warning,
      icon: Icons.sync_problem_outlined,
      title: flapping.length == 1
          ? '1 device changed connection state repeatedly'
          : '${fmt.count(flapping.length)} devices changed connection state repeatedly',
      message: 'The room\'s program logged these devices as Connected and Disconnected several times in a '
          'short time. The device\'s own logs, its network and its cabling are places to compare.',
      actions: [
        OutlinedButton.icon(
          onPressed: () => context.read<NavigationState>().goTo(AppDestination.issues),
          icon: const Icon(Icons.report_problem_outlined),
          label: const Text('Review in Issues'),
        ),
      ],
      children: [
        for (final (room, t) in shown)
          BulletText('${t.target} in $room: ${fmt.count(t.flapBursts)} '
              '${t.flapBursts == 1 ? 'burst' : 'bursts'} of rapid changes, '
              '${fmt.count(t.connects + t.disconnects)} changes in total. '
              'Last state: ${t.lastState ? 'connected' : 'disconnected'}.'),
        if (flapping.length > shown.length)
          BulletText('And ${fmt.count(flapping.length - shown.length)} more; see the table below.'),
      ],
    );
  }

  // ------------------------------------------------------- no conn. events

  Widget _noConnectionEvents(BuildContext context) => const InfoCallout(
        icon: Icons.cable_outlined,
        title: 'No connection events in this range',
        message: 'Connected and Disconnected events are logged when a room\'s program sees communication '
            'with a device it controls go down or come back. None were recorded for the selected rooms '
            'and dates.',
        children: [
          BulletText('This is expected when every device stayed connected, or when a program does not log '
              'communication changes.'),
          BulletText('If you expected events, check that the room\'s control program reports device '
              'connection changes to the metrics server. Every AV System Metrics client supports the '
              'Connected and Disconnected actions, but a program has to call them.'),
          BulletText('Processor online time below is measured from heartbeats and does not need these events.'),
        ],
      );

  // -------------------------------------------------------------- timeline

  Widget _timelineCard(BuildContext context, ConnectivityReport c, Fmt fmt) {
    final palette = ChartPalette.of(context);
    final days = c.daily;
    final connects = days.fold<int>(0, (a, d) => a + d.connects);
    final disconnects = days.fold<int>(0, (a, d) => a + d.disconnects);
    ConnectionDay? busiest;
    for (final d in days) {
      if (busiest == null || d.connects + d.disconnects > busiest.connects + busiest.disconnects) busiest = d;
    }
    final total = connects + disconnects;
    final summary = '${fmt.count(total)} connection events over ${fmt.count(days.length)} days: '
        '${fmt.count(connects)} connected and ${fmt.count(disconnects)} disconnected.'
        '${busiest != null && total > 0 ? ' The busiest day was ${Fmt.calendarDate(busiest.date)} with '
            '${fmt.count(busiest.connects + busiest.disconnects)} events.' : ''}';
    return AccessibleChartCard(
      title: 'Connections and disconnections per day',
      description: 'Connected and Disconnected events from all selected rooms, stacked per day '
          '(dates in ${Fmt.of(context).utc ? 'UTC' : 'local time'}).',
      summary: summary,
      chartHeight: 260,
      chart: StackedBarChart(
        categories: [for (final d in days) Fmt.calendarDateShort(d.date)],
        series: [
          BarSeries('Connected', [for (final d in days) d.connects.toDouble()]),
          BarSeries('Disconnected', [for (final d in days) d.disconnects.toDouble()]),
        ],
      ),
      legend: PatternLegend(items: [
        LegendItem.fromPalette(palette, 0, 'Connected', value: fmt.count(connects)),
        LegendItem.fromPalette(palette, 1, 'Disconnected', value: fmt.count(disconnects)),
      ]),
      table: ChartTable(
        columns: const [
          ChartColumn('Date'),
          ChartColumn('Connected', numeric: true),
          ChartColumn('Disconnected', numeric: true),
          ChartColumn('Total', numeric: true),
        ],
        rows: [
          for (final d in days)
            [
              Fmt.calendarDate(d.date),
              fmt.count(d.connects),
              fmt.count(d.disconnects),
              fmt.count(d.connects + d.disconnects),
            ],
        ],
        rawRows: [
          for (final d in days) [Fmt.calendarDateIso(d.date), d.connects, d.disconnects, d.connects + d.disconnects],
        ],
      ),
    );
  }

  // ---------------------------------------------------------- events table

  Widget _eventsCard(BuildContext context, ConnectivityReport c, Fmt fmt) {
    final byDevice = <(RoomConnectivity, TargetConnectivity)>[
      for (final r in c.rooms)
        for (final t in r.targets) (r, t),
    ];
    final log = c.events.reversed.toList(growable: false);

    final ChartTable csv;
    final Widget table;
    if (_eventView == _EventView.byDevice) {
      const columns = [
        ChartColumn('Room'),
        ChartColumn('Device'),
        ChartColumn('Connected', numeric: true),
        ChartColumn('Disconnected', numeric: true),
        ChartColumn('Unstable bursts', numeric: true),
        ChartColumn('Last state'),
        ChartColumn('Last change'),
      ];
      table = SortableTable(
        key: const ValueKey('conn-by-device'),
        label: 'Connection events by device',
        columns: columns,
        initialSortColumn: 4,
        initialAscending: false,
        rows: [
          for (final (r, t) in byDevice)
            [
              r.room,
              t.target,
              fmt.count(t.connects),
              fmt.count(t.disconnects),
              fmt.count(t.flapBursts),
              t.lastState ? 'Connected' : 'Disconnected',
              fmt.dateTime(t.lastChange),
            ],
        ],
        sortKeys: [
          for (final (r, t) in byDevice)
            [r.room, t.target, t.connects, t.disconnects, t.flapBursts, t.lastState ? 'Connected' : 'Disconnected', t.lastChange],
        ],
      );
      csv = ChartTable(columns: columns, rows: const [], rawRows: [
        for (final (r, t) in byDevice)
          [r.room, t.target, t.connects, t.disconnects, t.flapBursts, t.lastState ? 'Connected' : 'Disconnected', instantIso(t.lastChange)],
      ]);
    } else {
      const columns = [ChartColumn('Time'), ChartColumn('Room'), ChartColumn('Device'), ChartColumn('Event')];
      table = SortableTable(
        key: const ValueKey('conn-log'),
        label: 'Connection event log',
        columns: columns,
        initialSortColumn: 0,
        initialAscending: false,
        rows: [
          for (final e in log) [fmt.dateTime(e.time), e.room, e.target, e.connected ? 'Connected' : 'Disconnected'],
        ],
        sortKeys: [
          for (final e in log) [e.time, e.room, e.target, e.connected ? 'Connected' : 'Disconnected'],
        ],
      );
      csv = ChartTable(columns: columns, rows: const [], rawRows: [
        for (final e in log) [instantIso(e.time), e.room, e.target, e.connected ? 'Connected' : 'Disconnected'],
      ]);
    }

    return TitledCard(
      title: 'Connection events by room and device',
      subtitle: 'Sort any column. "Unstable bursts" counts runs of rapid connect/disconnect changes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<_EventView>(
                segments: [
                  for (final v in _EventView.values) ButtonSegment(value: v, label: Text(v.label)),
                ],
                selected: {_eventView},
                onSelectionChanged: (s) => setState(() => _eventView = s.first),
              ),
              TextButton.icon(
                onPressed: () => copyWithConfirmation(
                  context,
                  csv.toCsv(),
                  'Connection events copied to the clipboard as CSV.',
                ),
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copy as CSV'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          table,
        ],
      ),
    );
  }

  // ---------------------------------------------------------- online rooms

  Widget _onlineCard(BuildContext context, ConnectivityReport c, Fmt fmt) {
    final withData = c.rooms.where((r) => r.onlineFraction != null).toList();
    final without = c.rooms.where((r) => r.onlineFraction == null).toList();
    final sorted = [...withData];
    switch (_onlineSort) {
      case _OnlineSort.lowest:
        sorted.sort((a, b) {
          final x = a.onlineFraction!.compareTo(b.onlineFraction!);
          return x != 0 ? x : a.room.compareTo(b.room);
        });
      case _OnlineSort.highest:
        sorted.sort((a, b) {
          final x = b.onlineFraction!.compareTo(a.onlineFraction!);
          return x != 0 ? x : a.room.compareTo(b.room);
        });
      case _OnlineSort.room:
        sorted.sort((a, b) => a.room.toLowerCase().compareTo(b.room.toLowerCase()));
    }
    var online = 0, covered = 0;
    for (final r in withData) {
      online += r.onlineHours;
      covered += r.coveredHours;
    }
    final lowest = withData.isEmpty
        ? null
        : withData.reduce((a, b) => a.onlineFraction! <= b.onlineFraction! ? a : b);
    final below = withData.where((r) => r.onlineFraction! < 0.99).length;
    final summary = withData.isEmpty
        ? 'No room has heartbeat data inside the covered period.'
        : 'Processors were online ${fmt.percent(covered == 0 ? 0 : online / covered)} of covered hours across '
            '${fmt.count(withData.length)} rooms. ${below == 0 ? 'Every room was online at least 99% of the time.' : '${fmt.count(below)} ${below == 1 ? 'room was' : 'rooms were'} online less than 99% of the time.'}'
            '${lowest != null && lowest.onlineFraction! < 0.99 ? ' Lowest: ${lowest.room} at ${fmt.percent(lowest.onlineFraction!)}.' : ''}';

    final noHeartbeats = without.isEmpty
        ? ''
        : ' ${fmt.count(without.length)} ${without.length == 1 ? 'room sent' : 'rooms sent'} no heartbeats, '
            'so ${without.length == 1 ? 'its' : 'their'} online time is unknown: ${without.map((r) => r.room).join(', ')}.';

    final items = [
      for (final r in sorted)
        BarListItem(
          label: r.room,
          fraction: r.onlineFraction!,
          valueText: fmt.percent(r.onlineFraction!),
          marker: r.offlinePeriods.isNotEmpty ? Icons.warning_amber_rounded : null,
        ),
      // No bar (not 0%): the online time of these rooms is unknown.
      for (final r in without)
        BarListItem(label: r.room, fraction: 0, valueText: noHeartbeatsText),
    ];
    final tableRows = [...sorted, ...without];
    return AccessibleChartCard(
      title: 'Processor online time per room',
      description: 'Share of covered hours in which each room processor sent a heartbeat or event, measured '
          'from the room\'s first heartbeat or event in the covered period. A warning sign marks rooms with '
          'at least one heartbeat gap. Rooms that sent no heartbeats are listed last as "No heartbeats".',
      summary: '$summary$noHeartbeats',
      chartHeight: LabeledBarList.heightFor(context, items.length),
      actions: [
        SegmentedButton<_OnlineSort>(
          showSelectedIcon: false,
          segments: [
            for (final s in _OnlineSort.values) ButtonSegment(value: s, label: Text(s.label)),
          ],
          selected: {_onlineSort},
          onSelectionChanged: (s) => setState(() => _onlineSort = s.first),
        ),
      ],
      chart: LabeledBarList(items: items),
      footer: Text(
        [
          'Covered period: ${fmt.dateTime(c.coverageStart!)} to ${fmt.dateTime(c.coverageEnd!)}.',
          if (c.retentionDays != null) 'Heartbeats are kept for ${c.retentionDays} days on the server.',
          if (without.isNotEmpty)
            '${fmt.count(without.length)} ${without.length == 1 ? 'room has' : 'rooms have'} no heartbeats in the '
                'covered period and ${without.length == 1 ? 'is' : 'are'} shown as "No heartbeats".',
          if (tableRows.any(lastSeenIsHourly))
            'A last-seen time "during the hour starting" comes from a heartbeat, which is only recorded per hour.',
        ].join(' '),
      ),
      table: ChartTable(
        columns: const [
          ChartColumn('Room'),
          ChartColumn('Building'),
          ChartColumn('Online', numeric: true),
          ChartColumn('Online hours', numeric: true),
          ChartColumn('Covered hours', numeric: true),
          ChartColumn('Heartbeat gaps', numeric: true),
          ChartColumn('Last seen'),
          ChartColumn('Last seen precision'),
        ],
        rows: [
          for (final r in tableRows)
            [
              r.room,
              r.building,
              r.onlineFraction == null ? noHeartbeatsText : fmt.percent(r.onlineFraction!),
              fmt.count(r.onlineHours),
              fmt.count(r.coveredHours),
              fmt.count(r.offlinePeriods.length),
              lastSeenText(r, fmt),
              lastSeenPrecision(r),
            ],
        ],
        rawRows: [
          for (final r in tableRows)
            [
              r.room,
              r.building,
              // A fraction 0-1, or the words (never an empty cell that a
              // spreadsheet would read as 0%).
              r.onlineFraction ?? noHeartbeatsText,
              r.onlineHours,
              r.coveredHours,
              r.offlinePeriods.length,
              r.lastSeen == null ? '' : instantIso(r.lastSeen!),
              lastSeenPrecision(r),
            ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------- heartbeat gaps

  Widget _offlineCard(BuildContext context, ConnectivityReport c, Fmt fmt) {
    final gap = context.select<SettingsState, Duration>((s) => s.analysisConfig.thresholds.offlineGap);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final periods = [for (final r in c.rooms) ...r.offlinePeriods]
      ..sort((a, b) {
        final x = b.start.compareTo(a.start);
        return x != 0 ? x : a.room.compareTo(b.room);
      });
    final csv = ChartTable(
      columns: const [
        ChartColumn('Room'),
        ChartColumn('Start (UTC)'),
        ChartColumn('End (UTC)'),
        ChartColumn('Hours', numeric: true),
        ChartColumn('Continuing at end of data'),
      ],
      rows: const [],
      rawRows: [
        for (final p in periods)
          [p.room, instantIso(p.start), instantIso(p.end), p.hours, p.ongoing ? 'yes' : 'no'],
      ],
    );
    final shown = periods.take(_offlineVisible).toList();
    return TitledCard(
      title: 'Heartbeat gaps',
      subtitle: 'Stretches longer than ${fmt.duration(gap)} with no heartbeat or event from a room, newest '
          'first. Each one shows only that nothing was received.',
      trailing: periods.isEmpty
          ? null
          : TextButton.icon(
              onPressed: () => copyWithConfirmation(context, csv.toCsv(), 'Heartbeat gaps copied to the clipboard as CSV.'),
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('Copy as CSV'),
            ),
      child: periods.isEmpty
          ? Text('No room went more than ${fmt.duration(gap)} without a heartbeat or event in the covered period.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final p in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(color: cs.outlineVariant),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(minWidth: 200),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ExcludeSemantics(child: Icon(Icons.cloud_off_outlined, size: 20, color: cs.onSurface)),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          '${p.room}: no heartbeats for ${fmt.duration(p.duration)}${p.ongoing ? ' (continuing at the end of the data)' : ''}',
                                          style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text('${fmt.dateTime(p.start)} to ${fmt.dateTime(p.end)}',
                                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: () => _openRoom(p.room),
                              child: Text('Open ${p.room}'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (shown.length < periods.length)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton(
                      onPressed: () => setState(() => _offlineVisible += _offlinePage),
                      child: Text('Show more heartbeat gaps (${periods.length - shown.length} remaining)'),
                    ),
                  ),
              ],
            ),
    );
  }
}
