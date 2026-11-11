import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/navigation_state.dart';
import '../widgets/widgets.dart';
import 'parts/a_common.dart';
import 'parts/a_room_detail.dart';

/// How the room list is ordered.
enum RoomSort {
  name('Room name'),
  building('Building'),
  hours('System-on hours'),
  sessions('Sessions'),
  issues('Issues'),
  lastSeen('Last seen');

  const RoomSort(this.label);

  final String label;
}

/// One row of the room list: the engine's summary plus the latest time the
/// room was heard from (event or heartbeat).
@immutable
class RoomListEntry {
  const RoomListEntry(this.summary, this.lastSeen);

  final RoomSummary summary;
  final DateTime? lastSeen;
}

/// Filters [entries] by [query] (room or building, case-insensitive) and
/// sorts them. Pure, so it is unit-tested directly.
List<RoomListEntry> filterAndSortRooms(
  List<RoomListEntry> entries, {
  required String query,
  required RoomSort sort,
  required bool ascending,
}) {
  final q = query.trim().toLowerCase();
  final list = [
    for (final e in entries)
      if (q.isEmpty || e.summary.room.toLowerCase().contains(q) || e.summary.building.toLowerCase().contains(q)) e,
  ];
  int byName(RoomListEntry a, RoomListEntry b) => a.summary.room.toLowerCase().compareTo(b.summary.room.toLowerCase());
  int cmp(RoomListEntry a, RoomListEntry b) {
    final r = switch (sort) {
      RoomSort.name => byName(a, b),
      RoomSort.building => a.summary.building.compareTo(b.summary.building),
      RoomSort.hours => a.summary.systemHours.compareTo(b.summary.systemHours),
      RoomSort.sessions => a.summary.systemSessions.compareTo(b.summary.systemSessions),
      RoomSort.issues => a.summary.issueTotal.compareTo(b.summary.issueTotal),
      RoomSort.lastSeen => (a.lastSeen?.microsecondsSinceEpoch ?? -1).compareTo(
        b.lastSeen?.microsecondsSinceEpoch ?? -1,
      ),
    };
    if (r != 0) return ascending ? r : -r;
    return byName(a, b);
  }

  return list..sort(cmp);
}

/// Searchable, sortable room list with a per-room drill-down: side by side
/// on wide windows, list then detail (with a Back button, Escape or the
/// system back gesture) on narrow ones.
class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key});

  /// Content widths from here show the list and the detail side by side.
  static const double masterDetailWidth = 960;

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  final TextEditingController _query = TextEditingController();
  RoomSort _sort = RoomSort.name;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnalysisPage(
    title: 'Rooms',
    subtitle: 'Find a room and see how it is used.',
    builder: (context, analysis) {
      if (analysis.isEmpty) return noMatchingRooms(context);
      final selected = context.select<NavigationState, String?>((n) => n.selectedRoom);
      final lastSeen = {for (final c in analysis.connectivity.rooms) c.room: c.lastSeen};
      final entries = [
        for (final s in analysis.roomSummaries) RoomListEntry(s, _latest(s.lastEvent, lastSeen[s.room])),
      ];
      final shown = filterAndSortRooms(entries, query: _query.text, sort: _sort, ascending: _ascending);
      final controls = _ListControls(
        query: _query,
        sort: _sort,
        ascending: _ascending,
        shown: shown.length,
        total: entries.length,
        onSort: (s) => setState(() {
          _sort = s;
          // Numbers read best largest first; names A to Z.
          _ascending = s == RoomSort.name || s == RoomSort.building;
        }),
        onDirection: () => setState(() => _ascending = !_ascending),
      );
      return [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= RoomsScreen.masterDetailWidth) {
              return _MasterDetail(controls: controls, entries: shown, selected: selected, analysis: analysis);
            }
            return _NarrowRooms(controls: controls, entries: shown, selected: selected, analysis: analysis);
          },
        ),
      ];
    },
  );

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}

class _ListControls extends StatelessWidget {
  const _ListControls({
    required this.query,
    required this.sort,
    required this.ascending,
    required this.shown,
    required this.total,
    required this.onSort,
    required this.onDirection,
  });

  final TextEditingController query;
  final RoomSort sort;
  final bool ascending;
  final int shown;
  final int total;
  final ValueChanged<RoomSort> onSort;
  final VoidCallback onDirection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = Fmt.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: query,
              decoration: InputDecoration(
                labelText: 'Search rooms',
                helperText: 'Room or building name',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.text.isEmpty
                    ? null
                    : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.clear), onPressed: query.clear),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppDropdownMenu<RoomSort>(
                  width: math.min(260.0, w - 56),
                  label: 'Sort by',
                  initialSelection: sort,
                  entries: [for (final s in RoomSort.values) DropdownMenuEntry(value: s, label: s.label)],
                  onSelected: (s) {
                    if (s != null) onSort(s);
                  },
                ),
                IconButton(
                  tooltip: ascending
                      ? 'Sorted ascending; switch to descending'
                      : 'Sorted descending; switch to ascending',
                  icon: Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward),
                  onPressed: onDirection,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                shown == total
                    ? '${fmt.count(total)} rooms'
                    : 'Showing ${fmt.count(shown)} of ${fmt.count(total)} rooms',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurface),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.entry, required this.selected, this.focusNode});

  final RoomListEntry entry;
  final bool selected;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final s = entry.summary;
    final issues = s.issueTotal;
    return ListTile(
      focusNode: focusNode,
      selected: selected,
      selectedTileColor: cs.secondaryContainer,
      selectedColor: cs.onSecondaryContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(issues > 0 ? Icons.report_problem_outlined : Icons.meeting_room_outlined),
      title: Text(
        s.room,
        style: theme.textTheme.titleMedium?.copyWith(color: selected ? cs.onSecondaryContainer : cs.onSurface),
      ),
      subtitle: Text(
        [
          'Building ${s.building}',
          fmt.hours(s.systemHours),
          '${fmt.count(s.systemSessions)} sessions',
          '${fmt.count(issues)} ${issues == 1 ? 'issue' : 'issues'}',
          entry.lastSeen == null ? 'never seen' : 'last seen ${fmt.dateTime(entry.lastSeen!)}',
        ].join(' · '),
        style: theme.textTheme.bodyMedium?.copyWith(color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant),
      ),
      onTap: () => context.read<NavigationState>().selectRoom(s.room),
    );
  }
}

