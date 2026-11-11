import 'package:flutter/material.dart';

/// Arrow icons for [DropdownMenu]s. When the menu's field accepts typing
/// (`requestFocusOnTap`, the default on desktop and web), Flutter exposes the
/// trailing arrow as a separate button with no accessible name. These icons
/// carry one (WCAG 4.1.2). [AppDropdownMenu] always uses them.
const Widget menuOpenIcon = Icon(Icons.arrow_drop_down, semanticLabel: 'Show the list');

/// See [menuOpenIcon].
const Widget menuCloseIcon = Icon(Icons.arrow_drop_up, semanticLabel: 'Hide the list');

/// The app's [DropdownMenu]: a labelled menu whose arrow button always has an
/// accessible name, whatever the platform default for typing is. Use it
/// instead of [DropdownMenu] everywhere.
///
/// Leave [requestFocusOnTap] null for the platform default (typing on
/// desktop and web, a plain menu button on touch devices). Set it to true
/// with [enableFilter] for long, searchable lists.
class AppDropdownMenu<T> extends StatelessWidget {
  const AppDropdownMenu({
    super.key,
    required this.label,
    required this.entries,
    required this.onSelected,
    this.initialSelection,
    this.width,
    this.helperText,
    this.enableFilter = false,
    this.requestFocusOnTap,
    this.menuHeight,
  });

  /// Visible label of the field (also its accessible name).
  final String label;
  final List<DropdownMenuEntry<T>> entries;
  final ValueChanged<T?> onSelected;
  final T? initialSelection;
  final double? width;
  final String? helperText;
  final bool enableFilter;
  final bool? requestFocusOnTap;
  final double? menuHeight;

  @override
  Widget build(BuildContext context) {
    return DropdownMenu<T>(
      width: width,
      label: Text(label),
      helperText: helperText,
      initialSelection: initialSelection,
      enableFilter: enableFilter,
      requestFocusOnTap: requestFocusOnTap,
      trailingIcon: menuOpenIcon,
      selectedTrailingIcon: menuCloseIcon,
      menuHeight: menuHeight,
      dropdownMenuEntries: entries,
      onSelected: onSelected,
    );
  }
}
