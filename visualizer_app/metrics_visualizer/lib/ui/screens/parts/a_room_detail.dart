// The per-room drill-down shown by the Rooms screen: headline numbers,
// per-room versions of the input, device and usage charts, recent issues
// and a virtualized, keyboard-scrollable timeline of the room's events.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../analytics/analytics.dart';
import '../../../state/app_state.dart';
import '../../../state/navigation_state.dart';
import '../../../state/settings_state.dart';
import '../../widgets/widgets.dart';
import 'a_cards.dart';
import 'a_common.dart';

/// Everything about one room.
class RoomDetail extends StatefulWidget {
  const RoomDetail({super.key, required this.room, required this.analysis});

  final String room;
  final AnalysisResult analysis;

  @override
  State<RoomDetail> createState() => _RoomDetailState();
}

class _RoomDetailState extends State<RoomDetail> {
  InputMeasure _measure = InputMeasure.time;

  @override
  Widget build(BuildContext context) {
    final a = widget.analysis;
    final room = widget.room;
    final summary = a.roomSummary(room);
    final fmt = Fmt.of(context);
    final nav = context.read<NavigationState>();
    if (summary == null) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'Room $room is not in the current filters',
        message: 'Choose another room, or widen the date range and building or room filters.',
        action: FilledButton.icon(
          onPressed: () => nav.selectRoom(null),
          icon: const Icon(Icons.list),
          label: const Text('Back to the room list'),
        ),
      );
    }
    final util = a.system.rooms.where((r) => r.room == room).firstOrNull;
    final conn = a.connectivity.rooms.where((r) => r.room == room).firstOrNull;
    final issues = [...a.issuesForRoom(room)]..sort((x, y) => y.start.compareTo(x.start));
    final lastSeen = _latest(summary.lastEvent, conn?.lastSeen);
    final styles = InputStyles(ChartPalette.of(context), a.inputs.campus);
    final typeOrder = [for (final t in a.devices.types) t.type]..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Room $room',
          subtitle:
              'Building ${summary.building}'
              '${lastSeen == null ? '' : ' · last seen ${fmt.dateTime(lastSeen)}'}'
              '${summary.topInput == null ? '' : ' · most used source ${summary.topInput!.label}'}',
        ),
        ResponsiveGrid(
          minChildWidth: 190,
          maxColumns: 5,
          children: [
            KpiTile(label: 'System-on hours', value: fmt.hours(summary.systemHours), icon: Icons.timer_outlined),
            KpiTile(
              label: 'Sessions',
              value: fmt.count(summary.systemSessions),
              icon: Icons.power_settings_new,
              caption: 'average ${fmt.hours(summary.averageSessionHours)}',
            ),
            KpiTile(
              label: 'Utilization',
              value: fmt.percent(summary.utilization),
              icon: Icons.event_available_outlined,
              caption: '${fmt.hours(summary.afterHoursHours)} after hours',
            ),
            KpiTile(
              label: 'Device on-hours',
              value: fmt.hours(summary.deviceHours),
              icon: Icons.videocam_outlined,
              caption: '${summary.deviceIds.length} devices',
            ),
            KpiTile(
              label: 'Online',
              value: summary.onlineFraction == null ? 'Unknown' : fmt.percent(summary.onlineFraction!),
              icon: Icons.lan_outlined,
              caption: summary.onlineFraction == null ? 'no heartbeat data in range' : 'of hours with heartbeats',
            ),
            KpiTile(
              label: 'Potential issues',
              value: fmt.count(summary.issueTotal),
              icon: Icons.report_problem_outlined,
              caption: '${fmt.count(summary.issueCounts[IssueSeverity.critical] ?? 0)} critical',
            ),
            KpiTile(label: 'Help-labelled events', value: fmt.count(summary.helpEvents), icon: Icons.help_outline),
            KpiTile(label: 'Program starts', value: fmt.count(summary.reboots), icon: Icons.restart_alt),
            KpiTile(label: 'Control presses', value: fmt.count(summary.buttonPresses), icon: Icons.touch_app_outlined),
            KpiTile(label: 'Events', value: fmt.count(summary.eventCount), icon: Icons.list_alt),
          ],
        ),
        const SizedBox(height: 16),
        ResponsiveGrid(
          minChildWidth: 420,
          maxColumns: 2,
          children: [
            InputShareCard(
              title: 'Source share in $room',
              shares: a.inputs.byRoom[room] ?? const [],
              measure: _measure,
              scopeLabel: 'room $room',
              styles: styles,
              actions: [
                Semantics(
                  label: 'Measure',
                  container: true,
                  explicitChildNodes: true,
                  child: SegmentedButton<InputMeasure>(
                    segments: [for (final m in InputMeasure.values) ButtonSegment(value: m, label: Text(m.label))],
                    selected: {_measure},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() => _measure = s.first),
                  ),
                ),
              ],
            ),
            DeviceHoursCard(
              title: 'Device on-hours in $room',
              devices: a.devicesForRoom(room),
              scopeLabel: 'room $room',
              showRoom: false,
              typeOrder: typeOrder,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (util != null)
          HeatmapCard(
            heatmap: util.occupancy,
            title: 'When $room is in use',
            description: 'Share of each hour of the week that the system was on in this room.',
            cellNoun: 'of the time on',
            timeZoneLabel: a.timeZoneLabel,
          ),
        const SizedBox(height: 16),
        InfoCard(
          title: 'Recent issues in $room',
          icon: Icons.report_problem_outlined,
          description: issues.isEmpty ? null : 'Newest first; ${issues.length} in total.',
          actions: [
            if (issues.isNotEmpty)
              TextButton(onPressed: () => nav.goTo(AppDestination.issues), child: const Text('Open Issues')),
          ],
          child: issues.isEmpty
              ? Text(
                  'No patterns were found in this room.',
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
                )
              : IssueSummaryList(issues: issues.take(10).toList(), showRoom: false),
        ),
        const SizedBox(height: 16),
        EventTimeline(room: room),
      ],
    );
  }

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }
}

