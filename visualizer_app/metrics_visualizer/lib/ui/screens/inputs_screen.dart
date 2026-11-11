import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../analytics/analytics.dart';
import '../widgets/widgets.dart';
import 'parts/a_cards.dart';
import 'parts/a_common.dart';

/// Which rooms the input charts cover.
enum InputScope {
  campus('Campus'),
  building('Building'),
  room('Room');

  const InputScope(this.label);

  final String label;
}

/// Source popularity: share by selections or by time on screen, for the
/// whole campus, one building or one room, plus a room x source matrix and
/// the least-used sources.
class InputsScreen extends StatefulWidget {
  const InputsScreen({super.key});

  @override
  State<InputsScreen> createState() => _InputsScreenState();
}

class _InputsScreenState extends State<InputsScreen> {
  InputScope _scope = InputScope.campus;
  InputMeasure _measure = InputMeasure.selections;
  String? _building;
  String? _room;

  @override
  Widget build(BuildContext context) => AnalysisPage(
    title: 'Sources',
    subtitle: 'Which sources are selected and how long they stay on screen.',
    builder: (context, analysis) {
      if (analysis.isEmpty) return noMatchingRooms(context);
      // Keep selections valid when filters change the available rooms.
      final building = analysis.buildings.contains(_building) ? _building! : analysis.buildings.first;
      final room = analysis.rooms.contains(_room) ? _room! : analysis.rooms.first;
      final styles = InputStyles(ChartPalette.of(context), analysis.inputs.campus);
      final (shares, scopeLabel, rooms) = switch (_scope) {
        InputScope.campus => (analysis.inputs.campus, 'all rooms', analysis.rooms),
        InputScope.building => (
          analysis.inputs.byBuilding[building] ?? const <InputShare>[],
          'building $building',
          analysis.roomsInBuilding(building),
        ),
        InputScope.room => (analysis.inputs.byRoom[room] ?? const <InputShare>[], 'room $room', [room]),
      };
      final underused = [
        for (final u in analysis.inputs.underused)
          if (switch (_scope) {
            InputScope.campus => true,
            InputScope.building => u.building == building,
            InputScope.room => u.room == room,
          })
            u,
      ];
      return [
        _Controls(
          scope: _scope,
          measure: _measure,
          buildings: analysis.buildings,
          rooms: analysis.rooms,
          building: building,
          room: room,
          onScope: (s) => setState(() => _scope = s),
          onMeasure: (m) => setState(() => _measure = m),
          onBuilding: (b) => setState(() => _building = b),
          onRoom: (r) => setState(() => _room = r),
        ),
        _ScopeKpis(
          shares: shares,
          underused: underused.length,
          scopeLabel: scopeLabel,
          automatic: automaticSelections(analysis, rooms),
        ),
        ResponsiveGrid(
          minChildWidth: 420,
          maxColumns: 2,
          children: [
            InputShareCard(shares: shares, measure: _measure, scopeLabel: scopeLabel, styles: styles),
            InputRankingCard(shares: shares, measure: _measure, scopeLabel: scopeLabel, styles: styles),
          ],
        ),
        _UnderusedCard(items: underused, scope: _scope, scopeLabel: scopeLabel),
        if (_scope != InputScope.room)
          _InputMatrixCard(
            key: ValueKey('matrix-${_scope.name}-$building-${_measure.name}'),
            analysis: analysis,
            rooms: rooms,
            scopeShares: shares,
            measure: _measure,
            scopeLabel: scopeLabel,
          ),
        _Methodology(automatic: automaticSelections(analysis, rooms), scopeLabel: scopeLabel),
      ];
    },
  );
}

/// Automatic startup selections (the program's default source at power-on)
/// in [rooms]. They are left out of the selection counts but their time on
/// screen is included.
int automaticSelections(AnalysisResult analysis, Iterable<String> rooms) =>
    rooms.fold(0, (n, r) => n + (analysis.sessions[r]?.automaticInputStarts.length ?? 0));

/// How selections and time on screen are counted.
class _Methodology extends StatelessWidget {
  const _Methodology({required this.automatic, required this.scopeLabel});

