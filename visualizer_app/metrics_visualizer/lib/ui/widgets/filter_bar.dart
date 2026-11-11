import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/settings_state.dart';
import 'formatters.dart';
import 'multi_select_dialog.dart';

/// "Demo campus · 24,153 events · 24 rooms", or "No data loaded".
String datasetSummary(AppState app, Fmt fmt) {
  final ds = app.dataset;
  return ds == null
      ? 'No data loaded'
      : '${ds.description} · ${fmt.count(ds.events.length)} events · ${fmt.count(app.rooms.length)} rooms';
}

/// Tells analysis pages where the shell wants the filters. When [inline] is
/// true (short windows, or narrow windows with large text) the shell does
/// not show the fixed [FilterBar]; [AnalysisPage] puts a compact one at the
/// top of its scrolling content instead, so the filters never take the
/// page's whole height (WCAG 1.4.10 Reflow).
class FilterBarPlacement extends InheritedWidget {
  const FilterBarPlacement({super.key, required this.inline, this.showDatasetSummary = false, required super.child});

  final bool inline;

  /// The app bar has no room for the dataset summary; show it with the
  /// filters.
  final bool showDatasetSummary;

  static FilterBarPlacement? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FilterBarPlacement>();

  @override
  bool updateShouldNotify(FilterBarPlacement oldWidget) =>
      inline != oldWidget.inline || showDatasetSummary != oldWidget.showDatasetSummary;
}

/// Date range, building and room filters for the analysis screens. Reads and
/// updates [AppState]; every control is a standard button or menu, so it is
/// fully keyboard and screen reader operable. The shell shows it above every
/// analysis screen (or [AnalysisPage] shows the [compact] form inline, see
/// [FilterBarPlacement]); screens do not need to add it themselves.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, this.compact = false, this.showDatasetSummary = false});

  /// One "Filters" button (opening a dialog with every filter) plus the
  /// analysed period, for small windows and large text.
  final bool compact;

  /// Also show the dataset summary (when the app bar has no room for it).
  final bool showDatasetSummary;

  /// Number of filters that differ from the defaults.
  static int activeCount(DashboardFilters filters) =>
      (filters.preset == DatePreset.all ? 0 : 1) +
      (filters.buildings.isEmpty ? 0 : 1) +
      (filters.rooms.isEmpty ? 0 : 1);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final ds = app.dataset;
    if (ds == null || app.window == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);

    final Widget body;
    if (compact) {
      final active = activeCount(app.filters);
      body = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.tonalIcon(
            onPressed: () => showFilterDialog(context),
            icon: const Icon(Icons.filter_list),
            label: Text(active == 0 ? 'Filters' : 'Filters ($active active)'),
          ),
          const _FilterStatus(),
          if (showDatasetSummary)
            Text(datasetSummary(app, fmt), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      );
    } else {
      body = Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ...filterControls(context),
          const _FilterStatus(),
          if (showDatasetSummary)
            Text(datasetSummary(app, fmt), style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      );
    }

    return Semantics(
      container: true,
      label: 'Filters',
      explicitChildNodes: true,
      child: Material(
        color: cs.surfaceContainer,
        borderRadius: compact ? BorderRadius.circular(12) : null,
        child: Padding(
          padding: compact ? const EdgeInsets.all(8) : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: body,
        ),
      ),
    );
  }

  /// Every filter control, in reading order. [inDialog] lists the date
  /// presets as radio buttons instead of a pop-up menu (a menu can be wider
  /// than a 320 px window at large text sizes).
  static List<Widget> filterControls(BuildContext context, {bool inDialog = false}) {
    final app = context.watch<AppState>();
    final filters = app.filters;
    final buildingLabel = filters.buildings.isEmpty
        ? 'All buildings'
        : filters.buildings.length == 1
        ? filters.buildings.first
        : '${filters.buildings.length} buildings';
    final roomCount = app.selectedClients?.length ?? app.rooms.length;
    final roomLabel = filters.rooms.isEmpty
        ? (filters.buildings.isEmpty ? 'All rooms' : 'All $roomCount rooms')
        : filters.rooms.length == 1
        ? filters.rooms.first
        : '${filters.rooms.length} rooms';
    return [
      if (inDialog) _DatePresetRadios(current: filters.preset) else _DatePresetMenu(current: filters.preset),
      if (filters.preset == DatePreset.custom)
        OutlinedButton.icon(
          onPressed: () => pickCustomRange(context),
          icon: const Icon(Icons.edit_calendar_outlined),
          label: const Text('Edit dates'),
        ),
      OutlinedButton.icon(
        onPressed: app.buildings.isEmpty
            ? null
            : () async {
                final result = await showMultiSelectDialog(
                  context: context,
                  title: 'Choose buildings',
                  options: app.buildings,
                  selected: filters.buildings,
                  subtitleOf: (b) => '${app.roomsIn(b).length} rooms',
                );
                if (result != null) app.setBuildings(result);
              },
        icon: const Icon(Icons.apartment_outlined),
        label: Text('Buildings: $buildingLabel'),
      ),
      OutlinedButton.icon(
        onPressed: app.selectableRooms.isEmpty
            ? null
            : () async {
                final result = await showMultiSelectDialog(
                  context: context,
                  title: 'Choose rooms',
                  options: app.selectableRooms,
                  selected: filters.rooms,
                  subtitleOf: app.buildingOf,
                );
                if (result != null) app.setRooms(result);
              },
        icon: const Icon(Icons.meeting_room_outlined),
        label: Text('Rooms: $roomLabel'),
      ),
      if (!filters.isDefault)
        TextButton.icon(
          onPressed: app.clearFilters,
          icon: const Icon(Icons.filter_alt_off_outlined),
          label: const Text('Clear filters'),
        ),
    ];
  }

  /// Opens every filter in a scrollable dialog (the [compact] bar's button).
  /// Changes apply immediately, as in the full bar.
  static Future<void> showFilterDialog(BuildContext context) =>
      showDialog<void>(context: context, builder: (context) => const _FilterDialog());

  /// Opens the date range picker and applies the chosen whole days.
  static Future<void> pickCustomRange(BuildContext context) async {
    final app = context.read<AppState>();
    final ds = app.dataset;
    if (ds == null) return;
    final utc = context.read<SettingsState>().timeDisplay == TimeDisplay.utc;
    DateTime toDisplay(DateTime t) => utc ? t.toUtc() : t.toLocal();
    DateTime dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
    final first = dayOf(toDisplay(ds.rangeStart));
    final last = dayOf(toDisplay(ds.rangeEnd.subtract(const Duration(microseconds: 1))));
    final current = app.window!;
    var initStart = dayOf(toDisplay(current.start));
    var initEnd = dayOf(toDisplay(current.end.subtract(const Duration(microseconds: 1))));
    if (initStart.isBefore(first)) initStart = first;
    if (initEnd.isAfter(last)) initEnd = last;
    if (initEnd.isBefore(initStart)) initEnd = initStart;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDateRange: DateTimeRange(start: initStart, end: initEnd),
      helpText: 'Choose the dates to analyse',
      saveText: 'Apply',
      // Calendar first, with the switch to typed dates available
      // (no dragging needed, WCAG 2.5.7).
      initialEntryMode: DatePickerEntryMode.calendar,
    );
    if (picked == null) return;
    DateTime boundary(DateTime day) =>
        utc ? DateTime.utc(day.year, day.month, day.day) : DateTime(day.year, day.month, day.day).toUtc();
    final endDay = picked.end.add(const Duration(days: 1));
    app.setCustomWindow(boundary(picked.start), boundary(DateTime(endDay.year, endDay.month, endDay.day)));
  }
}

