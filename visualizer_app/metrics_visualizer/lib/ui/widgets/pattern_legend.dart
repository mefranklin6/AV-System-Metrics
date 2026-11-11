import 'package:flutter/material.dart';

import '../theme/chart_palette.dart';
import '../theme/chart_patterns.dart';

/// One legend entry.
@immutable
class LegendItem {
  const LegendItem({
    required this.label,
    required this.color,
    this.pattern = ChartPattern.solid,
    this.value,
  });

  /// Builds the item for series [index] from [palette].
  factory LegendItem.fromPalette(ChartPalette palette, int index, String label, {String? value}) =>
      LegendItem(
        label: label,
        color: palette.colorAt(index),
        pattern: palette.patternAt(index),
        value: value,
      );

  final String label;
  final Color color;
  final ChartPattern pattern;

  /// Optional formatted value shown after the label, e.g. "42%".
  final String? value;
}

/// A chart legend that does not rely on colour alone: every entry shows a
/// pattern swatch, a text label and (optionally) its value, and screen
/// readers hear "label, value, pattern name".
class PatternLegend extends StatelessWidget {
  const PatternLegend({
    super.key,
    required this.items,
    this.direction = Axis.horizontal,
  });

  final List<LegendItem> items;

  /// Horizontal wraps entries; vertical lists them one per line.
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = [
      for (final item in items)
        Semantics(
          label: [
            item.label,
            ?item.value,
            if (item.pattern != ChartPattern.solid) '${item.pattern.label} pattern',
          ].join(', '),
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PatternBox(color: item.color, pattern: item.pattern, width: 18, height: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: item.label),
                    if (item.value != null)
                      TextSpan(
                        text: '  ${item.value}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                  ]),
                  style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                ),
              ),
            ],
          ),
        ),
    ];
    return Semantics(
      container: true,
      label: 'Legend',
      explicitChildNodes: true,
      child: direction == Axis.horizontal
          ? Wrap(spacing: 16, runSpacing: 8, children: entries)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in entries)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: e),
              ],
            ),
    );
  }
}