  final int automatic;
  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final style = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Text('•  ', style: style)),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
    return InfoCard(
      title: 'How sources are counted',
      icon: Icons.help_outline,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          bullet(
            'Selections: each source selection the room\'s program logged (a source event with "Started" or '
            '"Trace", as set under Settings > Event recognition).',
          ),
          bullet(
            'The default source a program selects by itself at power-on is not counted as a selection: '
            'it is the first source within ${SessionBuilder.startupSelectionWindow.inSeconds} seconds '
            'of power-on, or before the optional startup-complete trace (such as "System Startup Complete") '
            'when that follows within '
            '${SessionBuilder.startupTraceLimit.inMinutes} minutes. It still counts toward time on screen. '
            '${automatic == 0 ? 'There were no such startup selections in $scopeLabel in this period.' : 'In $scopeLabel, ${fmt.count(automatic)} startup ${automatic == 1 ? 'selection was' : 'selections were'} left out of the selection counts.'}',
          ),
          bullet(
            'Time on screen: from a source\'s selection until another source is selected, the source\'s '
            '"Stopped" event, the system powers off, a program start event, or the session reaches the '
            'longest believable session in Settings.',
          ),
          bullet(
            'Automatic startup selections are also left out of rapid source changes (Issues) and source trends (Forecast).',
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.scope,
    required this.measure,
    required this.buildings,
    required this.rooms,
    required this.building,
    required this.room,
    required this.onScope,
    required this.onMeasure,
    required this.onBuilding,
    required this.onRoom,
  });

  final InputScope scope;
  final InputMeasure measure;
  final List<String> buildings;
  final List<String> rooms;
  final String building;
  final String room;
  final ValueChanged<InputScope> onScope;
  final ValueChanged<InputMeasure> onMeasure;
  final ValueChanged<String> onBuilding;
  final ValueChanged<String> onRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface);
    Widget group(String title, Widget child) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: label),
        const SizedBox(height: 8),
        Semantics(label: title, container: true, explicitChildNodes: true, child: child),
      ],
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final menuWidth = math.min(320.0, constraints.maxWidth);
            return Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                group(
                  'Scope',
                  SegmentedButton<InputScope>(
                    segments: [for (final s in InputScope.values) ButtonSegment(value: s, label: Text(s.label))],
                    selected: {scope},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => onScope(s.first),
                  ),
                ),
                if (scope == InputScope.building)
                  AppDropdownMenu<String>(
                    key: const ValueKey('building-menu'),
                    width: menuWidth,
                    label: 'Building',
                    helperText: '${buildings.length} buildings',
                    initialSelection: building,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    entries: [for (final b in buildings) DropdownMenuEntry(value: b, label: b)],
                    onSelected: (b) {
                      if (b != null) onBuilding(b);
                    },
                  ),
                if (scope == InputScope.room)
                  AppDropdownMenu<String>(
                    key: const ValueKey('room-menu'),
                    width: menuWidth,
                    label: 'Room',
                    helperText: 'Type to search ${rooms.length} rooms',
                    initialSelection: room,
                    enableFilter: true,
                    requestFocusOnTap: true,
                    menuHeight: 360,
                    entries: [for (final r in rooms) DropdownMenuEntry(value: r, label: r)],
                    onSelected: (r) {
                      if (r != null) onRoom(r);
                    },
                  ),
                group(
                  'Measure',
                  SegmentedButton<InputMeasure>(
                    segments: [for (final m in InputMeasure.values) ButtonSegment(value: m, label: Text(m.label))],
                    selected: {measure},
                    showSelectedIcon: false,
                    onSelectionChanged: (m) => onMeasure(m.first),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ScopeKpis extends StatelessWidget {
  const _ScopeKpis({
    required this.shares,
    required this.underused,
    required this.scopeLabel,
    required this.automatic,
  });

  final List<InputShare> shares;
  final int underused;
  final String scopeLabel;

  /// Startup default selections left out of [shares]' selection counts.
  final int automatic;

  @override
  Widget build(BuildContext context) {
    final fmt = Fmt.of(context);
    final selections = shares.fold<int>(0, (s, i) => s + i.selections);
    final hours = shares.fold<double>(0, (s, i) => s + i.hours);
    return ResponsiveGrid(
      minChildWidth: 220,
      children: [
        KpiTile(label: 'Sources used', value: fmt.count(shares.length), icon: Icons.input, caption: 'in $scopeLabel'),
        KpiTile(
          label: 'Selections',
          value: fmt.count(selections),
          icon: Icons.touch_app_outlined,
          caption: automatic == 0
              ? 'source selections logged'
              : 'source selections logged; ${fmt.count(automatic)} startup '
                    '${automatic == 1 ? 'default' : 'defaults'} not counted',
        ),
        KpiTile(
          label: 'Time on screen',
          value: fmt.hours(hours),
          icon: Icons.tv_outlined,
          caption: 'total, all sources, startup default included',
        ),
        KpiTile(
          label: 'Least-used sources',
          value: fmt.count(underused),
          icon: Icons.savings_outlined,
          caption: 'rarely or never used',
        ),
      ],
    );
  }
}

class _UnderusedCard extends StatefulWidget {
  const _UnderusedCard({required this.items, required this.scope, required this.scopeLabel});

  final List<UnderusedInput> items;
  final InputScope scope;
  final String scopeLabel;

  @override
  State<_UnderusedCard> createState() => _UnderusedCardState();
}

class _UnderusedCardState extends State<_UnderusedCard> {
  static const int _initial = 8;
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final items = widget.items;
    final shown = _all ? items : items.take(_initial).toList();
    return InfoCard(
      title: 'Least-used sources',
      icon: Icons.savings_outlined,
      description:
          'Sources with under ${Fmt.of(context).percent(InputUsage.underusedShareThreshold)} of both '
          'selections and time, or with no selections in a room where other rooms in the same building '
          'select them. The data only shows sources that were selected, not what is installed.',
      child: items.isEmpty
          ? Text(
              'No least-used sources in ${widget.scopeLabel}: every source selected here has at least '
              '${Fmt.of(context).percent(InputUsage.underusedShareThreshold)} of selections or time.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final u in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          u.kind == UnderuseKind.neverUsedInRoom ? Icons.block_outlined : Icons.trending_down,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: u.room == null ? u.label : '${u.label} in ${u.room}',
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                TextSpan(text: ' (${u.kind.label}). '),
                                TextSpan(text: u.reason),
                              ],
                            ),
                            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (items.length > _initial)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => setState(() => _all = !_all),
                      child: Text(_all ? 'Show fewer' : 'Show all ${items.length} sources'),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Rooms x inputs: each cell is the input's share of that room's
/// selections (or time). Sortable, paged and copyable as CSV.
class _InputMatrixCard extends StatefulWidget {
  const _InputMatrixCard({
    super.key,
    required this.analysis,
    required this.rooms,
    required this.scopeShares,
    required this.measure,
    required this.scopeLabel,
  });

  final AnalysisResult analysis;
  final List<String> rooms;
  final List<InputShare> scopeShares;
  final InputMeasure measure;
  final String scopeLabel;

  @override
  State<_InputMatrixCard> createState() => _InputMatrixCardState();
}

class _InputMatrixCardState extends State<_InputMatrixCard> {
  static const int _pageSize = 50;
  final ScrollController _horizontal = ScrollController();
  int _visible = _pageSize;
  int? _sortColumn;
  bool _ascending = true;

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final m = widget.measure;
    final columns = sortInputs(widget.scopeShares, m).take(maxNamedSeries).toList();
    final hasOther = widget.scopeShares.length > columns.length;
    final keys = [for (final c in columns) c.key];

    // Matrix values: share per room per column, plus Other and Total.
    final rows = <_MatrixRow>[];
    for (final room in widget.rooms) {
      final shares = widget.analysis.inputs.byRoom[room] ?? const <InputShare>[];
      final total = shares.fold<double>(0, (s, i) => s + m.valueOf(i));
      final byKey = {for (final s in shares) s.key: m.valueOf(s)};
      final cells = [for (final k in keys) total <= 0 ? 0.0 : (byKey[k] ?? 0) / total];
      final named = keys.fold<double>(0, (s, k) => s + (byKey[k] ?? 0));
      rows.add(_MatrixRow(room, cells, total <= 0 ? 0 : (total - named) / total, total));
    }
    final sortCol = _sortColumn;
    if (sortCol != null) {
      int cmp(_MatrixRow a, _MatrixRow b) {
        final r = switch (sortCol) {
          0 => a.room.toLowerCase().compareTo(b.room.toLowerCase()),
          _ when sortCol <= keys.length => a.cells[sortCol - 1].compareTo(b.cells[sortCol - 1]),
          _ when hasOther && sortCol == keys.length + 1 => a.other.compareTo(b.other),
          _ => a.total.compareTo(b.total),
        };
        return _ascending ? r : -r;
      }

      rows.sort(cmp);
    }
    String totalText(double v) => m == InputMeasure.selections ? fmt.count(v) : fmt.hours(v);
    final headers = [
      'Room',
      for (final c in columns) c.label,
      if (hasOther) 'Other',
      m == InputMeasure.selections ? 'Total selections' : 'Total time',
    ];
    final csv = ChartTable(
      columns: [for (var i = 0; i < headers.length; i++) ChartColumn(headers[i], numeric: i > 0)],
      rows: const [],
      rawRows: [
        for (final r in rows) [r.room, ...r.cells, if (hasOther) r.other, r.total],
      ],
    );
    Widget shareCell(double v) => Container(
      constraints: const BoxConstraints(minWidth: 64),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      alignment: AlignmentDirectional.centerEnd,
      decoration: BoxDecoration(
        color: Color.lerp(cs.surfaceContainerLow, cs.primaryContainer, v.clamp(0.0, 1.0)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(fmt.percent(v), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
    );
    final shown = rows.take(_visible).toList();
    return InfoCard(
      title: 'Room by source matrix',
      icon: Icons.grid_on_outlined,
      description:
          'Share of each room\'s ${m.label.toLowerCase()} per source, ${widget.scopeLabel}. '
          'Shading repeats the percentage. Select a column heading to sort.',
      actions: [
        IconButton(
          tooltip: 'Copy the matrix as CSV',
          icon: const Icon(Icons.copy_all_outlined),
          onPressed: rows.isEmpty
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: csv.toCsv()));
                  if (!context.mounted) return;
                  const message = 'Matrix copied to the clipboard as CSV.';
                  ScaffoldMessenger.maybeOf(context)
                    ?..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text(message)));
                  announce(context, message);
                },
        ),
      ],
      child: rows.isEmpty
          ? Text('No rooms in this scope.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: 'Room by source matrix, ${rows.length} rooms, ${headers.length - 1} value columns',
                  container: true,
                  explicitChildNodes: true,
                  child: Scrollbar(
                    controller: _horizontal,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(bottom: 12),
                      child: DataTable(
                        sortColumnIndex: _sortColumn,
                        sortAscending: _ascending,
                        headingRowHeight: 56,
                        dataRowMinHeight: 48,
                        dataRowMaxHeight: double.infinity,
                        columnSpacing: 16,
                        columns: [
                          for (var i = 0; i < headers.length; i++)
                            DataColumn(
                              label: SortableColumnLabel(
                                label: headers[i],
                                sorted: _sortColumn == i,
                                ascending: _ascending,
                              ),
                              numeric: i > 0,
                              onSort: (c, asc) {
                                setState(() {
                                  _sortColumn = c;
                                  _ascending = asc;
                                });
                                announce(context, SortableColumnLabel.announcement(headers[c], asc));
                              },
                            ),
                        ],
                        rows: [
                          for (final r in shown)
                            DataRow(
                              cells: [
                                DataCell(Text(r.room)),
                                for (final v in r.cells) DataCell(shareCell(v)),
                                if (hasOther) DataCell(shareCell(r.other)),
                                DataCell(Text(totalText(r.total))),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_visible < rows.length)
                  OutlinedButton(
                    onPressed: () => setState(() => _visible += _pageSize),
                    child: Text('Show more rooms (${rows.length - _visible} remaining)'),
                  ),
              ],
            ),
    );
  }
}

class _MatrixRow {
  _MatrixRow(this.room, this.cells, this.other, this.total);

  final String room;
  final List<double> cells;
  final double other;
  final double total;
}
