// Chart cards shared by several screens (campus-wide and per-room versions
// of the same charts). Each one is an AccessibleChartCard with a
// plain-language summary and a table holding the same numbers.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../analytics/analytics.dart';
import '../../widgets/widgets.dart';
import 'a_charts.dart';
import 'a_common.dart';

// ------------------------------------------------------------- input share

/// Donut of source share for one scope, with values on the legend.
class InputShareCard extends StatelessWidget {
  const InputShareCard({
    super.key,
    required this.shares,
    required this.measure,
    required this.scopeLabel,
    required this.styles,
    this.title = 'Source share',
    this.actions = const [],
  });

  final List<InputShare> shares;
  final InputMeasure measure;

  /// Words for the scope, e.g. "all rooms" or "room BSS_245".
  final String scopeLabel;
  final InputStyles styles;
  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final sorted = sortInputs(shares, measure);
    final total = sorted.fold<double>(0, (s, i) => s + measure.valueOf(i));
    if (sorted.isEmpty || total <= 0) {
      return EmptyChartCard(title: title, message: noInputMessage(shares, measure, scopeLabel));
    }
    String value(double v) => measure == InputMeasure.selections ? fmt.count(v) : fmt.hours(v);
    final slices = inputSlices(sorted, measure, styles);
    final top = sorted.first;
    final noun = measure == InputMeasure.selections ? 'selections' : 'time on screen';
    final summary =
        '${top.label} accounts for ${fmt.percent(top.share(measure, total))} of $noun in '
        '$scopeLabel (${value(measure.valueOf(top))} of ${value(total)}). '
        '${sorted.length} ${sorted.length == 1 ? 'source was' : 'sources were'} used'
        '${slices.length < sorted.length ? '; the smallest are grouped as Other' : ''}.';
    return AccessibleChartCard(
      title: title,
      description: '${measure.label}, $scopeLabel',
      summary: summary,
      actions: actions,
      chartHeight: 240,
      chart: DonutChart(
        slices: slices,
        centerValue: value(total),
        centerLabel: measure == InputMeasure.selections ? 'selections' : 'on screen',
      ),
      legend: PatternLegend(
        items: [
          for (final s in slices)
            LegendItem(
              label: s.label,
              color: s.color,
              pattern: s.pattern,
              value: '${fmt.percent(s.value / total)} · ${value(s.value)}',
            ),
        ],
      ),
      table: inputTable(context, sorted),
    );
  }
}

/// Why an input chart for [measure] has nothing to show. When nobody chose
/// an input but the startup default source was on screen, there are no
/// selections (the default is not counted as one) yet there is time on
/// screen; say so instead of "no input was selected".
String noInputMessage(List<InputShare> shares, InputMeasure measure, String scopeLabel) {
  final hours = shares.fold<double>(0, (s, i) => s + i.hours);
  if (measure == InputMeasure.selections && hours > 0) {
    return 'No source selections were logged in $scopeLabel during this period. Only the startup default source was on '
        'screen; it is not counted as a selection. Choose "Time on screen" to see it.';
  }
  return 'No source selections were logged in $scopeLabel during this period.';
}

extension on InputShare {
  double share(InputMeasure m, double total) => total <= 0 ? 0 : m.valueOf(this) / total;
}

/// Table with every measure of [shares] (same order as given).
ChartTable inputTable(BuildContext context, List<InputShare> shares) {
  final fmt = Fmt.of(context);
  return ChartTable(
    columns: const [
      ChartColumn('Source'),
      ChartColumn('Selections', numeric: true),
      ChartColumn('Share of selections', numeric: true),
      ChartColumn('Time on screen', numeric: true),
      ChartColumn('Share of time', numeric: true),
      ChartColumn('Rooms used', numeric: true),
    ],
    rows: [
      for (final s in shares)
        [
          s.label,
          fmt.count(s.selections),
          fmt.percent(s.selectionShare),
          fmt.hours(s.hours),
          fmt.percent(s.timeShare),
          fmt.count(s.roomCount),
        ],
    ],
    rawRows: [
      for (final s in shares) [s.label, s.selections, s.selectionShare, s.hours, s.timeShare, s.roomCount],
    ],
  );
}

