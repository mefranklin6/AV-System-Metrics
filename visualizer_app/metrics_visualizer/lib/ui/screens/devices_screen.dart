import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';
import 'parts/a_cards.dart';
import 'parts/a_charts.dart';
import 'parts/a_common.dart';
import 'parts/device_type_note.dart';

/// Device on-hours from device power events: by type and device, weekly
/// trends, sessions left on and a per-device detail.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context) => AnalysisPage(
    title: 'Devices',
    subtitle: 'How long each device is on, from its power events.',
    builder: (context, analysis) {
      if (analysis.isEmpty) return noMatchingRooms(context);
      final leftOnHours = context.select<SettingsState, int>((s) => s.analysisConfig.thresholds.deviceLeftOnHours);
      final devices = analysis.devices;
      if (devices.devices.isEmpty) {
        return [
          const EmptyState(
            icon: Icons.videocam_off_outlined,
            title: 'No device activity in this period',
            message:
                'None of the selected rooms logged a device power event (Started or Stopped for a name '
                'such as "Projector 1"). Choose a wider date range or other rooms, or check the device '
                'pattern under Settings > Event recognition.',
          ),
        ];
      }
      return [
        _DeviceKpis(usage: devices, leftOnHours: leftOnHours),
        if (devices.devices.isNotEmpty) const DeviceTypeNote(),
        ResponsiveGrid(
          minChildWidth: 420,
          maxColumns: 2,
          children: [
            _TypeCard(types: devices.types),
            _TypeTrendCard(types: devices.types),
          ],
        ),
        DeviceHoursCard(
          devices: devices.devices,
          scopeLabel: 'all rooms',
          typeOrder: [for (final t in devices.types) t.type]..sort(),
        ),
        _LeftOnCard(analysis: analysis, leftOnHours: leftOnHours),
        _DeviceDetail(devices: devices.devices),
      ];
    },
  );
}

class _DeviceKpis extends StatelessWidget {
  const _DeviceKpis({required this.usage, required this.leftOnHours});

  final DeviceUsage usage;
  final int leftOnHours;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final n = usage.devices.length;
    final onAtEnd = usage.devices.where((d) => d.onAtEnd).length;
    return ResponsiveGrid(
      minChildWidth: 220,
      children: [
        KpiTile(
          label: 'Devices',
          value: fmt.count(n),
          icon: Icons.videocam_outlined,
          caption: '${usage.types.length} ${usage.types.length == 1 ? 'type' : 'types'}',
        ),
        KpiTile(
          label: 'Total on-hours',
          value: fmt.hours(usage.totalOnHours),
          icon: Icons.timer_outlined,
          caption: '${fmt.hours(n == 0 ? 0 : usage.totalOnHours / n)} per device on average',
        ),
        KpiTile(
          label: 'Long sessions',
          value: fmt.count(usage.leftOnSessions),
          icon: Icons.nightlight_outlined,
          caption: 'sessions longer than $leftOnHours h',
        ),
        KpiTile(
          label: 'On at end of data',
          value: fmt.count(onAtEnd),
          icon: Icons.power_outlined,
          caption: 'devices still on when the data ends',
        ),
      ],
    );
  }
}

class _TypeCard extends StatelessWidget {
  const _TypeCard({required this.types});

