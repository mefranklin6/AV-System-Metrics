// Shared building blocks for the Overview, Inputs, Devices, System usage and
// Rooms screens: consistent input colours, "Other" grouping, empty states,
// plain cards and insight lists.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../analytics/analytics.dart';
import '../../../state/app_state.dart';
import '../../../state/navigation_state.dart';
import '../../widgets/widgets.dart';
import '../issues_screen.dart';
import 'a_charts.dart';

/// Number of named slices before the rest is grouped into "Other" (the
/// palette has 8 colours; the 8th is reserved for "Other").
const int maxNamedSeries = 7;

/// "Week of Nov 3" for a series week-start calendar date (see
/// [Fmt.calendarDateShort]; never converts time zones).
String weekLabel(DateTime monday) => 'Week of ${Fmt.calendarDateShort(monday)}';

/// Colour and pattern of every input, fixed by its campus-wide rank by
/// time on screen, so an input looks the same on every chart and scope.
class InputStyles {
  InputStyles(this.palette, List<InputShare> campus)
    : _rank = {for (var i = 0; i < campus.length; i++) campus[i].key: i};

  final ChartPalette palette;
  final Map<String, int> _rank;

  int _index(String key) => math.min(_rank[key] ?? maxNamedSeries, maxNamedSeries);

  Color color(String key) => palette.colorAt(_index(key));
  ChartPattern pattern(String key) => palette.patternAt(_index(key));

  /// Style of the grouped "Other" slice.
  Color get otherColor => palette.colorAt(maxNamedSeries);
  ChartPattern get otherPattern => palette.patternAt(maxNamedSeries);
}

/// Which measure of input usage a chart shows.
enum InputMeasure {
  selections('Selections'),
  time('Time on screen');

  const InputMeasure(this.label);

  final String label;

  double valueOf(InputShare s) => this == selections ? s.selections.toDouble() : s.hours;
  double shareOf(InputShare s) => this == selections ? s.selectionShare : s.timeShare;
}

/// Inputs sorted by [measure] (largest first, ties by label).
List<InputShare> sortInputs(List<InputShare> shares, InputMeasure measure) => [...shares]
  ..sort((a, b) {
    final c = measure.valueOf(b).compareTo(measure.valueOf(a));
    return c != 0 ? c : a.label.compareTo(b.label);
  });

/// The empty-filter-result message every analysis screen shows when the
/// current filters leave no rooms.
List<Widget> noMatchingRooms(BuildContext context) => [
  EmptyState(
    icon: Icons.filter_alt_off_outlined,
    title: 'No rooms match the current filters',
    message:
        'The selected dates, buildings or rooms contain no data. '
        'Choose a wider date range or clear the filters.',
    action: FilledButton.icon(
      onPressed: () => context.read<AppState>().clearFilters(),
      icon: const Icon(Icons.filter_alt_off),
      label: const Text('Clear filters'),
    ),
  ),
];

/// A card with a heading, optional description and free content. Use it for
/// lists and tables that are not charts (charts use AccessibleChartCard).
class InfoCard extends StatelessWidget {
  const InfoCard({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.icon,
    this.actions = const [],
  });

