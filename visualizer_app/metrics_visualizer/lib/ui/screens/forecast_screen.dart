import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/app_state.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';
import 'parts/b_charts.dart';
import 'parts/b_common.dart';
import 'parts/b_forecast_logic.dart';
import 'parts/b_table.dart';
import 'parts/device_type_note.dart';

/// Device replacement planning and input usage trends, with the
/// assumptions behind them in plain language.
class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  String? _deviceKey;
  int _years = 3;

  @override
  Widget build(BuildContext context) {
    return AnalysisPage(
      title: 'Forecast',
      subtitle: 'Usage trends and replacement planning from observed hours. A rough guide, not a prediction.',
      builder: (context, analysis) => _content(context, analysis),
    );
  }

  List<Widget> _content(BuildContext context, AnalysisResult a) {
    final f = a.forecast;
    final fmt = Fmt.of(context);
    return [
      _kpis(context, f, fmt),
      if (!f.hasEnoughData) _notEnoughData(context, f),
      if (f.devices.isEmpty)
        const InfoCallout(
          icon: Icons.videocam_off_outlined,
          title: 'No device power events in this data',
          message: 'Device forecasts need device power events with Started and Stopped (for example '
              '"Projector 1"; see Settings > Event recognition). None were found for the selected rooms and dates.',
        )
      else ...[
        const DeviceTypeNote(),
        _deviceTable(context, f, fmt),
        _devicePicker(context, f),
        _deviceChart(context, f, fmt),
      ],
      if (f.inputs.isEmpty)
        const InfoCallout(
          icon: Icons.input_outlined,
          title: 'No source selections in this data',
          message: 'Source trends need source selection events (for example "Source - HDMI 1" Started; see '
              'Settings > Event recognition). '
              'None were found for the selected rooms and dates.',
        )
      else ...[
        _inputChart(context, f, fmt),
        _inputStatements(context, f),
      ],
      _methodology(context, f),
    ];
  }

  // ------------------------------------------------------------------ KPIs

  Widget _kpis(BuildContext context, ForecastReport f, Fmt fmt) {
    final withFit = f.devices.where((d) => d.fit != null).length;
    final horizon = f.origin.add(Duration(microseconds: (3 * TrendRules.weeksPerYear * 7 * 24 * 3600 * 1e6).round()));
    final soon = f.devices
        .where((d) => d.ratedLifeReached ||
            (d.projectedRatedLifeDate != null && d.projectedRatedLifeDate!.isBefore(horizon)))
        .length;
    final reached = f.devices.where((d) => d.ratedLifeReached).length;
    DeviceForecast? soonest;
    for (final d in f.devices) {
      if (d.projectedRatedLifeDate == null) continue;
      if (soonest == null || d.projectedRatedLifeDate!.isBefore(soonest.projectedRatedLifeDate!)) soonest = d;
    }
    final growing = f.inputs.where((t) => t.direction == TrendDirection.growing).length;
    final declining = f.inputs.where((t) => t.direction == TrendDirection.declining).length;
    return ResponsiveGrid(
      minChildWidth: 220,
      children: [
        KpiTile(
          label: 'Devices tracked',
          value: fmt.count(f.devices.length),
          icon: Icons.videocam_outlined,
          caption: '${fmt.count(withFit)} with enough data for a trend',
        ),
        KpiTile(
          label: 'At rated life within 3 years',
          value: fmt.count(soon),
          icon: Icons.event_outlined,
          caption: reached > 0
              ? 'including ${fmt.count(reached)} already past it'
              : 'following current trends',
        ),
        KpiTile(
          label: 'Soonest projected date',
          value: soonest == null ? 'None' : fmt.date(soonest.projectedRatedLifeDate!),
          icon: Icons.schedule_outlined,
          caption: soonest == null
              ? 'No device has a projection yet'
              : '${soonest.deviceId} in ${soonest.room}',
        ),
        KpiTile(
          label: 'Source trends',
          value: '${fmt.count(growing)} up · ${fmt.count(declining)} down',
          icon: Icons.trending_up,
          caption: '${fmt.count(f.inputs.length - growing - declining)} stable or not enough data',
        ),
      ],
    );
  }

  Widget _notEnoughData(BuildContext context, ForecastReport f) {
    final app = context.watch<AppState>();
    final narrowed = app.filters.preset != DatePreset.all;
    return InfoCallout(
      tone: CalloutTone.warning,
      icon: Icons.hourglass_empty,
      title: 'Not enough data for trends yet',
      message: 'The selected range has ${f.fullWeeksAvailable} complete '
          '${f.fullWeeksAvailable == 1 ? 'week' : 'weeks'}. Trends and projections need at least '
          '${TrendRules.minFullWeeks} complete weeks (Monday to Sunday), and a full term gives much more '
          'reliable results. Observed hours are still shown below.',
      actions: [
        if (narrowed)
          OutlinedButton.icon(
            onPressed: () => context.read<AppState>().setDatePreset(DatePreset.all),
            icon: const Icon(Icons.date_range_outlined),
            label: const Text('Analyse all loaded data'),
          ),
        OutlinedButton.icon(
          onPressed: () => context.read<NavigationState>().goTo(AppDestination.dataSource),
          icon: const Icon(Icons.storage_outlined),
          label: const Text('Load a longer export'),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ device table

  static String _projectedText(DeviceForecast d, Fmt fmt) {
    if (d.ratedLifeReached) return 'Already reached';
    if (d.ratedLifeHours == null) return 'No rated life set';
    if (d.fit == null) return 'Not enough data';
    final date = d.projectedRatedLifeDate;
    if (date == null) return 'Beyond ${TrendRules.maxProjectionYears} years';
    return fmt.date(date);
  }

  static String _rangeText(DeviceForecast d, Fmt fmt) {
    final e = d.projectedRatedLifeDateEarliest, l = d.projectedRatedLifeDateLatest;
    if (e == null && l == null) return 'Not available';
    return '${e == null ? 'unknown' : fmt.date(e)} to '
        '${l == null ? 'beyond ${TrendRules.maxProjectionYears} years' : fmt.date(l)}';
  }

  Widget _deviceTable(BuildContext context, ForecastReport f, Fmt fmt) {
    const columns = [
      ChartColumn('Device'),
      ChartColumn('Room'),
      ChartColumn('Type'),
      ChartColumn('Observed hours', numeric: true),
      ChartColumn('Weekly run-rate', numeric: true, tooltip: 'Average hours per complete week'),
      ChartColumn('Trend'),
      ChartColumn('Rated life used', numeric: true, tooltip: 'Observed hours as a share of rated life'),
      ChartColumn('Projected to reach rated life'),
      ChartColumn('Likely range'),
      ChartColumn('Confidence'),
    ];
    final conf = {for (final d in f.devices) d.key: assessConfidence(d)};
    String isoDate(DateTime? instant) => instant == null ? '' : Fmt.calendarDateIso(fmt.display(instant));
    String rate(DeviceForecast d) =>
        d.fullWeeksUsed == 0 ? 'No complete weeks' : '${fmt.decimal(d.runRateHoursPerWeek)} h/week';
    String used(DeviceForecast d) => d.lifeUsedFraction == null ? 'No rated life set' : fmt.percent(d.lifeUsedFraction!);
    final csv = ChartTable(
      columns: const [
        ChartColumn('device'),
        ChartColumn('room'),
        ChartColumn('building'),
        ChartColumn('type'),
        ChartColumn('observed_hours', numeric: true),
        ChartColumn('complete_weeks', numeric: true),
        ChartColumn('weekly_run_rate_hours', numeric: true),
        ChartColumn('trend'),
        ChartColumn('rated_life_hours', numeric: true),
        ChartColumn('rated_life_reached'),
        ChartColumn('projected_rated_life_date'),
        ChartColumn('likely_earliest'),
        ChartColumn('likely_latest'),
        ChartColumn('flat_rate_date'),
        ChartColumn('projected_hours_1y', numeric: true),
        ChartColumn('projected_hours_3y', numeric: true),
        ChartColumn('projected_hours_5y', numeric: true),
        ChartColumn('confidence'),
      ],
      rows: const [],
      rawRows: [
        for (final d in f.devices)
          [
            d.deviceId,
            d.room,
            d.building,
            d.deviceType,
            d.observedHours,
            d.fullWeeksUsed,
            d.runRateHoursPerWeek,
            d.direction.label,
            d.ratedLifeHours,
            d.ratedLifeReached ? 'yes' : 'no',
            // Projected dates are instants: export the calendar date shown
            // in the table (display zone), not the raw UTC date.
            isoDate(d.projectedRatedLifeDate),
            isoDate(d.projectedRatedLifeDateEarliest),
            isoDate(d.projectedRatedLifeDateLatest),
            isoDate(d.projectedRatedLifeDateFlat),
            for (final y in TrendRules.horizonsYears)
              d.projections.where((p) => p.years == y).map((p) => p.expectedHours).firstOrNull,
            conf[d.key]!.level.label,
          ],
      ],
    );
    return TitledCard(
      title: 'Device replacement planning',
      subtitle: 'Soonest projected date first. Sort any column. Dates follow the current weekly trend; '
          'the likely range uses the trend slope plus or minus one standard error.',
      trailing: TextButton.icon(
        onPressed: () => copyWithConfirmation(context, csv.toCsv(), 'Device forecasts copied to the clipboard as CSV.'),
        icon: const Icon(Icons.copy_all_outlined),
        label: const Text('Copy as CSV'),
      ),
      child: SortableTable(
        label: 'Device replacement planning',
        columns: columns,
        rows: [
          for (final d in f.devices)
            [
              d.deviceId,
              d.room,
              d.deviceType,
              fmt.decimal(d.observedHours),
              rate(d),
              d.direction.label,
              used(d),
              _projectedText(d, fmt),
              _rangeText(d, fmt),
              conf[d.key]!.level.label,
            ],
        ],
        sortKeys: [
          for (final d in f.devices)
            [
              d.deviceId,
              d.room,
              d.deviceType,
              d.observedHours,
              d.fullWeeksUsed == 0 ? null : d.runRateHoursPerWeek,
              d.direction.index,
              d.lifeUsedFraction,
              d.ratedLifeReached
                  ? f.origin.microsecondsSinceEpoch
                  : d.projectedRatedLifeDate?.microsecondsSinceEpoch,
              d.projectedRatedLifeDateEarliest?.microsecondsSinceEpoch,
              conf[d.key]!.level.index,
            ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ device chart

  DeviceForecast _selectedDevice(ForecastReport f) {
    final byKey = {for (final d in f.devices) d.key: d};
    return byKey[_deviceKey] ?? f.devices.firstWhere((d) => d.fit != null, orElse: () => f.devices.first);
  }

  Widget _devicePicker(BuildContext context, ForecastReport f) {
    final selected = _selectedDevice(f);
    final sorted = [...f.devices]..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DropdownButtonFormField<String>(
          key: ValueKey('device-${selected.key}'),
          initialValue: selected.key,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Device to chart',
            helperText: 'Shows its observed hours and projection below',
          ),
          items: [
            for (final d in sorted)
              DropdownMenuItem(value: d.key, child: Text('${d.deviceId} in ${d.room}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _deviceKey = v);
            final d = f.devices.firstWhere((x) => x.key == v);
            announce(context, 'Chart shows ${d.deviceId} in ${d.room}.');
          },
        ),
      ),
    );
  }

  Widget _deviceChart(BuildContext context, ForecastReport f, Fmt fmt) {
    final palette = ChartPalette.of(context);
    final d = _selectedDevice(f);
    final horizonWeeks = weeksForYears(_years);
    // Weekly points are calendar dates in the analysis zone, which follows
    // the time display setting.
    final curve = projectionCurve(d, f.origin,
        horizonWeeks: horizonWeeks, zone: TimeBucketer(useLocalTime: !fmt.utc));
    final rated = d.ratedLifeHours;
    final yearProjection = d.projections.where((p) => p.years == _years).firstOrNull;

    DateTime at(double weeks) => f.origin.add(Duration(microseconds: (weeks * 7 * 24 * 3600 * 1e6).round()));
    final monthFmt = DateFormat.yMMM();
    String formatX(double x) => monthFmt.format(fmt.display(at(x)));
    String formatY(double y) => '${fmt.compact(y)} h';

    final buffer = StringBuffer('${d.deviceId} in ${d.room}: ${fmt.hours(d.observedHours)} observed');
    if (d.fit == null) {
      buffer.write(' over ${d.fullWeeksUsed} complete weeks. There is not enough data for a projection yet '
          '(at least ${TrendRules.minFullWeeks} complete weeks are needed).');
    } else {
      buffer.write(', ${fmt.decimal(d.runRateHoursPerWeek)} hours per week on average, trend '
          '${d.direction.label.toLowerCase()}.');
      if (yearProjection != null) {
        buffer.write(' Following the trend it reaches about ${fmt.hours(yearProjection.expectedHours)} in '
            '$_years ${_years == 1 ? 'year' : 'years'} (likely ${fmt.hours(yearProjection.lowHours)} to '
            '${fmt.hours(yearProjection.highHours)}).');
      }
      if (d.ratedLifeReached) {
        buffer.write(' It has already passed its rated life of ${fmt.hours(rated!)}.');
      } else if (rated != null && d.projectedRatedLifeDate != null) {
        buffer.write(' It would reach its rated life of ${fmt.hours(rated)} around '
            '${fmt.date(d.projectedRatedLifeDate!)}.');
      } else if (rated != null) {
        buffer.write(' It would not reach its rated life of ${fmt.hours(rated)} within '
            '${TrendRules.maxProjectionYears} years at this trend.');
      }
    }

    final series = <LineSeriesSpec>[
      LineSeriesSpec(label: 'Observed', points: curve.observed, color: palette.colorAt(0), showDots: true),
      if (curve.hasProjection) ...[
        LineSeriesSpec(
            label: 'Likely low', points: curve.low, color: palette.colorAt(1), style: LineStyleKind.dotted, width: 1.5),
        LineSeriesSpec(
            label: 'Likely high', points: curve.high, color: palette.colorAt(1), style: LineStyleKind.dotted, width: 1.5),
        LineSeriesSpec(
            label: 'Projected', points: curve.expected, color: palette.colorAt(1), style: LineStyleKind.dashed),
        LineSeriesSpec(
            label: 'Flat rate', points: curve.flat, color: palette.colorAt(2), style: LineStyleKind.dashDot, width: 2),
      ],
    ];
    // Only show the rated-life rule when it is in a useful range of the
    // chart (otherwise the projection would be squashed flat).
    final maxPlotted = [for (final s in series) for (final p in s.points) p.dy].fold<double>(0, math.max);
    final showRated = rated != null && rated <= maxPlotted * 4;

    // Table: observed weekly totals, then quarterly projection points.
    final rows = <List<String>>[];
    final raw = <List<Object?>>[];
    for (final p in curve.observed.skip(1)) {
      final date = at(p.dx);
      rows.add([fmt.date(date), 'Observed', fmt.decimal(p.dy), '', '', '']);
      raw.add([Fmt.calendarDateIso(fmt.display(date)), 'observed', p.dy, null, null, null]);
    }
    if (curve.hasProjection) {
      for (var k = 13; k <= horizonWeeks + 12; k += 13) {
        final w = math.min(k, horizonWeeks);
        final date = at(w.toDouble());
        rows.add([
          fmt.date(date),
          'Projected',
          fmt.decimal(curve.expected[w].dy),
          fmt.decimal(curve.low[w].dy),
          fmt.decimal(curve.high[w].dy),
          fmt.decimal(curve.flat[w].dy),
        ]);
        raw.add([
          Fmt.calendarDateIso(fmt.display(date)),
          'projected',
          curve.expected[w].dy,
          curve.low[w].dy,
          curve.high[w].dy,
          curve.flat[w].dy,
        ]);
        if (w == horizonWeeks) break;
      }
    }

    return AccessibleChartCard(
      title: 'Cumulative hours: ${d.deviceId} in ${d.room}',
      description: 'Observed on-hours added up week by week, then projected forward. The shaded band is the '
          'likely range. The dashed vertical line marks the end of the data.',
      summary: buffer.toString(),
      chartHeight: 300,
      actions: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: [
            for (final y in TrendRules.horizonsYears)
              ButtonSegment(value: y, label: Text('$y ${y == 1 ? 'year' : 'years'}'), tooltip: 'Project $y ${y == 1 ? 'year' : 'years'} ahead'),
          ],
          selected: {_years},
          onSelectionChanged: (s) => setState(() => _years = s.first),
        ),
      ],
      chart: TrendLineChart(
        series: series,
        bands: [
          if (curve.hasProjection) LineBand(1, 2, palette.colorAt(1).withValues(alpha: 0.18)),
        ],
        verticalMarkerX: 0,
        horizontalMarkerY: showRated ? rated : null,
        formatX: formatX,
        formatY: formatY,
      ),
      legend: LineLegend(entries: [
        ('Observed', palette.colorAt(0), LineStyleKind.solid),
        if (curve.hasProjection) ...[
          ('Projected, current trend', palette.colorAt(1), LineStyleKind.dashed),
          ('Likely range, shaded between', palette.colorAt(1), LineStyleKind.dotted),
          ('Flat rate', palette.colorAt(2), LineStyleKind.dashDot),
        ],
        if (showRated) ('Rated life ${fmt.hours(rated)}', palette.bad, LineStyleKind.dashed),
      ]),
      footer: Text(d.explanation),
      table: ChartTable(
        columns: const [
          ChartColumn('Week ending'),
          ChartColumn('Kind'),
          ChartColumn('Hours (observed or projected)', numeric: true),
          ChartColumn('Likely low', numeric: true),
          ChartColumn('Likely high', numeric: true),
          ChartColumn('Flat rate', numeric: true),
        ],
        rows: rows,
        rawRows: raw,
        caption: 'Cumulative on-hours. Projected rows are every 13 weeks (quarterly) up to the chosen horizon.',
      ),
    );
  }

  // ------------------------------------------------------------ input trends

  Widget _inputChart(BuildContext context, ForecastReport f, Fmt fmt) {
    final palette = ChartPalette.of(context);
    final top = f.inputs.take(LineStyleKind.values.length).toList();
    DateTime? first;
    for (final t in top) {
      for (final p in t.weekly) {
        if (!p.isComplete) continue;
        if (first == null || p.date.isBefore(first)) first = p.date;
      }
    }
    final base = first ?? f.origin;
    double weeksFromBase(DateTime d) => d.difference(base).inHours / (24 * 7);
    final series = <LineSeriesSpec>[
      for (var i = 0; i < top.length; i++)
        LineSeriesSpec(
          label: top[i].label,
          points: [
            for (final p in top[i].weekly)
              if (p.isComplete) Offset(weeksFromBase(p.date), p.value),
          ],
          color: palette.colorAt(i),
          style: LineStyleKind.values[i],
          showDots: true,
          width: 2.5,
        ),
    ];
    final weeks = <DateTime>{
      for (final t in top)
        for (final p in t.weekly)
          if (p.isComplete) p.date,
    }.toList()
      ..sort();
    final summaryParts = [
      for (final t in top)
        switch (t.direction) {
          TrendDirection.growing =>
            '${t.label} is growing (about ${fmt.decimal(t.percentChangePerWeek ?? 0)}% per week)',
          TrendDirection.declining =>
            '${t.label} is declining (about ${fmt.decimal((t.percentChangePerWeek ?? 0).abs())}% per week)',
          TrendDirection.stable => '${t.label} is stable',
          TrendDirection.insufficientData => '${t.label} does not have enough data for a trend',
        },
    ];
    final summary = weeks.isEmpty
        ? 'There are no complete weeks of source selections to chart yet.'
        : 'Weekly selections of the ${top.length} most used sources over ${weeks.length} complete weeks. '
            '${summaryParts.join('; ')}.';
    return AccessibleChartCard(
      title: 'Source selections per week',
      description: 'The most used sources, campus-wide (complete weeks only, as in the trend calculation).',
      summary: summary,
      chartHeight: 260,
      chart: weeks.isEmpty
          ? Center(child: Text('No complete weeks yet.', style: Theme.of(context).textTheme.bodyLarge))
          : TrendLineChart(
              series: series,
              formatX: (x) => Fmt.calendarDateShort(base.add(Duration(hours: (x * 24 * 7).round()))),
              formatY: (y) => fmt.compact(y),
            ),
      legend: LineLegend(entries: [
        for (var i = 0; i < top.length; i++) (top[i].label, palette.colorAt(i), LineStyleKind.values[i]),
      ]),
      table: ChartTable(
        columns: [
          const ChartColumn('Week starting'),
          for (final t in top) ChartColumn(t.label, numeric: true),
        ],
        rows: [
          for (final w in weeks)
            [
              Fmt.calendarDate(w),
              for (final t in top) fmt.count(t.weekly.where((p) => p.date == w).firstOrNull?.value ?? 0),
            ],
        ],
        rawRows: [
          for (final w in weeks)
            [
              Fmt.calendarDateIso(w),
              for (final t in top) t.weekly.where((p) => p.date == w).firstOrNull?.value ?? 0,
            ],
        ],
      ),
    );
  }

  Widget _inputStatements(BuildContext context, ForecastReport f) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const order = [
      TrendDirection.growing,
      TrendDirection.declining,
      TrendDirection.stable,
      TrendDirection.insufficientData,
    ];
    IconData icon(TrendDirection d) => switch (d) {
          TrendDirection.growing => Icons.trending_up,
          TrendDirection.declining => Icons.trending_down,
          TrendDirection.stable => Icons.trending_flat,
          TrendDirection.insufficientData => Icons.help_outline,
        };
    return TitledCard(
      title: 'Source usage trends',
      subtitle: 'Every source, grouped by the direction of its weekly selections.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final dir in order)
            if (f.inputs.any((t) => t.direction == dir)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Heading(
                  '${dir.label} (${f.inputs.where((t) => t.direction == dir).length})',
                  level: HeadingLevel.detail,
                  child: Row(
                    children: [
                      ExcludeSemantics(child: Icon(icon(dir), color: cs.onSurface)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${dir.label} (${f.inputs.where((t) => t.direction == dir).length})',
                          style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              for (final t in f.inputs.where((t) => t.direction == dir))
                DefaultTextStyle.merge(
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                  child: BulletText(t.explanation),
                ),
            ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ methodology

  Widget _methodology(BuildContext context, ForecastReport f) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final rated = context.select<SettingsState, Map<String, double>>((s) => s.analysisConfig.ratedLifeHours);
    final entries = rated.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return TitledCard(
      title: 'How these forecasts work',
      subtitle: 'Assumptions and limits to keep in mind before using these figures in a budget.',
      child: DefaultTextStyle.merge(
        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final a in f.assumptions) BulletText(a),
            BulletText(ConfidenceRules.description),
            const SizedBox(height: 8),
            Text('Rated life currently used',
                style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            if (entries.isEmpty)
              const BulletText('No rated life values are set, so no replacement dates can be projected.')
            else
              for (final e in entries)
                BulletText('${e.key.isEmpty ? e.key : '${e.key[0]}${e.key.substring(1).toLowerCase()}'}: ${fmt.hours(e.value)}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.read<NavigationState>().goTo(AppDestination.settings),
                  icon: const Icon(Icons.tune),
                  label: const Text('Edit rated life in Settings'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'The full methodology is in the analytics README (lib/analytics/README.md, section 2.6) in the '
              'project repository.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