  final List<DeviceTypeStat> types;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    const title = 'On-hours by device type';
    final sorted = [...types]..sort((a, b) => b.onHours.compareTo(a.onHours));
    final total = sorted.fold<double>(0, (s, t) => s + t.onHours);
    final top = sorted.first;
    final summary =
        '${deviceTypeLabel(top.type)} devices ran ${fmt.hours(top.onHours)} '
        '(${fmt.percent(total <= 0 ? 0 : top.onHours / total)} of all device hours), '
        '${fmt.hours(top.averageHoursPerDevice)} per device across ${fmt.count(top.deviceCount)} devices.';
    // Colour slots follow the alphabetical type order used on every device chart.
    final alpha = [for (final t in types) t.type]..sort();
    int slot(String type) => math.min(alpha.indexOf(type), maxNamedSeries);
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final t in sorted)
            BarDatum(
              label: '${deviceTypeLabel(t.type)} (${fmt.count(t.deviceCount)})',
              value: t.onHours,
              valueLabel: '${fmt.hours(t.onHours)} · ${fmt.hours(t.averageHoursPerDevice)} each',
              color: palette.colorAt(slot(t.type)),
              pattern: palette.patternAt(slot(t.type)),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: 'Total observed on-hours per type; the value shows the hours and the average per device.',
          summary: summary,
          chartHeight: height,
          chart: RankedBarChart(stacked: stacked, items: items),
          table: ChartTable(
            columns: const [
              ChartColumn('Type'),
              ChartColumn('Devices', numeric: true),
              ChartColumn('Sessions', numeric: true),
              ChartColumn('On-hours', numeric: true),
              ChartColumn('Average per device', numeric: true),
              ChartColumn('Long sessions', numeric: true),
            ],
            rows: [
              for (final t in sorted)
                [
                  deviceTypeLabel(t.type),
                  fmt.count(t.deviceCount),
                  fmt.count(t.sessions),
                  fmt.hours(t.onHours),
                  fmt.hours(t.averageHoursPerDevice),
                  fmt.count(t.leftOnSessions),
                ],
            ],
            rawRows: [
              for (final t in sorted)
                [t.type, t.deviceCount, t.sessions, t.onHours, t.averageHoursPerDevice, t.leftOnSessions],
            ],
          ),
        );
      },
    );
  }
}

/// Weekly (or daily) on-hours per device type.
class _TypeTrendCard extends StatefulWidget {
  const _TypeTrendCard({required this.types});

  final List<DeviceTypeStat> types;

  @override
  State<_TypeTrendCard> createState() => _TypeTrendCardState();
}

class _TypeTrendCardState extends State<_TypeTrendCard> {
  bool _weekly = true;

  @override
  Widget build(BuildContext context) {
    final sorted = [...widget.types]..sort((a, b) => b.onHours.compareTo(a.onHours));
    final shown = sorted.take(4).toList();
    final alpha = [for (final t in widget.types) t.type]..sort();
    return SeriesTrendCard(
      title: 'On-hours trend by type',
      description:
          '${_weekly ? 'Weekly (Monday start)' : 'Daily'} on-hours of the '
          '${shown.length == sorted.length ? '' : '${shown.length} busiest '}device types.',
      weekly: _weekly,
      unit: 'hours',
      series: [
        for (final t in shown)
          NamedSeries(
            deviceTypeLabel(t.type),
            _weekly ? t.weekly : t.daily,
            slot: math.min(alpha.indexOf(t.type), maxNamedSeries),
          ),
      ],
      actions: [
        Semantics(
          label: 'Period',
          container: true,
          explicitChildNodes: true,
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Weekly')),
              ButtonSegment(value: false, label: Text('Daily')),
            ],
            selected: {_weekly},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _weekly = s.first),
          ),
        ),
      ],
    );
  }
}

class _LeftOnCard extends StatefulWidget {
  const _LeftOnCard({required this.analysis, required this.leftOnHours});

  final AnalysisResult analysis;
  final int leftOnHours;

  @override
  State<_LeftOnCard> createState() => _LeftOnCardState();
}

