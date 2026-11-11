import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/app_state.dart';
import '../../state/navigation_state.dart';
import '../widgets/widgets.dart';
import 'parts/b_charts.dart';
import 'parts/b_common.dart';
import 'parts/b_issue_logic.dart';
import 'parts/b_issue_widgets.dart';

/// Opens the Issues page showing [issue]: the list is filtered to the
/// issue's room, and the issue is expanded, scrolled into view and focused.
/// Used by issue links on other pages so they land on the issue they name
/// instead of the top of the full list.
void openIssueInIssues(BuildContext context, Issue issue) {
  _IssuesScreenState._pendingReveal = issue;
  context.read<NavigationState>().goTo(AppDestination.issues);
}

/// Patterns worth reviewing, found in the event data: a filterable list with
/// factual explanations, things worth checking and evidence, counts by type
/// and by data area, and CSV export.
class IssuesScreen extends StatefulWidget {
  const IssuesScreen({super.key});

  @override
  State<IssuesScreen> createState() => _IssuesScreenState();
}

enum _Grouping {
  type('By type'),
  cause('By data area');

  const _Grouping(this.label);
  final String label;
}

class _IssuesScreenState extends State<IssuesScreen> {
  static const int _page = 25;

  /// Set by [openIssueInIssues] just before the page opens.
  static Issue? _pendingReveal;
  String? _revealId;
  final GlobalKey _revealKey = GlobalKey(debugLabel: 'Revealed issue');
  final GlobalKey _topKey = GlobalKey(debugLabel: 'Issues top');
  final FocusNode _revealFocus = FocusNode(debugLabel: 'Revealed issue', skipTraversal: true);

