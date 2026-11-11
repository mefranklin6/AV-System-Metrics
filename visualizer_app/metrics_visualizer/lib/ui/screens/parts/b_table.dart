// A sortable, paged data table for list-style content (event logs, device
// tables) on the Connectivity, Issues and Forecast screens.

import 'package:flutter/material.dart';

import '../../widgets/widgets.dart';

/// A real [DataTable] (keyboard and screen reader friendly) that:
/// * sorts by any column (numeric columns by their [sortKeys]);
/// * scrolls horizontally on narrow windows instead of clipping;
/// * shows [pageSize] rows at a time with a "Show more rows" button so very
///   long lists stay responsive.
class SortableTable extends StatefulWidget {
  const SortableTable({
    super.key,
    required this.label,
    required this.columns,
    required this.rows,
    this.sortKeys,
    this.initialSortColumn,
    this.initialAscending = true,
    this.pageSize = 100,
    this.emptyMessage = 'No rows for the current filters.',
  });

  /// Accessible name, e.g. "Connection events".
  final String label;
  final List<ChartColumn> columns;

  /// Display strings, one list per row.
  final List<List<String>> rows;

  /// Optional sort values per cell (num, DateTime, String or null). Nulls
  /// always sort last. Defaults to the display strings.
  final List<List<Comparable<dynamic>?>>? sortKeys;
  final int? initialSortColumn;
  final bool initialAscending;
  final int pageSize;
  final String emptyMessage;

  @override
  State<SortableTable> createState() => _SortableTableState();
}

class _SortableTableState extends State<SortableTable> {
  late int? _sortColumn = widget.initialSortColumn;
  late bool _ascending = widget.initialAscending;
  late int _visible = widget.pageSize;
  final ScrollController _horizontal = ScrollController();

  @override
  void didUpdateWidget(SortableTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rows.length != widget.rows.length) _visible = widget.pageSize;
    if (_sortColumn != null && _sortColumn! >= widget.columns.length) _sortColumn = null;
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  Comparable<dynamic>? _key(int row, int col) {
    final keys = widget.sortKeys;
    if (keys != null) return keys[row][col];
    return widget.rows[row][col].toLowerCase();
  }

  List<int> _order() {
    final idx = List<int>.generate(widget.rows.length, (i) => i);
    final col = _sortColumn;
    if (col == null) return idx;
    idx.sort((a, b) {
      final ka = _key(a, col), kb = _key(b, col);
      if (ka == null && kb == null) return a.compareTo(b);
      if (ka == null) return 1; // nulls last in both directions
      if (kb == null) return -1;
      final c = ka is String && kb is String
          ? ka.toLowerCase().compareTo(kb.toLowerCase())
          : ka.compareTo(kb);
      if (c == 0) return a.compareTo(b);
      return _ascending ? c : -c;
    });
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    if (widget.rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(widget.emptyMessage, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
      );
    }
    final order = _order();
    final shown = order.take(_visible).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label: '${widget.label} table, ${widget.rows.length} rows',
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
                columnSpacing: 28,
                columns: [
                  for (var c = 0; c < widget.columns.length; c++)
                    DataColumn(
                      label: SortableColumnLabel(
                        label: widget.columns[c].label,
                        sorted: _sortColumn == c,
                        ascending: _ascending,
                      ),
                      numeric: widget.columns[c].numeric,
                      tooltip: widget.columns[c].tooltip ?? 'Sort by ${widget.columns[c].label}',
                      onSort: (i, asc) {
                        setState(() {
                          _sortColumn = i;
                          _ascending = asc;
                        });
                        announce(context, SortableColumnLabel.announcement(widget.columns[i].label, asc));
                      },
                    ),
                ],
                rows: [
                  for (final r in shown)
                    DataRow(cells: [for (final cell in widget.rows[r]) DataCell(Text(cell))]),
                ],
              ),
            ),
          ),
        ),
        if (_visible < order.length)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(
              onPressed: () => setState(() => _visible += widget.pageSize),
              child: Text('Show more rows (${order.length - _visible} remaining)'),
            ),
          ),
      ],
    );
  }
}