/// Ranked bars of inputs by [measure], every bar labelled with its value.
class InputRankingCard extends StatelessWidget {
  const InputRankingCard({
    super.key,
    required this.shares,
    required this.measure,
    required this.scopeLabel,
    required this.styles,
  });

  final List<InputShare> shares;
  final InputMeasure measure;
  final String scopeLabel;
  final InputStyles styles;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final sorted = sortInputs(shares, measure);
    const title = 'Sources ranked';
    final total = sorted.fold<double>(0, (s, i) => s + measure.valueOf(i));
    if (sorted.isEmpty || total <= 0) {
      return EmptyChartCard(title: title, message: noInputMessage(shares, measure, scopeLabel));
    }
    String value(double v) => measure == InputMeasure.selections ? fmt.count(v) : fmt.hours(v);
    final last = sorted.last;
    final summary =
        '${sorted.length} sources in $scopeLabel, ranked by ${measure.label.toLowerCase()}. '
        'Most: ${sorted.first.label} with ${value(measure.valueOf(sorted.first))}. '
        'Least: ${last.label} with ${value(measure.valueOf(last))}'
        '${total > 0 ? ' (${fmt.percent(measure.valueOf(last) / total)})' : ''}.';
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final s in sorted)
            BarDatum(
              label: s.label,
              value: measure.valueOf(s),
              valueLabel: '${value(measure.valueOf(s))} (${fmt.percent(total <= 0 ? 0 : measure.valueOf(s) / total)})',
              color: styles.color(s.key),
              pattern: styles.pattern(s.key),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: '${measure.label}, $scopeLabel',
          summary: summary,
          chartHeight: height,
          chart: RankedBarChart(stacked: stacked, items: items),
          table: inputTable(context, sorted),
        );
      },
    );
  }
}

// ------------------------------------------------------------------ heat map

/// Weekday x hour heat map card. Every cell has its own semantic label and
/// the table lists all 168 values.
class HeatmapCard extends StatelessWidget {
  const HeatmapCard({
    super.key,
    required this.heatmap,
    required this.title,
    required this.description,
    required this.cellNoun,
    required this.timeZoneLabel,
  });

  final HourWeekdayHeatmap heatmap;
  final String title;
  final String description;