  IssueFilter _filter = const IssueFilter();
  _Grouping _grouping = _Grouping.type;
  int _visible = _page;
  final Set<String> _expanded = {};
  final TextEditingController _search = TextEditingController();
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    final reveal = _pendingReveal;
    _pendingReveal = null;
    if (reveal != null) {
      _filter = IssueFilter(building: reveal.building, room: reveal.room);
      _expanded.add(reveal.id);
      _revealId = reveal.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showRevealed(reveal));
    }
  }

  /// Brings the issue opened from another page into view and focuses it.
  /// The page list is built lazily, so it scrolls step by step until the
  /// issue's card exists.
  void _showRevealed(Issue issue, [int attempt = 0, ScrollPosition? scroll]) {
    if (!mounted) return;
    final ctx = _revealKey.currentContext;
    if (ctx == null) {
      final top = _topKey.currentContext;
      // The top item scrolls out of the lazily built list, so keep the
      // position from the first attempt.
      final position = scroll ?? (top == null ? null : Scrollable.maybeOf(top)?.position);
      if (position != null &&
          position.hasPixels &&
          attempt < 60 &&
          position.pixels < position.maxScrollExtent) {
        position.jumpTo((position.pixels + position.viewportDimension * 0.8).clamp(0, position.maxScrollExtent));
        WidgetsBinding.instance.addPostFrameCallback((_) => _showRevealed(issue, attempt + 1, position));
        return;
      }
    } else {
      Scrollable.ensureVisible(ctx, alignment: 0.1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _revealKey.currentContext != null) _revealFocus.requestFocus();
      });
    }
    announce(context, 'Showing issues in ${issue.room}. ${issue.title} is expanded.');
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _revealFocus.dispose();
    super.dispose();
  }

  List<Issue> _apply(AnalysisResult a, IssueFilter f) =>
      f.apply(a.issues, rangeEnd: a.rangeEnd, knownBuildings: a.buildings.toSet(), knownRooms: a.rooms.toSet());

  /// Applies [next] and announces the new result count.
  void _setFilter(IssueFilter next, {bool announceNow = true}) {
    setState(() {
      _filter = next;
      _visible = _page;
    });
    if (announceNow) _announceCount();
  }

  void _announceCount() {
    final a = context.read<AppState>().analysis;
    if (a == null || !mounted) return;
    final n = _apply(a, _filter).length;
    announce(context, 'Showing $n of ${a.issues.length} issues.');
  }

  void _onSearchChanged(String text) {
    _setFilter(_filter.copyWith(query: text), announceNow: false);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted) _announceCount();
    });
  }

  void _clearFilters() {
    _search.clear();
    _setFilter(_filter.cleared());
  }

  void _openRoom(String room) => context.read<NavigationState>().goTo(AppDestination.rooms, room: room);

  @override
  Widget build(BuildContext context) {
    return AnalysisPage(
      title: 'Issues',
      subtitle: 'Patterns in the event data worth reviewing. Each one describes what the data shows, not its cause.',
      builder: (context, analysis) => _content(context, analysis),
    );
  }

  List<Widget> _content(BuildContext context, AnalysisResult a) {
    if (a.issues.isEmpty) {
      return [
        EmptyState(
          icon: Icons.task_alt,
          title: 'No patterns found',
          message:
              'No pattern in the selected rooms and dates reached the detection thresholds. '
              'You can change the thresholds in Settings.',
          action: OutlinedButton.icon(
            onPressed: () => context.read<NavigationState>().openSettings(SettingsSection.thresholds),
            icon: const Icon(Icons.tune),
            label: const Text('Detection thresholds'),
          ),
        ),
      ];
    }
    final filtered = _apply(a, _filter);
    final shown = filtered.take(_visible).toList();
    return [
      KeyedSubtree(key: _topKey, child: _kpis(context, a)),
      _chartCard(context, a),
      _filterCard(context, a, filtered),
      if (filtered.isEmpty)
        _noMatches(context)
      else ...[
        for (final i in shown)
          _revealable(
            i,
            IssueTile(
              key: ValueKey('issue-tile-${i.id}'),
              issue: i,
              expanded: _expanded.contains(i.id),
              onExpansionChanged: (open) => setState(() {
                if (open) {
                  _expanded.add(i.id);
                } else {
                  _expanded.remove(i.id);
                }
              }),
              onOpenRoom: _openRoom,
            ),
          ),
        if (shown.length < filtered.length)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton(
              onPressed: () => setState(() => _visible += _page),
              child: Text('Show more issues (${filtered.length - shown.length} remaining)'),
            ),
          ),
      ],
    ];
  }

  /// Wraps the issue opened from another page in a focus target, so it can
  /// receive focus (the ring is drawn around the whole card).
  Widget _revealable(Issue i, Widget tile) =>
      i.id != _revealId ? tile : Focus(key: _revealKey, focusNode: _revealFocus, child: tile);

  // ------------------------------------------------------------------ KPIs

  Widget _kpis(BuildContext context, AnalysisResult a) {
    final fmt = Fmt.of(context);
    final counts = countIssuesBy(a.issues, (i) => i.severity, IssueSeverity.values);
    KpiTile tile(IssueSeverity s, String caption) {
      final n = counts[s] ?? 0;
      return KpiTile(
        label: s.label,
        value: fmt.count(n),
        icon: severityIcon(s),
        caption: caption,
        tooltip: 'Show only ${s.label.toLowerCase()} issues',
        onTap: () => _setFilter(_filter.copyWith(severities: {s})),
      );
    }

    return ResponsiveGrid(
      minChildWidth: 200,
      children: [
        KpiTile(
          label: 'Potential issues',
          value: fmt.count(a.issues.length),
          icon: Icons.report_problem_outlined,
          caption: 'in ${fmt.count({for (final i in a.issues) i.room}.length)} rooms',
        ),
        tile(IssueSeverity.critical, 'Strongest patterns'),
        tile(IssueSeverity.warning, 'Clear patterns'),
        tile(IssueSeverity.info, 'For awareness'),
      ],
    );
  }

  // ----------------------------------------------------------------- chart

  Widget _chartCard(BuildContext context, AnalysisResult a) {
    final fmt = Fmt.of(context);
    final total = a.issues.length;
    final List<(String, int, int)> entries; // label, count, palette index
    if (_grouping == _Grouping.type) {
      final c = countIssuesBy(a.issues, (i) => i.type, IssueType.values);
      entries = [for (final e in c.entries) (e.key.label, e.value, e.key.index)];
    } else {
      final c = countIssuesBy(a.issues, (i) => i.area, IssueArea.values);
      entries = [for (final e in c.entries) (e.key.label, e.value, e.key.index)];
    }
    entries.sort((x, y) {
      final c = y.$2.compareTo(x.$2);
      return c != 0 ? c : x.$1.compareTo(y.$1);
    });
    final maxCount = entries.isEmpty ? 1 : entries.first.$2;
    final top = entries.first;
    final noun = _grouping == _Grouping.type ? 'type' : 'data area';
    final summary =
        '${fmt.count(total)} potential issues. The most common $noun is ${top.$1}: '
        '${fmt.count(top.$2)} (${fmt.percent(top.$2 / total)}).'
        '${entries.length > 1 ? ' Next is ${entries[1].$1} with ${fmt.count(entries[1].$2)}.' : ''}';
    return AccessibleChartCard(
      title: 'Issues ${_grouping == _Grouping.type ? 'by type' : 'by data area'}',
      description: 'All issues in the selected rooms and dates. The list below can be narrowed further.',
      summary: summary,
      chartHeight: LabeledBarList.heightFor(context, entries.length),
      actions: [
        SegmentedButton<_Grouping>(
          showSelectedIcon: false,
          segments: [for (final g in _Grouping.values) ButtonSegment(value: g, label: Text(g.label))],
          selected: {_grouping},
          onSelectionChanged: (s) => setState(() => _grouping = s.first),
        ),
      ],
      chart: LabeledBarList(
        items: [
          for (final (label, count, index) in entries)
            BarListItem(
              label: label,
              fraction: count / maxCount,
              valueText: '${fmt.count(count)} (${fmt.percent(count / total)})',
              seriesIndex: index,
            ),
        ],
      ),
      footer: _grouping == _Grouping.cause
          ? const Text(
              'Data area is the kind of event a pattern was found in (for example system power, controls, '
              'sources or heartbeats). It says where to look in the data, not what caused the pattern.',
            )
          : null,
      table: ChartTable(
        columns: [
          ChartColumn(_grouping == _Grouping.type ? 'Type' : 'Data area'),
          const ChartColumn('Issues', numeric: true),
          const ChartColumn('Share', numeric: true),
        ],
        rows: [
          for (final (label, count, _) in entries) [label, fmt.count(count), fmt.percent(count / total)],
        ],
        rawRows: [
          for (final (label, count, _) in entries) [label, count, count / total],
        ],
      ),
    );
  }

  // --------------------------------------------------------------- filters

  Widget _filterCard(BuildContext context, AnalysisResult a, List<Issue> filtered) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final f = _filter;
    final typeCounts = countIssuesBy(a.issues, (i) => i.type, IssueType.values);
    final areaCounts = countIssuesBy(a.issues, (i) => i.area, IssueArea.values);
    final sevCounts = countIssuesBy(a.issues, (i) => i.severity, IssueSeverity.values);
    final building = f.building != null && a.buildings.contains(f.building) ? f.building : null;
    final rooms = building == null ? a.rooms : a.roomsInBuilding(building);
    final room = f.room != null && rooms.contains(f.room) ? f.room : null;

    Widget chipGroup<T>(
      String label,
      List<T> values,
      Set<T> selected,
      String Function(T) name,
      Map<T, int> counts,
      void Function(Set<T>) onChanged,
    ) {
      return Semantics(
        container: true,
        label: '$label filter',
        explicitChildNodes: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final v in values)
                  FilterChip(
                    label: Text('${name(v)} (${fmt.count(counts[v] ?? 0)})'),
                    selected: selected.contains(v),
                    onSelected: (_) => onChanged(IssueFilter.toggle(selected, v)),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    final dropdowns = ResponsiveGrid(
      minChildWidth: 220,
      children: [
        DropdownButtonFormField<String?>(
          key: ValueKey('building-$building'),
          initialValue: building,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Building'),
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All buildings')),
            for (final b in a.buildings) DropdownMenuItem<String?>(value: b, child: Text(b)),
          ],
          onChanged: (v) => _setFilter(f.copyWith(building: () => v, room: () => null)),
        ),
        DropdownButtonFormField<String?>(
          key: ValueKey('room-$building-$room'),
          initialValue: room,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Room'),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(building == null ? 'All rooms' : 'All rooms in $building'),
            ),
            for (final r in rooms) DropdownMenuItem<String?>(value: r, child: Text(r)),
          ],
          onChanged: (v) => _setFilter(f.copyWith(room: () => v)),
        ),
        DropdownButtonFormField<IssuePeriod>(
          key: ValueKey('period-${f.period}'),
          initialValue: f.period,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'When', helperText: 'Counted back from the end of the data'),
          items: [for (final p in IssuePeriod.values) DropdownMenuItem(value: p, child: Text(p.label))],
          onChanged: (v) => _setFilter(f.copyWith(period: v)),
        ),
        DropdownButtonFormField<IssueSort>(
          key: ValueKey('sort-${f.sort}'),
          initialValue: f.sort,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Sort'),
          items: [for (final s in IssueSort.values) DropdownMenuItem(value: s, child: Text(s.label))],
          onChanged: (v) => _setFilter(f.copyWith(sort: v)),
        ),
      ],
    );

    return TitledCard(
      title: 'Find issues',
      subtitle: 'Choose any combination. With nothing selected in a group, all of that group are shown.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chipGroup<IssueSeverity>(
            'Severity',
            IssueSeverity.values.reversed.toList(),
            f.severities,
            (s) => s.label,
            sevCounts,
            (s) => _setFilter(f.copyWith(severities: s)),
          ),
          const SizedBox(height: 12),
          chipGroup<IssueType>(
            'Type',
            [
              for (final t in IssueType.values)
                if (typeCounts.containsKey(t) || f.types.contains(t)) t,
            ],
            f.types,
            (t) => t.label,
            typeCounts,
            (s) => _setFilter(f.copyWith(types: s)),
          ),
          const SizedBox(height: 12),
          chipGroup<IssueArea>(
            'Data area',
            [
              for (final c in IssueArea.values)
                if (areaCounts.containsKey(c) || f.areas.contains(c)) c,
            ],
            f.areas,
            (c) => c.label,
            areaCounts,
            (s) => _setFilter(f.copyWith(areas: s)),
          ),
          const SizedBox(height: 16),
          dropdowns,
          const SizedBox(height: 16),
          TextField(
            controller: _search,
            onChanged: _onSearchChanged,
            decoration: const InputDecoration(
              labelText: 'Search',
              helperText: 'Matches the title, room, building, device or control name and explanation',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text(
                'Showing ${fmt.count(filtered.length)} of ${fmt.count(a.issues.length)} issues',
                style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: f.isDefault ? null : _clearFilters,
                    icon: const Icon(Icons.filter_alt_off_outlined),
                    label: const Text('Clear filters'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: filtered.isEmpty
                        ? null
                        : () => copyWithConfirmation(
                            context,
                            issuesToCsv(filtered),
                            '${filtered.length} ${filtered.length == 1 ? 'issue' : 'issues'} copied to the clipboard as CSV.',
                          ),
                    icon: const Icon(Icons.copy_all_outlined),
                    label: Text('Copy ${fmt.count(filtered.length)} as CSV'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _noMatches(BuildContext context) => EmptyState(
    icon: Icons.filter_alt_off_outlined,
    title: 'No issues match these filters',
    message: 'Remove a filter or clear them all to see more issues.',
    action: OutlinedButton.icon(
      onPressed: _clearFilters,
      icon: const Icon(Icons.filter_alt_off_outlined),
      label: const Text('Clear filters'),
    ),
  );
}
