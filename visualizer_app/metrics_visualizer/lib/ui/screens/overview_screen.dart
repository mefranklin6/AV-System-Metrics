import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';
import 'parts/a_cards.dart';
import 'parts/a_charts.dart';
import 'parts/a_common.dart';
import 'parts/a_insights.dart';
import 'parts/b_table.dart';

/// Campus-wide summary: headline numbers, small versions of the key charts,
/// the most important issues and plain-language insights.
class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key});

  @override
  Widget build(BuildContext context) => AnalysisPage(
    title: 'Overview',
    subtitle: 'Campus-wide summary of room and device usage.',
    builder: (context, analysis) {
      if (analysis.isEmpty) return noMatchingRooms(context);
      final leftOn = context.select<SettingsState, int>((s) => s.analysisConfig.thresholds.deviceLeftOnHours);
      return [
        _Kpis(analysis: analysis),
        // Warnings change how the figures should be read, so they come
        // before the charts; the rest of the data notes are at the end.
        if (analysis.dataQuality.warnings.isNotEmpty) DataWarningsCard(warnings: analysis.dataQuality.warnings),
        const SizedBox(height: 8),
        const SectionHeader(title: 'At a glance'),
        ResponsiveGrid(
          minChildWidth: 400,
          maxColumns: 2,
          children: [
            InputShareCard(
              shares: analysis.inputs.campus,
              measure: InputMeasure.time,
              scopeLabel: 'all rooms',
              styles: InputStyles(ChartPalette.of(context), analysis.inputs.campus),
            ),
            SeriesTrendCard(
              title: 'Weekly system hours',
              description: 'Total hours rooms had their AV system on, per week (Monday start).',
              series: [NamedSeries('System hours', analysis.system.weekly)],
              unit: 'hours',
            ),
            _BusiestHoursCard(analysis: analysis),
            _TopIssuesCard(issues: analysis.issues),
          ],
        ),
        const SizedBox(height: 8),
        InfoCard(
          title: 'Insights',
          icon: Icons.lightbulb_outline,
          description: 'Plain-language findings from this data. Confirm before acting on them.',
          child: InsightList(insights: buildInsights(analysis, leftOnHours: leftOn)),
        ),
        DataQualityCard(quality: analysis.dataQuality),
      ];
    },
  );
}

/// Data and configuration warnings ([DataQuality.warnings]), such as how
/// spreadsheet dates were read or a settings pattern that could not be used.
class DataWarningsCard extends StatelessWidget {
  const DataWarningsCard({super.key, required this.warnings});

  final List<String> warnings;

