import 'package:csv/csv.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/motion.dart';
import 'section_header.dart';
import 'status_widgets.dart';

/// A column of a [ChartTable].
@immutable
class ChartColumn {
  const ChartColumn(this.label, {this.numeric = false, this.tooltip});

  final String label;

  /// Right-aligns the column and sorts numerically.
  final bool numeric;
  final String? tooltip;
}

/// The data behind a chart, shown as a real table ("View as table") and
/// exported by "Copy as CSV". Give it the SAME numbers as the chart.
///
/// [rows] hold display strings (format numbers with `Fmt`); [rawRows]
/// optionally hold unformatted values for CSV export (defaults to [rows]).
@immutable
class ChartTable {
  const ChartTable({
    required this.columns,
    required this.rows,
    this.rawRows,
    this.caption,
  });

  final List<ChartColumn> columns;
  final List<List<String>> rows;
  final List<List<Object?>>? rawRows;

  /// Short description announced before the table.
  final String? caption;

  bool get isEmpty => rows.isEmpty;

  /// RFC 4180 CSV with a header row (formula-injection safe: cells starting
  /// with = + - @ are prefixed with an apostrophe for spreadsheet safety).
  String toCsv() {
    final data = <List<Object?>>[
      [for (final c in columns) c.label],
      ...(rawRows ?? rows),
    ];
    return Csv(lineDelimiter: '\n').encode([
      for (final row in data) [for (final cell in row) _safeCell(cell)]
    ]);
  }

  static Object? _safeCell(Object? cell) {
    if (cell is String && cell.isNotEmpty && '=+-@\t\r'.contains(cell[0])) {
      // Numbers such as "-3.5" are fine; only neutralise non-numeric text.
      if (num.tryParse(cell) == null) return "'$cell";
    }
    return cell;
  }
}

/// The label of a sortable [DataColumn]. Flutter's data table exposes a
/// column header with a tap action but says nothing about sorting, so this
/// adds the sort state to the accessible name ("Room, sorted ascending")
/// and a hint, while showing only [label] (WCAG 1.3.1 / 4.1.2).
class SortableColumnLabel extends StatelessWidget {
  const SortableColumnLabel({
    super.key,
    required this.label,
    required this.sorted,
    required this.ascending,
  });

  final String label;

  /// Whether the table is currently sorted by this column.
  final bool sorted;
  final bool ascending;

  /// "sorted ascending", "sorted descending" or "not sorted".
  static String stateOf({required bool sorted, required bool ascending}) =>
      !sorted ? 'not sorted' : (ascending ? 'sorted ascending' : 'sorted descending');

  /// The announcement after a re-sort.
  static String announcement(String label, bool ascending) =>
      'Sorted by $label, ${ascending ? 'ascending' : 'descending'}.';

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label, ${stateOf(sorted: sorted, ascending: ascending)}',
      hint: sorted ? 'Activate to reverse the order' : 'Activate to sort by this column',
      excludeSemantics: true,
      child: Text(label),
    );
  }
}

/// A dashboard card for one chart, accessible by construction:
///
/// * [title] is a heading; [description] explains what is plotted;
/// * the chart is exposed to screen readers as ONE node whose label is
///   [summary], a plain-language statement of the key finding, e.g.
///   "PC was selected most often: 42% of 1,204 selections";
/// * "View as table" swaps the chart for a real [DataTable] with the same
///   numbers (keyboard and screen reader friendly), "Copy as CSV" copies the
///   data to the clipboard;
/// * the swap animates only when motion is allowed.
///
/// ```dart
/// AccessibleChartCard(
///   title: 'Source share',
///   description: 'Share of source selections, all rooms',
///   summary: 'PC was used most: 42% of selections.',
///   chart: PieChart(...),
///   legend: PatternLegend(items: ...),
///   table: ChartTable(
///     columns: const [ChartColumn('Source'), ChartColumn('Selections', numeric: true)],
///     rows: [['PC', '506'], ['HDMI', '211']],
///   ),
/// )
/// ```
class AccessibleChartCard extends StatefulWidget {
  const AccessibleChartCard({
    super.key,
    required this.title,
    required this.summary,
    required this.chart,
    required this.table,
    this.description,
    this.legend,
    this.actions = const [],
    this.chartHeight = 280,
    this.initiallyShowTable = false,
    this.footer,
  });

  final String title;
  final String? description;

  /// Plain-language key finding read by screen readers instead of the chart.
  final String summary;
  final Widget chart;
  final ChartTable table;

  /// Usually a [PatternLegend], shown under the chart.
  final Widget? legend;

  /// Extra controls shown in the header (e.g. a SegmentedButton to switch
  /// between counts and time).
  final List<Widget> actions;

  /// Height of the chart area. Charts scale; text elsewhere wraps freely.
  final double chartHeight;
  final bool initiallyShowTable;

  /// Optional notes under the chart (assumptions, data caveats).
  final Widget? footer;

  @override
  State<AccessibleChartCard> createState() => _AccessibleChartCardState();
}