/// The analysed period ("Sep 1, 2026 – Nov 9, 2026"), or "Updating…" while
/// the analysis reruns. A live region, so changes are announced.
class _FilterStatus extends StatelessWidget {
  const _FilterStatus();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final window = app.window;
    if (window == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final fmt = Fmt.of(context);
    final lastDay = window.end.subtract(const Duration(microseconds: 1));
    return Semantics(
      liveRegion: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (app.isAnalyzing) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: ExcludeSemantics(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              app.isAnalyzing ? 'Updating…' : '${fmt.date(window.start)} – ${fmt.date(lastDay)}',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterDialog extends StatelessWidget {
  const _FilterDialog();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final short = MediaQuery.sizeOf(context).height < 480;
    return AlertDialog(
      title: const Text('Filters'),
      scrollable: true,
      insetPadding: short
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      content: app.dataset == null
          ? const Text('No data loaded.')
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final c in FilterBar.filterControls(context, inDialog: true))
                  Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
                const _FilterStatus(),
              ],
            ),
      actions: [FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
    );
  }
}

/// The date presets as a labelled radio group (used in the filter dialog).
class _DatePresetRadios extends StatelessWidget {
  const _DatePresetRadios({required this.current});

  final DatePreset current;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: 'Dates',
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Dates', style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface)),
          RadioGroup<DatePreset>(
            groupValue: current,
            onChanged: (p) async {
              if (p == null) return;
              if (p == DatePreset.custom) {
                await FilterBar.pickCustomRange(context);
              } else {
                app.setDatePreset(p);
              }
            },
            child: Column(
              children: [
                for (final p in DatePreset.values)
                  RadioListTile<DatePreset>(
                    value: p,
                    contentPadding: EdgeInsets.zero,
                    title: Text(p.label),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DatePresetMenu extends StatelessWidget {
  const _DatePresetMenu({required this.current});

  final DatePreset current;

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return MenuAnchor(
      menuChildren: [
        for (final p in DatePreset.values)
          MenuItemButton(
            leadingIcon: Icon(p == current ? Icons.radio_button_checked : Icons.radio_button_unchecked),
            onPressed: () async {
              if (p == DatePreset.custom) {
                await FilterBar.pickCustomRange(context);
              } else {
                app.setDatePreset(p);
              }
            },
            child: Semantics(selected: p == current, child: Text(p.label)),
          ),
      ],
      builder: (context, controller, _) => FilledButton.tonalIcon(
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: const Icon(Icons.date_range_outlined),
        label: Text('Dates: ${current.label}'),
      ),
    );
  }
}
