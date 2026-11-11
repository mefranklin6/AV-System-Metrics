import 'package:flutter/material.dart';

import '../theme/motion.dart';

/// Direction of a change, shown with an arrow icon AND words (never colour
/// alone).
enum KpiTrend { up, down, flat }

/// A headline number on a dashboard card.
///
/// Screen readers hear one merged phrase: "[label]: [value]. [caption].
/// [trendLabel]". The value animates in (gated by reduce motion).
///
/// ```dart
/// KpiTile(
///   label: 'Rooms in use today',
///   value: fmt.count(18),
///   icon: Icons.meeting_room,
///   caption: 'of 24 rooms',
///   trend: KpiTrend.up,
///   trendLabel: 'Up 12% on last week',
/// )
/// ```
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.caption,
    this.trend,
    this.trendLabel,
    this.onTap,
    this.tooltip,
  });

  final String label;

  /// Already formatted value (use `Fmt`).
  final String value;
  final IconData? icon;
  final String? caption;
  final KpiTrend? trend;

  /// Words describing [trend], e.g. "Up 12% on last week".
  final String? trendLabel;

  /// Optional drill-down; the tile becomes a button.
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final motion = Motion.of(context);
    final semanticsLabel = [
      '$label: $value',
      ?caption,
      ?trendLabel,
    ].join('. ');

    final content = Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(label,
                    style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
              if (icon != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 20, color: cs.onPrimaryContainer),
                ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedSwitcher(
            duration: motion.medium,
            switchInCurve: motion.curve,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.15), end: Offset.zero)
                    .animate(animation),
                child: child,
              ),
            ),
            child: Text(
              value,
              key: ValueKey(value),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: 4),
            Text(caption!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ],
          if (trend != null || trendLabel != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (trend != null)
                  Icon(
                    switch (trend!) {
                      KpiTrend.up => Icons.arrow_upward,
                      KpiTrend.down => Icons.arrow_downward,
                      KpiTrend.flat => Icons.arrow_forward,
                    },
                    size: 18,
                    color: cs.onSurface,
                  ),
                if (trendLabel != null) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(trendLabel!,
                        style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );

    // The card is one semantics node: the merged label below plus, when
    // activatable, the InkWell's tap action and its focusable/focused flags
    // (so screen readers follow keyboard focus onto the tile). Only the
    // visual children are excluded, never the InkWell's own semantics.
    final labelled = Semantics(
      button: onTap != null,
      label: semanticsLabel,
      child: ExcludeSemantics(child: content),
    );
    final card = Card(
      semanticContainer: true,
      child: onTap == null ? labelled : InkWell(onTap: onTap, child: labelled),
    );
    return tooltip == null ? card : Tooltip(message: tooltip!, child: card);
  }
}