/// A virtualized list of one room's events (newest first) with a category
/// filter. The list is a single tab stop: focus it and use the arrow,
/// Page Up/Down, Home and End keys to scroll.
class EventTimeline extends StatefulWidget {
  const EventTimeline({super.key, required this.room});

  final String room;

  /// Key of the focusable list area (one tab stop for the whole list).
  static const Key focusKey = ValueKey('event-timeline-focus');

  /// Category shown for events that matched no recognition rule.
  static const String unmatchedLabel = 'Not recognized';

  /// What an event was recognized as, for the timeline: the category plus
  /// the detail the app read from the name (source, device type, reason
  /// group, control kind), so implementers can check their naming.
  static String recognizedAs(ClassifiedMetric m) {
    final detail = switch (m.category) {
      EventCategory.input => m.inputLabel == null ? null : 'source "${m.inputLabel}"',
      EventCategory.device => m.deviceType == null ? null : 'type ${m.deviceType}',
      EventCategory.systemPower => switch (m.powerSource) {
          null || PowerSource.unknown => m.phase == EventPhase.none ? null : 'no reason logged',
          PowerSource.other => 'reason "${m.powerReason}" (in no reason group)',
          final p => 'reason group ${p.label}',
        },
      EventCategory.lifecycle => switch (m.lifecycle) {
          LifecycleKind.programStart => 'program start',
          LifecycleKind.programStartStopped => 'program start name with Stopped',
          LifecycleKind.startupComplete => 'startup complete',
          LifecycleKind.shutdownComplete => 'shutdown complete',
          null => null,
        },
      EventCategory.uiTrace => [
          if (m.isNavigation) 'navigation',
          if (m.isRepeatable) 'repeatable',
        ].join(', '),
      EventCategory.mute => m.muteName,
      EventCategory.volume => m.volumeLevel == null ? null : 'level ${m.volumeLevel}',
      _ => null,
    };
    final label = m.category == EventCategory.other ? '$unmatchedLabel (matched no rule)' : m.category.label;
    return detail == null || detail.isEmpty ? label : '$label: $detail';
  }

  @override
  State<EventTimeline> createState() => _EventTimelineState();
}

