import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lays [children] out in as many equal-width columns as fit, each at least
/// [minChildWidth] wide, wrapping to one column on narrow screens (reflow,
/// WCAG 1.4.10). Children keep their natural height, so text can grow with
/// the text-size setting without clipping.
///
/// A child can span several columns by wrapping it in [GridSpan].
///
/// ```dart
/// ResponsiveGrid(
///   minChildWidth: 220,
///   children: [KpiTile(...), KpiTile(...), GridSpan(columns: 2, child: chartCard)],
/// )
/// ```
class ResponsiveGrid extends StatelessWidget {
  const ResponsiveGrid({
    super.key,
    required this.children,
    this.minChildWidth = 360,
    this.spacing = 16,
    this.runSpacing = 16,
    this.maxColumns = 4,
  });

  final List<Widget> children;
  final double minChildWidth;
  final double spacing;
  final double runSpacing;
  final int maxColumns;

  /// Number of columns that fit in [width].
  static int columnsFor(double width, double minChildWidth, double spacing, int maxColumns) {
    if (!width.isFinite || width <= 0) return 1;
    final n = ((width + spacing) / (minChildWidth + spacing)).floor();
    return n.clamp(1, math.max(1, maxColumns));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = columnsFor(width, minChildWidth, spacing, maxColumns);
      // Floor to whole pixels so rounding never pushes the last cell to a new row.
      final cell = columns == 1
          ? width
          : ((width - spacing * (columns - 1)) / columns).floorToDouble();
      return Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        children: [
          for (final child in children)
            () {
              final span = child is GridSpan ? child.columns.clamp(1, columns) : 1;
              final w = cell * span + spacing * (span - 1);
              return SizedBox(
                width: w.isFinite ? w : null,
                child: child is GridSpan ? child.child : child,
              );
            }(),
        ],
      );
    });
  }
}

/// Makes a [ResponsiveGrid] child span [columns] columns (when available).
class GridSpan extends StatelessWidget {
  const GridSpan({super.key, required this.columns, required this.child});

  final int columns;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
