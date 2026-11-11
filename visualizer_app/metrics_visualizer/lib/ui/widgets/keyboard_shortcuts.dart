import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/navigation_state.dart';

/// Opens the CSV file picker.
class OpenCsvIntent extends Intent {
  const OpenCsvIntent();
}

/// Shows a top-level page.
class GoToDestinationIntent extends Intent {
  const GoToDestinationIntent(this.destination);
  final AppDestination destination;
}

/// Moves keyboard focus to the main content (skip navigation).
class SkipToContentIntent extends Intent {
  const SkipToContentIntent();
}

/// Global shortcuts. Both Ctrl (Windows/Linux/web) and Cmd (macOS) work.
/// None are single printable keys, so they never clash with typing or
/// screen reader quick-navigation keys (WCAG 2.1.4).
Map<ShortcutActivator, Intent> buildAppShortcuts() {
  final map = <ShortcutActivator, Intent>{};
  void both(LogicalKeyboardKey key, Intent intent) {
    map[SingleActivator(key, control: true)] = intent;
    map[SingleActivator(key, meta: true)] = intent;
  }

  both(LogicalKeyboardKey.keyO, const OpenCsvIntent());
  both(LogicalKeyboardKey.comma, const GoToDestinationIntent(AppDestination.settings));
  both(LogicalKeyboardKey.keyD, const GoToDestinationIntent(AppDestination.dataSource));
  const digits = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
  ];
  final analysis = AppDestination.values.where((d) => d.isAnalysis).toList();
  for (var i = 0; i < analysis.length && i < digits.length; i++) {
    both(digits[i], GoToDestinationIntent(analysis[i]));
  }
  map[const SingleActivator(LogicalKeyboardKey.f6)] = const SkipToContentIntent();
  return map;
}

/// Human-readable list for Settings and About.
List<(String keys, String action)> describeAppShortcuts() {
  final analysis = AppDestination.values.where((d) => d.isAnalysis).toList();
  return [
    ('Ctrl+O', 'Open a CSV export'),
    ('Ctrl+D', 'Data source page'),
    ('Ctrl+,', 'Settings'),
    for (var i = 0; i < analysis.length && i < 8; i++) ('Ctrl+${i + 1}', analysis[i].label),
    ('F6', 'Move focus to the main content'),
    ('Tab / Shift+Tab', 'Move between controls'),
    ('Enter / Space', 'Activate the focused control'),
    ('Esc', 'Close dialogs and menus'),
  ];
}

/// A two-column, accessible table of the shortcuts.
class ShortcutList extends StatelessWidget {
  const ShortcutList({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (keys, action) in describeAppShortcuts())
          Semantics(
            label: '$keys: $action',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: cs.outline),
                    ),
                    child: Text(keys,
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: cs.onSurface, fontFamily: 'monospace',
                            fontFamilyFallback: const ['Consolas', 'Menlo'])),
                  ),
                  Text(action, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