class _AccessibleChartCardState extends State<AccessibleChartCard> {
  late bool _showTable = widget.initiallyShowTable;

  Future<void> _copyCsv() async {
    await Clipboard.setData(ClipboardData(text: widget.table.toCsv()));
    if (!mounted) return;
    const message = 'Table copied to the clipboard as CSV.';
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text(message)));
    announce(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final motion = Motion.of(context);

    final header = Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 160),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Heading(widget.title, level: HeadingLevel.subsection),
              if (widget.description != null) ...[
                const SizedBox(height: 2),
                Text(widget.description!,
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        ),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ...widget.actions,
            Tooltip(
              message: _showTable ? 'Show the chart' : 'Show the data as a table',
              child: TextButton.icon(
                onPressed: () => setState(() => _showTable = !_showTable),
                icon: Icon(_showTable ? Icons.insert_chart_outlined : Icons.table_chart_outlined),
                label: Text(_showTable ? 'View as chart' : 'View as table'),
              ),
            ),
            IconButton(
              onPressed: widget.table.isEmpty ? null : _copyCsv,
              icon: const Icon(Icons.copy_all_outlined),
              tooltip: 'Copy the data as CSV',
            ),
          ],
        ),
      ],
    );

    final chartView = Column(
      key: const ValueKey('chart'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          image: true,
          label: '${widget.title}. ${widget.summary}',
          hint: 'Use View as table for the exact values.',
          excludeSemantics: true,
          child: SizedBox(height: widget.chartHeight, child: widget.chart),
        ),
        if (widget.legend != null) ...[
          const SizedBox(height: 12),
          widget.legend!,
        ],
      ],
    );

    final tableView = KeyedSubtree(
      key: const ValueKey('table'),
      child: _ChartDataTable(table: widget.table, title: widget.title),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            const SizedBox(height: 8),
            // Visible summary too: helps everyone, not just screen readers.
            ExcludeSemantics(
              child: Text(widget.summary,
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: motion.medium,
              switchInCurve: motion.curve,
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [...previous, ?current],
              ),
              child: _showTable ? tableView : chartView,
            ),
            if (widget.footer != null) ...[
              const SizedBox(height: 12),
              DefaultTextStyle.merge(
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                child: widget.footer!,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ChartDataTable extends StatefulWidget {
  const _ChartDataTable({required this.table, required this.title});

  final ChartTable table;
  final String title;

  @override
  State<_ChartDataTable> createState() => _ChartDataTableState();
}

class _ChartDataTableState extends State<_ChartDataTable> {
  int? _sortColumn;
  bool _ascending = true;
  final ScrollController _horizontal = ScrollController();

  /// Very long tables are paged so the UI stays responsive.
  static const int _pageSize = 200;
  int _visible = _pageSize;

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  List<int> _order() {
    final rows = widget.table.rows;
    final idx = List<int>.generate(rows.length, (i) => i);
    final col = _sortColumn;
    if (col == null) return idx;
    final numeric = widget.table.columns[col].numeric;
    final raw = widget.table.rawRows;
    int compare(int a, int b) {
      int result;
      if (numeric) {
        num? va = raw != null && raw[a][col] is num ? raw[a][col] as num : _parseNum(rows[a][col]);
        num? vb = raw != null && raw[b][col] is num ? raw[b][col] as num : _parseNum(rows[b][col]);
        result = (va ?? double.negativeInfinity).compareTo(vb ?? double.negativeInfinity);
      } else {
        result = rows[a][col].toLowerCase().compareTo(rows[b][col].toLowerCase());
      }
      return _ascending ? result : -result;
    }

    idx.sort(compare);
    return idx;
  }

  static num? _parseNum(String s) =>
      num.tryParse(s.replaceAll(RegExp(r'[^0-9.\-]'), ''));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final table = widget.table;
    if (table.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text('No data for the current filters.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface)),
      );
    }
    final order = _order();
    final shown = order.take(_visible).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (table.caption != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(table.caption!,
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ),
        Semantics(
          label: '${widget.title} data table, ${table.rows.length} rows',
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
                columns: [
                  for (var c = 0; c < table.columns.length; c++)
                    DataColumn(
                      label: SortableColumnLabel(
                        label: table.columns[c].label,
                        sorted: _sortColumn == c,
                        ascending: _ascending,
                      ),
                      numeric: table.columns[c].numeric,
                      tooltip: table.columns[c].tooltip,
                      onSort: (i, asc) {
                        setState(() {
                          _sortColumn = i;
                          _ascending = asc;
                        });
                        announce(context, SortableColumnLabel.announcement(table.columns[i].label, asc));
                      },
                    ),
                ],
                rows: [
                  for (final r in shown)
                    DataRow(cells: [
                      for (final cell in table.rows[r]) DataCell(Text(cell)),
                    ]),
                ],
              ),
            ),
          ),
        ),
        if (_visible < order.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => setState(() => _visible += _pageSize),
              child: Text('Show more rows (${order.length - _visible} remaining)'),
            ),
          ),
      ],
    );
  }
}