class _EventTimelineState extends State<EventTimeline> {
  static const double _viewportHeight = 440;

  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'Event timeline');
  bool _focused = false;
  EventCategory? _category;

  Dataset? _cachedDataset;
  String? _cachedRoom;
  ClassifierConfig? _cachedConfig;
  MetricClassifier? _classifier;
  List<(MetricEvent, ClassifiedMetric)> _events = const [];

  @override
  void dispose() {
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _refresh(Dataset? ds, ClassifierConfig config) {
    if (identical(ds, _cachedDataset) && _cachedRoom == widget.room && identical(config, _cachedConfig)) {
      return;
    }
    _cachedDataset = ds;
    _cachedRoom = widget.room;
    _cachedConfig = config;
    _classifier = MetricClassifier(config);
    final classifier = _classifier!;
    final list = <(MetricEvent, ClassifiedMetric)>[];
    if (ds != null) {
      // Dataset events are time-ascending; walk backwards for newest first.
      for (var i = ds.events.length - 1; i >= 0; i--) {
        final e = ds.events[i];
        if (e.clientName != widget.room) continue;
        final c = classifier.classify(e.metric, e.action);
        if (c.category == EventCategory.heartbeat) continue;
        list.add((e, c));
      }
    }
    _events = list;
    if (_category != null && !list.any((x) => x.$2.category == _category)) _category = null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (!_scroll.hasClients) return KeyEventResult.ignored;
    final p = _scroll.position;
    final page = p.viewportDimension * 0.9;
    final target = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowDown => p.pixels + 48,
      LogicalKeyboardKey.arrowUp => p.pixels - 48,
      LogicalKeyboardKey.pageDown => p.pixels + page,
      LogicalKeyboardKey.pageUp => p.pixels - page,
      LogicalKeyboardKey.home => p.minScrollExtent,
      LogicalKeyboardKey.end => p.maxScrollExtent,
      _ => null,
    };
    if (target == null) return KeyEventResult.ignored;
    _scroll.jumpTo(target.clamp(p.minScrollExtent, p.maxScrollExtent));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final ds = context.select<AppState, Dataset?>((s) => s.filteredDataset);
    final config = context.select<SettingsState, ClassifierConfig>((s) => s.analysisConfig.classifier);
    _refresh(ds, config);
    final present = {for (final e in _events) e.$2.category}.toList()..sort((a, b) => a.index.compareTo(b.index));
    final events = _category == null
        ? _events
        : [
            for (final e in _events)
              if (e.$2.category == _category) e,
          ];
    return InfoCard(
      title: 'Event timeline: ${widget.room}',
      icon: Icons.timeline,
      description: 'Every event the room logged in this period, newest first (heartbeats excluded), with the '
          'category it was recognized as under Settings > Event recognition. Use it to check that a '
          'program\'s names are recognized as intended; events that matched no rule show as '
          '"${EventTimeline.unmatchedLabel}".',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppDropdownMenu<EventCategory?>(
                key: ValueKey('timeline-filter-${widget.room}'),
                width: constraints.maxWidth < 320 ? constraints.maxWidth : 320,
                label: 'Show events',
                initialSelection: _category,
                entries: [
                  const DropdownMenuEntry<EventCategory?>(value: null, label: 'All categories'),
                  for (final c in present)
                    DropdownMenuEntry<EventCategory?>(
                      value: c,
                      label: c == EventCategory.other ? EventTimeline.unmatchedLabel : c.label,
                    ),
                ],
                onSelected: (c) => setState(() => _category = c),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              '${fmt.count(events.length)} ${events.length == 1 ? 'event' : 'events'}'
              '${_category == null ? '' : ' in ${_category == EventCategory.other ? EventTimeline.unmatchedLabel : _category!.label}'}',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
            ),
          ),
          const SizedBox(height: 8),
          if (events.isEmpty)
            Text('No events to show.', style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface))
          else
            Focus(
              key: EventTimeline.focusKey,
              focusNode: _focus,
              onKeyEvent: _onKey,
              onFocusChange: (f) => setState(() => _focused = f),
              child: Semantics(
                container: true,
                label:
                    'Event timeline for ${widget.room}, ${events.length} events. '
                    'Use the arrow, Page Up, Page Down, Home and End keys to scroll.',
                explicitChildNodes: true,
                child: Container(
                  height: _viewportHeight,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _focused ? cs.primary : cs.outlineVariant, width: _focused ? 3 : 1),
                  ),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: ListView.builder(
                      controller: _scroll,
                      itemCount: events.length,
                      itemBuilder: (context, i) => _EventRow(event: events[i].$1, meaning: events[i].$2),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({required this.event, required this.meaning});

  final MetricEvent event;
  final ClassifiedMetric meaning;

  EventCategory get category => meaning.category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final fmt = Fmt.of(context);
    final time = fmt.dateTime(event.timestamp);
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 12),
              child: Icon(_icon(category), size: 20, color: cs.onSurfaceVariant),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${event.metric} · ${event.action}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '$time · Recognized as ${EventTimeline.recognizedAs(meaning)}',
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _icon(EventCategory c) => switch (c) {
    EventCategory.input => Icons.input,
    EventCategory.device => Icons.videocam_outlined,
    EventCategory.systemPower => Icons.power_settings_new,
    EventCategory.lifecycle => Icons.restart_alt,
    EventCategory.help => Icons.help_outline,
    EventCategory.mute => Icons.volume_off_outlined,
    EventCategory.volume => Icons.volume_up_outlined,
    EventCategory.share => Icons.cast,
    EventCategory.uiTrace => Icons.touch_app_outlined,
    EventCategory.connection => Icons.lan_outlined,
    EventCategory.adminLifecycle => Icons.dns_outlined,
    EventCategory.heartbeat => Icons.favorite_border,
    EventCategory.other => Icons.more_horiz,
  };
}