class _LeftOnCardState extends State<_LeftOnCard> {
  static const int _initial = 10;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final nav = context.read<NavigationState>();
    final limit = widget.leftOnHours.toDouble();
    final sessions = <DeviceSession>[
      for (final rs in widget.analysis.sessions.values)
        for (final d in rs.devices)
          if (d.hours > limit) d,
    ]..sort((a, b) => b.duration.compareTo(a.duration));
    final shown = _all ? sessions : sessions.take(_initial).toList();
    String ending(DeviceSession s) => switch (s.endKind) {
      SessionEnd.capped => ' No off event was logged, so the session was capped; the off event may have been lost.',
      SessionEnd.ongoing => ' It was still on when the data ends.',
      SessionEnd.reinitialized => ' It ended at a program start event.',
      _ => '',
    };
    return InfoCard(
      title: 'Long device sessions',
      icon: Icons.nightlight_outlined,
      description:
          'Device sessions longer than ${widget.leftOnHours} hours, longest first. '
          'On-hours count toward rated lamp and panel life.',
      child: sessions.isEmpty
          ? Text(
              'No device stayed on longer than ${widget.leftOnHours} hours in this period.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final s in shown)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule),
                    title: Text(
                      '${s.room} · ${s.deviceId}: on for ${fmt.duration(s.duration)}',
                      style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface),
                    ),
                    subtitle: Text(
                      'From ${fmt.dateTime(s.start)}.${ending(s)}',
                      style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => nav.goTo(AppDestination.rooms, room: s.room),
                  ),
                if (sessions.length > _initial)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(_all ? 'Show fewer' : 'Show all ${sessions.length} sessions'),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Pick one device and see its numbers and daily on-hours.
class _DeviceDetail extends StatefulWidget {
  const _DeviceDetail({required this.devices});

  final List<DeviceStat> devices;

  @override
  State<_DeviceDetail> createState() => _DeviceDetailState();
}

class _DeviceDetailState extends State<_DeviceDetail> {
  String? _key;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    final byKey = {for (final d in widget.devices) d.key: d};
    final busiest = widget.devices.reduce((a, b) => b.onHours > a.onHours ? b : a);
    final d = byKey[_key] ?? busiest;
    final days = d.daily;
    final peak = days.isEmpty ? null : days.reduce((a, b) => b.value > a.value ? b : a);
    final activeDays = days.where((p) => p.value > 0).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoCard(
          title: 'Device detail',
          icon: Icons.manage_search,
          description: 'Choose a device to see its usage. The busiest device is shown first.',
          child: LayoutBuilder(
            builder: (context, constraints) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppDropdownMenu<String>(
                    key: ValueKey('device-menu-${widget.devices.length}'),
                    width: math.min(420.0, constraints.maxWidth),
                    label: 'Device',
                    helperText: 'Type to search ${widget.devices.length} devices',
                    initialSelection: d.key,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    menuHeight: 360,
                    entries: [
                      for (final x in widget.devices)
                        DropdownMenuEntry(value: x.key, label: '${x.room} · ${x.deviceId}'),
                    ],
                    onSelected: (k) {
                      if (k != null) setState(() => _key = k);
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 32,
                    children: [
                      StatLine(label: 'Room', value: '${d.room} (building ${d.building})'),
                      StatLine(label: 'Type', value: deviceTypeLabel(d.deviceType)),
                      StatLine(label: 'On-hours', value: fmt.hours(d.onHours)),
                      StatLine(label: 'Sessions', value: fmt.count(d.sessions)),
                      StatLine(label: 'Average session', value: fmt.hours(d.averageSessionHours)),
                      StatLine(label: 'Longest session', value: fmt.hours(d.longestSessionHours)),
                      StatLine(label: 'Long sessions', value: '${fmt.count(d.leftOnSessions)} sessions'),
                      StatLine(label: 'Days used', value: '${fmt.count(activeDays)} of ${fmt.count(days.length)}'),
                      StatLine(label: 'On at end of data', value: d.onAtEnd ? 'Yes' : 'No'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => context.read<NavigationState>().goTo(AppDestination.rooms, room: d.room),
                    icon: const Icon(Icons.meeting_room_outlined),
                    label: Text('Open room ${d.room}'),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        if (peak == null || peak.value <= 0)
          EmptyChartCard(title: 'Daily on-hours: ${d.deviceId}', message: 'This device was not on in this period.')
        else
          AccessibleChartCard(
            title: 'Daily on-hours: ${d.room} · ${d.deviceId}',
            description: 'Hours on per calendar day. Hatched columns are partial days at the edges of the data.',
            summary:
                '${d.deviceId} in ${d.room} was on ${fmt.hours(d.onHours)} over ${days.length} days, '
                'used on $activeDays of them. Its longest day was ${Fmt.calendarDate(peak.date)} with '
                '${fmt.hours(peak.value)}.',
            chartHeight: 220,
            chart: ColumnChart(
              color: palette.colorAt(0),
              yFormat: (v) => '${fmt.compact(v)} h',
              showValues: false,
              data: [
                for (final p in days) ColumnDatum(label: Fmt.calendarDateShort(p.date), value: p.value, partial: !p.isComplete),
              ],
            ),
            table: ChartTable(
              columns: const [ChartColumn('Date'), ChartColumn('On-hours', numeric: true), ChartColumn('Complete day')],
              rows: [
                for (final p in days)
                  [Fmt.calendarDate(p.date), fmt.hours(p.value), p.isComplete ? 'Yes' : 'No (partial)'],
              ],
              rawRows: [
                for (final p in days) [Fmt.calendarDate(p.date), p.value, p.isComplete ? 'Yes' : 'No'],
              ],
            ),
          ),
      ],
    );
  }
}