  static const String title = 'Check these notes about the data';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = theme.textTheme.bodyMedium?.copyWith(color: cs.onTertiaryContainer);
    return Semantics(
      container: true,
      child: Card(
        color: cs.tertiaryContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.onTertiaryContainer.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(Icons.warning_amber_rounded, color: cs.onTertiaryContainer),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Heading(
                      title,
                      level: HeadingLevel.subsection,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: cs.onTertiaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'They affect how the figures on every page should be read.',
                      style: style,
                    ),
                    const SizedBox(height: 8),
                    for (final w in warnings) _Bullet(w, style: style),
                    const SizedBox(height: 4),
                    Theme(
                      data: theme.copyWith(
                        outlinedButtonTheme: OutlinedButtonThemeData(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: cs.onTertiaryContainer,
                            side: BorderSide(color: cs.onTertiaryContainer),
                          ),
                        ),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () => context.read<NavigationState>().goTo(AppDestination.settings),
                            icon: const Icon(Icons.tune),
                            label: const Text('Open Settings'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () => context.read<NavigationState>().goTo(AppDestination.dataSource),
                            icon: const Icon(Icons.storage_outlined),
                            label: const Text('Open Data source'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Transparency notes about the analysed data ([DataQuality]): rows that
/// could not be read, excluded clients, sessions that had to be closed by a
/// rule and warnings, plus the most common unmatched (metric, action) pairs
/// with links to Event recognition settings and the Implementation Guide.
class DataQualityCard extends StatelessWidget {
  const DataQualityCard({super.key, required this.quality});

  final DataQuality quality;

  static const String title = 'Data quality';

  /// Heading of the unmatched events list.
  static const String unmatchedTitle = 'Events that matched no rule';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    final q = quality;
    String n(int v, String one, String many) => '${fmt.count(v)} ${v == 1 ? one : many}';
    final notes = <String>[
      if (q.warnings.isNotEmpty)
        '${n(q.warnings.length, 'warning is', 'warnings are')} listed under "${DataWarningsCard.title}" near the top of this page.',
      if (q.skippedRows > 0) '${n(q.skippedRows, 'row', 'rows')} could not be read and ${q.skippedRows == 1 ? 'was' : 'were'} skipped.',
      if (q.excludedEvents > 0)
        '${n(q.excludedEvents, 'event', 'events')} from excluded clients (such as AVSM-System) ${q.excludedEvents == 1 ? 'was' : 'were'} left out. '
            'Change the list under Data in Settings.',
      if (q.adminEvents > 0)
        '${n(q.adminEvents, 'event', 'events')} from the server\'s own AVSM-System client ${q.adminEvents == 1 ? 'was' : 'were'} not treated as a room.',
      if (q.unterminatedSessions > 0)
        '${n(q.unterminatedSessions, 'session', 'sessions')} had no off event and ${q.unterminatedSessions == 1 ? 'was' : 'were'} '
            'cut at the longest believable session (Settings).',
      if (q.orphanStops > 0) '${n(q.orphanStops, '"Stopped" event', '"Stopped" events')} had nothing to stop and ${q.orphanStops == 1 ? 'was' : 'were'} ignored.',
      if (q.duplicateStarts > 0)
        '${n(q.duplicateStarts, 'repeated "Started" event was', 'repeated "Started" events were')} ignored.',
      if (q.unclassifiedTotal > 0)
        '${n(q.unclassifiedTotal, 'event', 'events')} matched no event recognition rule and ${q.unclassifiedTotal == 1 ? 'is' : 'are'} '
            'only counted in totals and shown on the room timeline. The most common are listed under "$unmatchedTitle" below.',
    ];
    return InfoCard(
      title: title,
      icon: Icons.fact_check_outlined,
      description: 'How the data was read and cleaned before these figures were worked out.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notes.isEmpty)
            Text('Every row was read and recognised; nothing had to be skipped or corrected.', style: style)
          else
            for (final t in notes) _Bullet(t, style: style),
          if (q.unclassifiedTotal > 0) ...[
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 4),
              child: Heading(unmatchedTitle, level: HeadingLevel.detail),
            ),
            Text(
              'These metric and action pairs matched no rule, so no chart uses them. If one of them should be '
              'recognized (for example a system power, source or device event logged under another name), add '
              'its name under Settings > Event recognition, or follow the naming in the Implementation Guide.',
              style: style,
            ),
            const SizedBox(height: 8),
            if (q.unclassified.isNotEmpty)
              SortableTable(
                label: unmatchedTitle,
                pageSize: 10,
                columns: const [ChartColumn('Metric'), ChartColumn('Action'), ChartColumn('Events', numeric: true)],
                rows: [
                  for (final m in q.unclassified) [m.metric, m.action, fmt.count(m.count)],
                ],
                sortKeys: [
                  for (final m in q.unclassified) [m.metric, m.action, m.count],
                ],
                initialSortColumn: 2,
                initialAscending: false,
              ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => context.read<NavigationState>().openSettings(SettingsSection.eventRecognition),
                icon: const Icon(Icons.rule),
                label: const Text('Open Event recognition settings'),
              ),
            ),
            const SizedBox(height: 8),
            const GuideLink(),
          ],
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Text('•  ', style: style)),
        Expanded(child: Text(text, style: style)),
      ],
    ),
  );
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.analysis});

  final AnalysisResult analysis;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final nav = context.read<NavigationState>();
    final o = analysis.overview;
    final top = o.mostUsedInputByTime;
    final change = lastPeriodChange(analysis.system.weekly);
    final counts = o.issueCounts;
    final critical = counts[IssueSeverity.critical] ?? 0;
    final warning = counts[IssueSeverity.warning] ?? 0;
    final info = counts[IssueSeverity.info] ?? 0;
    return ResponsiveGrid(
      minChildWidth: 230,
      maxColumns: 6,
      children: [
        KpiTile(
          label: 'Rooms',
          value: fmt.count(o.roomCount),
          icon: Icons.meeting_room_outlined,
          caption: 'in ${fmt.count(o.buildingCount)} ${o.buildingCount == 1 ? 'building' : 'buildings'}',
          onTap: () => nav.goTo(AppDestination.rooms),
          tooltip: 'Open the room list',
        ),
        KpiTile(
          label: 'System hours',
          value: fmt.hours(o.totalSystemHours),
          icon: Icons.power_settings_new,
          caption: '${fmt.count(o.systemSessionCount)} sessions over ${fmt.decimal(o.days)} days',
          trend: change == null
              ? null
              : change > 0.02
              ? KpiTrend.up
              : change < -0.02
              ? KpiTrend.down
              : KpiTrend.flat,
          trendLabel: change == null
              ? null
              : '${change >= 0 ? 'Up' : 'Down'} ${fmt.percent(change.abs())} on the previous complete week',
          onTap: () => nav.goTo(AppDestination.systemUsage),
          tooltip: 'Open system usage',
        ),
        KpiTile(
          label: 'Average daily use per room',
          value: fmt.hours(o.averageDailyHoursPerRoom),
          icon: Icons.schedule,
          caption: 'system on, per room per day',
        ),
        KpiTile(
          label: 'Top source',
          value: top?.label ?? 'None',
          icon: Icons.input,
          caption: top == null
              ? 'No source selections in this period'
              : '${fmt.percent(top.timeShare)} of time on screen, used in ${fmt.count(top.roomCount)} rooms',
          onTap: () => nav.goTo(AppDestination.inputs),
          tooltip: 'Open sources',
        ),
        KpiTile(
          label: 'Potential issues',
          value: fmt.count(o.issueTotal),
          icon: Icons.report_problem_outlined,
          caption: '${fmt.count(critical)} critical, ${fmt.count(warning)} warning, ${fmt.count(info)} info',
          onTap: () => nav.goTo(AppDestination.issues),
          tooltip: 'Open issues',
        ),
        KpiTile(
          label: 'Device on-hours',
          value: fmt.hours(o.totalDeviceHours),
          icon: Icons.videocam_outlined,
          caption: '${fmt.count(o.deviceCount)} devices',
          onTap: () => nav.goTo(AppDestination.devices),
          tooltip: 'Open devices',
        ),
      ],
    );
  }
}