/// List and detail side by side. The list scrolls on its own and is
/// virtualized, so thousands of rooms stay responsive.
class _MasterDetail extends StatelessWidget {
  const _MasterDetail({required this.controls, required this.entries, required this.selected, required this.analysis});

  final Widget controls;
  final List<RoomListEntry> entries;
  final String? selected;
  final AnalysisResult analysis;

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height - 160).clamp(420.0, 900.0);
    final motion = Motion.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 360,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  controls,
                  const SizedBox(height: 8),
                  SizedBox(
                    height: height,
                    child: entries.isEmpty
                        ? const _NoSearchMatches()
                        : Semantics(
                            container: true,
                            label: 'Room list, ${entries.length} rooms',
                            explicitChildNodes: true,
                            child: ListView.builder(
                              itemCount: entries.length,
                              itemBuilder: (context, i) =>
                                  _RoomTile(entry: entries[i], selected: entries[i].summary.room == selected),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: AnimatedSwitcher(
            duration: motion.medium,
            switchInCurve: motion.curve,
            transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            child: selected == null
                ? const EmptyState(
                    key: ValueKey('no-room'),
                    icon: Icons.touch_app_outlined,
                    title: 'Choose a room',
                    message: 'Select a room in the list to see its sources, devices, usage, issues and events.',
                  )
                : RoomDetail(key: ValueKey('room-$selected'), room: selected!, analysis: analysis),
          ),
        ),
      ],
    );
  }
}

/// Narrow layout: the list, or the selected room with a way back.
class _NarrowRooms extends StatefulWidget {
  const _NarrowRooms({required this.controls, required this.entries, required this.selected, required this.analysis});

  final Widget controls;
  final List<RoomListEntry> entries;
  final String? selected;
  final AnalysisResult analysis;

  @override
  State<_NarrowRooms> createState() => _NarrowRoomsState();
}

class _NarrowRoomsState extends State<_NarrowRooms> {
  static const int _pageSize = 50;
  int _visible = _pageSize;

  /// Page scroll offset of the list, restored when returning from a room.
  double _listOffset = 0;

  /// The room opened last; its tile gets focus back on return.
  String? _lastRoom;
  final FocusNode _backFocus = FocusNode(debugLabel: 'All rooms');
  final FocusNode _tileFocus = FocusNode(debugLabel: 'Last opened room');

  @override
  void dispose() {
    _backFocus.dispose();
    _tileFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NarrowRooms oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected == widget.selected) return;
    final position = Scrollable.maybeOf(context)?.position;
    final opening = widget.selected != null;
    if (opening) _lastRoom = widget.selected;
    // Opening a room starts at its heading with focus on Back; going back
    // returns to the same place in the list with focus on that room
    // (WCAG 2.4.3 focus order).
    if (oldWidget.selected == null && position != null && position.hasPixels) {
      _listOffset = position.pixels;
    }
    final target = opening ? 0.0 : _listOffset;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (position != null && position.hasPixels) {
        position.jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
      }
      (opening ? _backFocus : _tileFocus).requestFocus();
    });
  }

  void _back() {
    context.read<NavigationState>().selectRoom(null);
    announce(context, 'Back to the room list.');
  }

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context);
    final selected = widget.selected;
    final Widget body;
    if (selected != null) {
      body = PopScope(
        key: ValueKey('detail-$selected'),
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _back();
        },
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _back},
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  autofocus: true,
                  focusNode: _backFocus,
                  onPressed: _back,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('All rooms'),
                ),
              ),
              const SizedBox(height: 8),
              RoomDetail(room: selected, analysis: widget.analysis),
            ],
          ),
        ),
      );
    } else {
      final entries = widget.entries;
      final shown = entries.take(_visible).toList();
      body = Column(
        key: const ValueKey('list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: widget.controls),
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            const _NoSearchMatches()
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Semantics(
                  container: true,
                  label: 'Room list, ${entries.length} rooms',
                  explicitChildNodes: true,
                  child: Column(
                    children: [
                      for (final e in shown)
                        _RoomTile(
                          entry: e,
                          selected: false,
                          focusNode: e.summary.room == _lastRoom ? _tileFocus : null,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (_visible < entries.length)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                onPressed: () => setState(() => _visible += _pageSize),
                child: Text('Show more rooms (${entries.length - _visible} remaining)'),
              ),
            ),
        ],
      );
    }
    return AnimatedSwitcher(
      duration: motion.medium,
      switchInCurve: motion.curve,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0.04, 0), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
      child: body,
    );
  }
}

class _NoSearchMatches extends StatelessWidget {
  const _NoSearchMatches();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.search_off,
    title: 'No rooms match your search',
    message: 'Check the spelling or search for a building code such as BSS.',
  );
}
