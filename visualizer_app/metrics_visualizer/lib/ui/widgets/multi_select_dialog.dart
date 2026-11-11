import 'package:flutter/material.dart';

/// Shows a searchable, keyboard-accessible multi-select dialog. Returns the
/// new selection, or null when cancelled. An empty selection means "all"
/// when [emptyMeansAll] is true (the dialog says so).
Future<Set<String>?> showMultiSelectDialog({
  required BuildContext context,
  required String title,
  required List<String> options,
  required Set<String> selected,
  String? Function(String option)? subtitleOf,
  bool emptyMeansAll = true,
}) {
  return showDialog<Set<String>>(
    context: context,
    builder: (_) => MultiSelectDialog(
      title: title,
      options: options,
      selected: selected,
      subtitleOf: subtitleOf,
      emptyMeansAll: emptyMeansAll,
    ),
  );
}

/// The dialog behind [showMultiSelectDialog].
class MultiSelectDialog extends StatefulWidget {
  const MultiSelectDialog({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    this.subtitleOf,
    this.emptyMeansAll = true,
  });

  final String title;
  final List<String> options;
  final Set<String> selected;
  final String? Function(String option)? subtitleOf;
  final bool emptyMeansAll;

  @override
  State<MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<MultiSelectDialog> {
  late final Set<String> _selected = {...widget.selected};
  String _query = '';

  List<String> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return [
      for (final o in widget.options)
        if (o.toLowerCase().contains(q) ||
            (widget.subtitleOf?.call(o)?.toLowerCase().contains(q) ?? false))
          o
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final filtered = _filtered;
    final count = _selected.length;
    final status = count == 0
        ? (widget.emptyMeansAll ? 'None selected: all are included.' : 'None selected.')
        : '$count selected.';
    // The search field, the selection controls and the options share ONE
    // scroll view, so options stay reachable however little height there is
    // (320 x 256 px at 400% zoom, or very large text: WCAG 1.4.10 / 1.4.4).
    final short = MediaQuery.sizeOf(context).height < 480;
    final header = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Search',
            prefixIcon: const Icon(Icons.search),
            // Saves a line when space is tight; the label says it all.
            helperText: short ? null : 'Type to narrow the list.',
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(status, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
            ),
            TextButton(
              onPressed: filtered.isEmpty ? null : () => setState(() => _selected.addAll(filtered)),
              child: Text(_query.isEmpty ? 'Select all' : 'Select matches'),
            ),
            TextButton(
              onPressed: _selected.isEmpty ? null : () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
          ],
        ),
        const Divider(),
      ],
    );
    return AlertDialog(
      title: Text(widget.title),
      insetPadding: short
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: short ? const EdgeInsets.fromLTRB(16, 12, 16, 0) : null,
      contentPadding: short ? const EdgeInsets.fromLTRB(16, 8, 16, 0) : const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: short ? const EdgeInsets.fromLTRB(16, 4, 16, 8) : null,
      content: SizedBox(
        width: 440,
        // Not lazy on purpose: every option exists, so Tab reaches all of
        // them even when only a few fit on screen.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (filtered.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('No matches.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
                )
              else
                for (final o in filtered)
                  CheckboxListTile(
                    value: _selected.contains(o),
                    title: Text(o),
                    subtitle: widget.subtitleOf?.call(o) == null ? null : Text(widget.subtitleOf!(o)!),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(o);
                      } else {
                        _selected.remove(o);
                      }
                    }),
                  ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(Set<String>.of(_selected)),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