/// Average share of rooms in use per hour on business weekdays.
class _BusiestHoursCard extends StatelessWidget {
  const _BusiestHoursCard({required this.analysis});

  final AnalysisResult analysis;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    const title = 'Busiest hours';
    final days = {
      for (final d in analysis.system.businessHours.weekdays)
        if (d >= 1 && d <= 7) d,
    }.toList()..sort();
    final usedDays = days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : days;
    final values = [
      for (var h = 0; h < 24; h++)
        usedDays.fold<double>(0, (s, d) => s + analysis.system.occupancy.valueAt(d, h)) / usedDays.length,
    ];
    final maxV = values.fold<double>(0, (m, v) => v > m ? v : m);
    if (maxV <= 0) {
      return const EmptyChartCard(title: title, message: 'No room had its system on during this period.');
    }
    final peak = values.indexOf(maxV);
    final dayWords = days.length == 5 && days.first == 1 && days.last == 5
        ? 'weekdays'
        : usedDays.map((d) => Fmt.weekday(d, short: true)).join(', ');
    return AccessibleChartCard(
      title: title,
      description: 'Average share of rooms with the system on, $dayWords, by hour (${analysis.timeZoneLabel}).',
      summary:
          'Rooms are busiest at ${Fmt.hourOfDay(peak)}, when on average ${fmt.percent(maxV)} '
          'of rooms are in use on $dayWords.',
      chartHeight: 220,
      chart: ColumnChart(
        color: palette.colorAt(2),
        pattern: palette.patternAt(2),
        yFormat: (v) => fmt.percent(v),
        showValues: false,
        data: [for (var h = 0; h < 24; h++) ColumnDatum(label: Fmt.hourOfDay(h), value: values[h])],
      ),
      table: ChartTable(
        columns: const [ChartColumn('Hour'), ChartColumn('Rooms in use (average)', numeric: true)],
        rows: [
          for (var h = 0; h < 24; h++) [Fmt.hourOfDay(h), fmt.percent(values[h])],
        ],
        rawRows: [
          for (var h = 0; h < 24; h++) [h, values[h]],
        ],
      ),
    );
  }
}

class _TopIssuesCard extends StatelessWidget {
  const _TopIssuesCard({required this.issues});

  final List<Issue> issues;

  @override
  Widget build(BuildContext context) {
    final top = issuesBySeverity(issues).take(5).toList();
    return InfoCard(
      title: 'Top issues',
      icon: Icons.report_problem_outlined,
      description: issues.isEmpty
          ? null
          : 'The ${top.length} most severe of ${Fmt.of(context).count(issues.length)} potential issues.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (top.isEmpty)
            Text(
              'No patterns were found in this period.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface),
            )
          else
            IssueSummaryList(issues: top),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: () => context.read<NavigationState>().goTo(AppDestination.issues),
              icon: const Icon(Icons.arrow_forward),
              label: const Text('View all issues'),
            ),
          ),
        ],
      ),
    );
  }
}