  final String title;
  final String? description;
  final IconData? icon;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[Icon(icon, color: cs.primary), const SizedBox(width: 8)],
                    Flexible(
                      child: Heading(title, level: HeadingLevel.subsection),
                    ),
                  ],
                ),
                if (actions.isNotEmpty) Wrap(spacing: 4, runSpacing: 4, children: actions),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: 2),
              Text(description!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// A card that says a chart has nothing to show (keeps the page layout and
/// tells the user why).
class EmptyChartCard extends StatelessWidget {
  const EmptyChartCard({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InfoCard(
      title: title,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

/// A chart card whose chart height depends on the card width (ranked bars).
class WidthAwareCard extends StatelessWidget {
  const WidthAwareCard({super.key, required this.builder});

  final Widget Function(BuildContext context, double width) builder;

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) => builder(context, constraints.maxWidth));
}

/// How an insight should be read.
enum InsightKind {
  info(Icons.info_outline, 'Note'),
  saving(Icons.savings_outlined, 'Budget planning'),
  attention(Icons.warning_amber_outlined, 'Worth reviewing'),
  pattern(Icons.insights_outlined, 'Usage pattern'),
  energy(Icons.bolt_outlined, 'Energy');

  const InsightKind(this.icon, this.label);

  final IconData icon;

  /// Spoken before the sentence and shown as the icon's label.
  final String label;
}

/// One plain-language finding.
@immutable
class Insight {
  const Insight(this.kind, this.text, {this.destination, this.room});

  final InsightKind kind;
  final String text;

  /// Page with the details, if any.
  final AppDestination? destination;

  /// Room to open when [destination] is the Rooms page.
  final String? room;
}

/// A list of [Insight]s with an icon, the sentence and an optional link.
class InsightList extends StatelessWidget {
  const InsightList({super.key, required this.insights});

  final List<Insight> insights;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (insights.isEmpty) {
      return Text(
        'Nothing stands out in this period.',
        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final i in insights)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(i.kind.icon, color: cs.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${i.kind.label}: ',
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            TextSpan(text: i.text),
                          ],
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                      ),
                      if (i.destination != null)
                        TextButton(
                          onPressed: () => context.read<NavigationState>().goTo(i.destination!, room: i.room),
                          child: Text(i.room != null ? 'Open room ${i.room}' : 'Open ${i.destination!.label}'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A small label/value pair used in detail panels.
class StatLine extends StatelessWidget {
  const StatLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          spacing: 8,
          children: [
            Text('$label:', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// Short label for a severity, with its icon (never colour alone).
IconData severityIcon(IssueSeverity s) => switch (s) {
  IssueSeverity.critical => Icons.error_outline,
  IssueSeverity.warning => Icons.warning_amber_outlined,
  IssueSeverity.info => Icons.info_outline,
};

/// Issues ordered most severe first, then newest first.
List<Issue> issuesBySeverity(Iterable<Issue> issues) => [...issues]
  ..sort((a, b) {
    final s = b.severity.index.compareTo(a.severity.index);
    return s != 0 ? s : b.start.compareTo(a.start);
  });

/// A compact list of issues; each opens the Issues page filtered to its
/// room, with that issue expanded and focused.
class IssueSummaryList extends StatelessWidget {
  const IssueSummaryList({super.key, required this.issues, this.showRoom = true});

  final List<Issue> issues;
  final bool showRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final palette = ChartPalette.of(context);
    Color tint(IssueSeverity s) => switch (s) {
      IssueSeverity.critical => palette.bad,
      IssueSeverity.warning => palette.warning,
      IssueSeverity.info => palette.neutral,
    };
    return Column(
      children: [
        for (final i in issues)
          ListTile(
            contentPadding: EdgeInsets.zero,
            minVerticalPadding: 8,
            leading: Icon(severityIcon(i.severity), color: tint(i.severity)),
            title: Text(
              '${i.severity.label}: ${i.title}${showRoom ? ' in ${i.room}' : ''}',
              style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface),
            ),
            subtitle: Text(
              '${fmt.dateTime(i.start)} · ${i.area.label}',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openIssueInIssues(context, i),
          ),
      ],
    );
  }
}

/// "Other" grouping for donut slices: the first [maxNamedSeries] items keep
/// their own slice, the rest are summed.
List<DonutSlice> inputSlices(List<InputShare> sorted, InputMeasure measure, InputStyles styles) {
  final slices = <DonutSlice>[];
  var other = 0.0;
  for (var i = 0; i < sorted.length; i++) {
    final s = sorted[i];
    if (i < maxNamedSeries) {
      slices.add(
        DonutSlice(
          label: s.label,
          value: measure.valueOf(s),
          color: styles.color(s.key),
          pattern: styles.pattern(s.key),
        ),
      );
    } else {
      other += measure.valueOf(s);
    }
  }
  if (other > 0) {
    slices.add(DonutSlice(label: 'Other', value: other, color: styles.otherColor, pattern: styles.otherPattern));
  }
  return slices;
}

/// Percent change of the last complete period against the one before it,
/// or null when there are not two complete periods with data.
double? lastPeriodChange(List<SeriesPoint> series) {
  final complete = [
    for (final p in series)
      if (p.isComplete) p,
  ];
  if (complete.length < 2) return null;
  final prev = complete[complete.length - 2].value;
  final last = complete.last.value;
  if (prev <= 0) return null;
  return (last - prev) / prev;
}