  /// Completes "62% …", e.g. "of rooms in use" or "of the time on".
  final String cellNoun;
  final String timeZoneLabel;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final max = heatmap.maxValue;
    if (max <= 0) {
      return EmptyChartCard(title: title, message: 'The system was never on during this period.');
    }
    var bestD = 1, bestH = 0;
    for (var d = 1; d <= 7; d++) {
      for (var h = 0; h < 24; h++) {
        if (heatmap.valueAt(d, h) > heatmap.valueAt(bestD, bestH)) {
          bestD = d;
          bestH = h;
        }
      }
    }
    var bestDay = 1;
    for (var d = 2; d <= 7; d++) {
      if (heatmap.weekdayMean(d) > heatmap.weekdayMean(bestDay)) bestDay = d;
    }
    final weekend = (heatmap.weekdayMean(6) + heatmap.weekdayMean(7)) / 2;
    final summary =
        'Busiest: ${Fmt.weekday(bestD)} at ${Fmt.hourOfDay(bestH)}, '
        '${fmt.percent(heatmap.valueAt(bestD, bestH))} $cellNoun. '
        '${Fmt.weekday(bestDay)} is the busiest day on average '
        '(${fmt.percent(heatmap.weekdayMean(bestDay))} across 24 hours); '
        'weekends average ${fmt.percent(weekend)}.';
    return AccessibleChartCard(
      title: title,
      description:
          '$description Times in $timeZoneLabel. Darker cells mean a higher share $cellNoun; '
          'numbers in cells are percentages.',
      summary: summary,
      chartHeight: HeatmapScale.heightFor(context),
      chart: HeatmapScale(max: max, format: fmt.percent),
      legend: HeatmapGrid(
        values: heatmap.values,
        scaleMax: max,
        cellLabel: (d, h, v) => '${Fmt.weekday(d)} ${Fmt.hourOfDay(h)}: ${fmt.percent(v)} $cellNoun',
      ),
      table: ChartTable(
        caption: 'Rows are weekdays, columns are hours of the day ($timeZoneLabel).',
        columns: [
          const ChartColumn('Weekday'),
          for (var h = 0; h < 24; h++) ChartColumn(Fmt.hourOfDay(h), numeric: true),
        ],
        rows: [
          for (var d = 1; d <= 7; d++)
            [Fmt.weekday(d), for (var h = 0; h < 24; h++) fmt.percent(heatmap.valueAt(d, h))],
        ],
        rawRows: [
          for (var d = 1; d <= 7; d++) [Fmt.weekday(d), for (var h = 0; h < 24; h++) heatmap.valueAt(d, h)],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- device hours

/// Ranked bars of device on-hours with a full table.
class DeviceHoursCard extends StatelessWidget {
  const DeviceHoursCard({
    super.key,
    required this.devices,
    required this.scopeLabel,
    this.title = 'On-hours by device',
    this.limit = 15,
    this.showRoom = true,
    this.typeOrder,
  });

  final List<DeviceStat> devices;
  final String scopeLabel;
  final String title;

  /// Bars shown; the table always lists every device.
  final int limit;
  final bool showRoom;

  /// Device types in palette order (alphabetical campus-wide list), so a
  /// type keeps its colour on every chart. Defaults to the types present.
  final List<String>? typeOrder;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    if (devices.isEmpty) {
      return EmptyChartCard(title: title, message: 'No device power events were logged in $scopeLabel.');
    }
    final sorted = [...devices]
      ..sort((a, b) {
        final c = b.onHours.compareTo(a.onHours);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    final shown = sorted.take(limit).toList();
    final present = {for (final d in sorted) d.deviceType};
    final types = typeOrder ?? (present.toList()..sort());
    String name(DeviceStat d) => showRoom ? '${d.room} · ${d.deviceId}' : d.deviceId;
    final summary =
        '${name(sorted.first)} ran longest: ${fmt.hours(sorted.first.onHours)} in '
        '${fmt.count(sorted.first.sessions)} sessions. '
        '${sorted.length} ${sorted.length == 1 ? 'device' : 'devices'} in $scopeLabel'
        '${sorted.length > shown.length ? '; the top ${shown.length} are drawn and the table lists all' : ''}.';
    return WidthAwareCard(
      builder: (context, width) {
        final items = <BarDatum>[
          for (final d in shown)
            BarDatum(
              label: name(d),
              value: d.onHours,
              valueLabel: fmt.hours(d.onHours),
              color: palette.colorAt(_slot(types, d.deviceType)),
              pattern: palette.patternAt(_slot(types, d.deviceType)),
            ),
        ];
        final (stacked, height) = RankedBarChart.layoutFor(context, width, items);
        return AccessibleChartCard(
          title: title,
          description: 'Observed on-hours, $scopeLabel. Colour and pattern show the device type.',
          summary: summary,
          chartHeight: height,
          chart: RankedBarChart(stacked: stacked, items: items),
          legend: present.length > 1
              ? PatternLegend(
                  items: [
                    for (var i = 0; i < types.length && i <= maxNamedSeries; i++)
                      if (i == maxNamedSeries
                          ? types.skip(maxNamedSeries).any(present.contains)
                          : present.contains(types[i]))
                        LegendItem.fromPalette(
                          palette,
                          i,
                          i == maxNamedSeries ? 'Other types' : deviceTypeLabel(types[i]),
                        ),
                  ],
                )
              : null,
          table: deviceTable(context, sorted),
        );
      },
    );
  }
}

int _slot(List<String> types, String type) {
  final i = types.indexOf(type);
  return i < 0 ? maxNamedSeries : math.min(i, maxNamedSeries);
}

/// "PROJECTOR" -> "Projector".
String deviceTypeLabel(String type) {
  if (type.isEmpty) return type;
  final lower = type.toLowerCase().replaceAll('_', ' ');
  return lower[0].toUpperCase() + lower.substring(1);
}

/// Full per-device table.
ChartTable deviceTable(BuildContext context, List<DeviceStat> devices) {
  final fmt = Fmt.of(context);
  return ChartTable(
    columns: const [
      ChartColumn('Room'),
      ChartColumn('Device'),
      ChartColumn('Type'),
      ChartColumn('Sessions', numeric: true),
      ChartColumn('On-hours', numeric: true),
      ChartColumn('Average session', numeric: true),
      ChartColumn('Longest session', numeric: true),
      ChartColumn('Long sessions', numeric: true, tooltip: 'Sessions longer than the long device session threshold in Settings'),
      ChartColumn('On at end of data'),
    ],
    rows: [
      for (final d in devices)
        [
          d.room,
          d.deviceId,
          deviceTypeLabel(d.deviceType),
          fmt.count(d.sessions),
          fmt.hours(d.onHours),
          fmt.hours(d.averageSessionHours),
          fmt.hours(d.longestSessionHours),
          fmt.count(d.leftOnSessions),
          d.onAtEnd ? 'Yes' : 'No',
        ],
    ],
    rawRows: [
      for (final d in devices)
        [
          d.room,
          d.deviceId,
          d.deviceType,
          d.sessions,
          d.onHours,
          d.averageSessionHours,
          d.longestSessionHours,
          d.leftOnSessions,
          d.onAtEnd ? 'Yes' : 'No',
        ],
    ],
  );
}

// ------------------------------------------------------------------- trends

/// A named daily or weekly series.
@immutable
class NamedSeries {
  const NamedSeries(this.label, this.points, {this.slot});

  final String label;
  final List<SeriesPoint> points;

  /// Palette slot (colour and marker); defaults to the series position.
  final int? slot;
}

/// Line chart of one or more weekly (or daily) series. Partial periods are
/// drawn hollow and dashed and flagged in the table.
class SeriesTrendCard extends StatelessWidget {
  const SeriesTrendCard({
    super.key,
    required this.title,
    required this.description,
    required this.series,
    required this.unit,
    this.weekly = true,
    this.actions = const [],
  });

  final String title;
  final String description;
  final List<NamedSeries> series;

  /// "hours" or "selections": formats values.
  final String unit;
  final bool weekly;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    final nonEmpty = [
      for (final s in series)
        if (s.points.isNotEmpty) s,
    ];
    if (nonEmpty.isEmpty) {
      return EmptyChartCard(title: title, message: 'There is no data for this period.');
    }
    String value(double v) => unit == 'hours' ? fmt.hours(v) : fmt.decimal(v);
    // All series share the first series' dates (the engine emits dense,
    // aligned series for the same range).
    final dates = nonEmpty.first.points.map((p) => p.date).toList();
    final first = nonEmpty.first;
    final complete = [
      for (final p in first.points)
        if (p.isComplete) p,
    ];
    String summary;
    if (complete.length >= 2) {
      final a = complete.first, b = complete.last;
      final dir = b.value > a.value * 1.05
          ? 'rose'
          : b.value < a.value * 0.95
          ? 'fell'
          : 'stayed about the same';
      summary =
          '${first.label} $dir from ${value(a.value)} in the '
          '${weekly ? weekLabel(a.date).toLowerCase() : Fmt.calendarDateShort(a.date)} to ${value(b.value)} in the '
          '${weekly ? weekLabel(b.date).toLowerCase() : Fmt.calendarDateShort(b.date)}.';
    } else {
      final total = first.points.fold<double>(0, (s, p) => s + p.value);
      summary =
          '${first.label}: ${value(total)} over ${first.points.length} '
          '${weekly ? 'weeks' : 'days'}; not enough complete ${weekly ? 'weeks' : 'days'} to show a trend.';
    }
    if (nonEmpty.length > 1) summary += ' ${nonEmpty.length} series are shown.';
    final anyPartial = nonEmpty.any((s) => s.points.any((p) => !p.isComplete));
    return AccessibleChartCard(
      title: title,
      description: description,
      summary: summary,
      actions: actions,
      chartHeight: 240,
      chart: TrendLineChart(
        xLabels: [for (final d in dates) Fmt.calendarDateShort(d)],
        yFormat: (v) => unit == 'hours' ? '${fmt.compact(v)} h' : fmt.compact(v),
        series: [
          for (var i = 0; i < nonEmpty.length; i++)
            TrendSeries(
              label: nonEmpty[i].label,
              values: [for (final p in nonEmpty[i].points) p.value],
              partial: [for (final p in nonEmpty[i].points) !p.isComplete],
              color: palette.colorAt(nonEmpty[i].slot ?? i),
              marker: markerAt(nonEmpty[i].slot ?? i),
            ),
        ],
      ),
      legend: MarkerLegend(
        items: [
          for (var i = 0; i < nonEmpty.length; i++)
            MarkerLegendItem(
              label: nonEmpty[i].label,
              color: palette.colorAt(nonEmpty[i].slot ?? i),
              marker: markerAt(nonEmpty[i].slot ?? i),
            ),
        ],
        note: anyPartial ? 'Hollow marker, dashed line: partial ${weekly ? 'week' : 'day'}' : null,
      ),
      table: ChartTable(
        columns: [
          ChartColumn(weekly ? 'Week starting' : 'Date'),
          for (final s in nonEmpty) ChartColumn(s.label, numeric: true),
          const ChartColumn('Complete period'),
        ],
        rows: [
          for (var i = 0; i < dates.length; i++)
            [
              Fmt.calendarDate(dates[i]),
              for (final s in nonEmpty) i < s.points.length ? value(s.points[i].value) : '',
              nonEmpty.every((s) => i >= s.points.length || s.points[i].isComplete) ? 'Yes' : 'No (partial)',
            ],
        ],
        rawRows: [
          for (var i = 0; i < dates.length; i++)
            [
              Fmt.calendarDate(dates[i]),
              for (final s in nonEmpty) i < s.points.length ? s.points[i].value : null,
              nonEmpty.every((s) => i >= s.points.length || s.points[i].isComplete) ? 'Yes' : 'No',
            ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- columns

/// Hourly (0-23) counts as a column chart.
class HourlyCountsCard extends StatelessWidget {
  const HourlyCountsCard({
    super.key,
    required this.title,
    required this.description,
    required this.counts,
    required this.noun,
    required this.timeZoneLabel,
    this.seriesIndex = 0,
  });

  final String title;
  final String description;

  /// 24 values, index = hour of day.
  final List<num> counts;

  /// Plural noun for the summary, e.g. "power-ons".
  final String noun;
  final String timeZoneLabel;

  /// Palette slot (colour and pattern) for the columns.
  final int seriesIndex;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    final total = counts.fold<num>(0, (s, c) => s + c);
    if (total <= 0) {
      return EmptyChartCard(title: title, message: 'No $noun were recorded in this period.');
    }
    var peak = 0;
    for (var h = 1; h < counts.length; h++) {
      if (counts[h] > counts[peak]) peak = h;
    }
    // Three busiest consecutive hours.
    var bestStart = 0;
    num bestSum = -1;
    for (var h = 0; h + 2 < counts.length; h++) {
      final s = counts[h] + counts[h + 1] + counts[h + 2];
      if (s > bestSum) {
        bestSum = s;
        bestStart = h;
      }
    }
    final isInt = counts.every((c) => c is int);
    String value(num v) => isInt ? fmt.count(v) : fmt.decimal(v);
    final summary =
        'Most $noun happen at ${Fmt.hourOfDay(peak)} (${value(counts[peak])} of ${value(total)}, '
        '${fmt.percent(counts[peak] / total)}). ${Fmt.hourOfDay(bestStart)} to '
        '${Fmt.hourOfDay((bestStart + 3) % 24)} has ${fmt.percent(bestSum / total)} of all $noun.';
    return AccessibleChartCard(
      title: title,
      description: '$description Times in $timeZoneLabel.',
      summary: summary,
      chartHeight: 220,
      chart: ColumnChart(
        color: palette.colorAt(seriesIndex),
        pattern: palette.patternAt(seriesIndex),
        yFormat: (v) => fmt.compact(v),
        showValues: false,
        data: [
          for (var h = 0; h < counts.length; h++) ColumnDatum(label: Fmt.hourOfDay(h), value: counts[h].toDouble()),
        ],
      ),
      table: ChartTable(
        columns: [
          const ChartColumn('Hour'),
          ChartColumn(noun[0].toUpperCase() + noun.substring(1), numeric: true),
          const ChartColumn('Share', numeric: true),
        ],
        rows: [
          for (var h = 0; h < counts.length; h++) [Fmt.hourOfDay(h), value(counts[h]), fmt.percent(counts[h] / total)],
        ],
        rawRows: [
          for (var h = 0; h < counts.length; h++) [h, counts[h], counts[h] / total],
        ],
      ),
    );
  }
}
