// Internal: pattern detectors for the Issues view. Not exported.
//
// Every explanation states only what the data shows (counts, durations and
// metric names quoted as logged). Suggested actions are neutral follow-ups
// for an analyst. Neither says what a control does or why people used it:
// the engine does not know the room's control program.

import '../../data/models.dart';
import '../classifier.dart';
import '../connectivity.dart';
import '../issues.dart';
import '../sessions.dart';
import 'context.dart';
import 'window.dart';

/// Help-labelled events closer together than this are reported as one
/// issue.
const Duration helpClusterWindow = Duration(hours: 1);

/// A help-labelled cluster is a warning when it holds at least this many
/// onsets (events other than `Stopped`, `Released`, `Tapped`, `Held` and
/// `Repeated`, which usually accompany another event for the same use).
const int helpWarningCount = 3;

/// A device on for at least this long (with a real off event) is critical,
/// even when twice the configured threshold is longer.
const double deviceLeftOnCriticalHours = 24;

/// Human-friendly duration such as `45 seconds`, `7 minutes`, `3.5 hours`.
String formatDuration(Duration d) {
  final s = d.inMicroseconds / 1e6;
  String n(double v, String unit) {
    final text = v == v.roundToDouble()
        ? v.round().toString()
        : v.toStringAsFixed(1);
    return '$text $unit${text == '1' ? '' : 's'}';
  }

  if (s < 90) return n(s.roundToDouble(), 'second');
  if (s < 90 * 60) return n((s / 60).roundToDouble(), 'minute');
  if (s < 48 * 3600) return n(((s / 3600) * 10).round() / 10, 'hour');
  return n(((s / 86400) * 10).round() / 10, 'day');
}

String _times(int n) => n == 1 ? 'once' : '$n times';

String _q(String s) => '"$s"';

/// `"A" x3, "B" x1` for the counts in [counts], most frequent first.
String _tally(Map<String, int> counts, {int max = 6, bool quote = true}) {
  final entries = counts.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  final shown = [
    for (final e in entries.take(max))
      '${quote ? _q(e.key) : e.key} x${e.value}',
  ];
  final more = entries.length - shown.length;
  return more > 0 ? '${shown.join(', ')} and $more more' : shown.join(', ');
}

List<MetricEvent> _evidence(List<MetricEvent> all) => List.unmodifiable(
  all.length > Issue.maxEvidence ? all.sublist(0, Issue.maxEvidence) : all,
);

String _id(IssueType type, String room, String? subject, DateTime start) =>
    '${type.name}|$room|${subject ?? ''}|${start.microsecondsSinceEpoch}';

class _Detector {
  _Detector(this.ctx);
  final AnalysisContext ctx;
  final List<Issue> issues = [];

  void _add({
    required IssueType type,
    required IssueSeverity severity,
    required IssueArea area,
    required String room,
    String? subject,
    required DateTime start,
    required DateTime end,
    required int count,
    required String title,
    required String explanation,
    required String action,
    List<MetricEvent> evidence = const [],
  }) {
    issues.add(
      Issue(
        id: _id(type, room, subject, start),
        type: type,
        severity: severity,
        area: area,
        room: room,
        building: ctx.buildingOf(room),
        subject: subject,
        start: start,
        end: end,
        count: count,
        title: title,
        explanation: explanation,
        suggestedAction: action,
        evidence: _evidence(evidence),
      ),
    );
  }

  /// Runs [findBursts] over [events] and calls [onBurst] for each burst.
  void _bursts(
    List<MetricEvent> events,
    Duration window,
    int minCount,
    void Function(List<MetricEvent> burst) onBurst,
  ) {
    if (events.length < minCount) return;
    final times = [for (final e in events) e.timestamp.microsecondsSinceEpoch];
    for (final c in findBursts(times, window.inMicroseconds, minCount)) {
      onBurst(events.sublist(c.first, c.last + 1));
    }
  }

  /// Events of [events] in `[start, end]` whose meaning passes [keep].
  int _countBetween(
    List<ClassifiedEvent> events,
    DateTime start,
    DateTime end,
    bool Function(ClassifiedMetric) keep,
  ) {
    var n = 0;
    for (var i = _firstAtOrAfter(events, start); i < events.length; i++) {
      final ce = events[i];
      if (ce.time.isAfter(end)) break;
      if (keep(ce.meaning)) n++;
    }
    return n;
  }

  static int _firstAtOrAfter(List<ClassifiedEvent> events, DateTime t) {
    var lo = 0, hi = events.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (events[mid].time.isBefore(t)) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void detectRoom(String room) {
    final t = ctx.config.thresholds;
    final events = ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[];
    final sessions = ctx.sessions[room];

    // ---- repeated power cycling
    if (sessions != null) {
      _bursts(sessions.powerOnEvents, t.powerCycleWindow, t.powerCycleCount, (
        burst,
      ) {
        final n = burst.length;
        final start = burst.first.timestamp, end = burst.last.timestamp;
        final span = end.difference(start);
        final stops = _countBetween(
          events,
          start,
          end,
          (m) => m.category == EventCategory.systemPower && m.isStop,
        );
        final boots = _countBetween(
          events,
          start,
          end,
          (m) => m.lifecycle == LifecycleKind.programStart,
        );
        _add(
          type: IssueType.rapidPowerCycling,
          severity: n >= 2 * t.powerCycleCount
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          area: IssueArea.systemPower,
          room: room,
          start: start,
          end: end,
          count: n,
          title: 'Repeated power cycling in $room',
          explanation:
              'System power was turned on ${_times(n)} within '
              '${formatDuration(span)} (threshold: ${t.powerCycleCount} '
              'within ${formatDuration(t.powerCycleWindow)}). In the same '
              'period, system power was turned off ${_times(stops)} and '
              '${boots == 0 ? 'no program start was' : boots == 1 ? 'one program start was' : '$boots program starts were'} '
              'logged.',
          action:
              'Look at the room timeline for $room around this time to see '
              'what was logged between the power-ons. If the program logs '
              'device power or communication events, compare them for the '
              'same period.',
          evidence: _withNearby(
            events,
            burst,
            (m) =>
                m.category == EventCategory.systemPower ||
                m.category == EventCategory.lifecycle,
          ),
        );
      });
    }

    // ---- repeated presses, rapid navigation (Pressed only)
    final pressesByControl = <String, List<MetricEvent>>{};
    final repeatable = <String, bool>{};
    final navPresses = <ClassifiedEvent>[];
    final selections = <ClassifiedEvent>[];
    final help = <ClassifiedEvent>[];
    final connByTarget = <String, List<MetricEvent>>{};
    final connState = <String, bool>{};
    for (final ce in events) {
      final m = ce.meaning;
      if (m.isPress) {
        pressesByControl.putIfAbsent(m.controlName!, () => []).add(ce.event);
        repeatable[m.controlName!] = m.isRepeatable;
        if (m.isNavigation) navPresses.add(ce);
      }
      switch (m.category) {
        case EventCategory.input:
          // The automatic default source at power-on is not a selection.
          if (m.isSourceSelection &&
              !(sessions?.isAutomaticSelection(ce.event) ?? false)) {
            selections.add(ce);
          }
        case EventCategory.help:
          help.add(ce);
        case EventCategory.connection:
          // Only state changes count: programs often report the same state
          // twice (for example "Connected" now and again 10 s later).
          final target = m.connectionTarget!;
          if (connState[target] == m.connected) break;
          connState[target] = m.connected!;
          connByTarget.putIfAbsent(target, () => []).add(ce.event);
        default:
          break;
      }
    }

    for (final control in (pressesByControl.keys.toList()..sort())) {
      final rep = repeatable[control] ?? false;
      final need =
          t.buttonMashCount *
          (rep ? MetricClassifier.repeatableMashMultiplier : 1);
      _bursts(pressesByControl[control]!, t.buttonMashWindow, need, (burst) {
        final n = burst.length;
        final span = burst.last.timestamp.difference(burst.first.timestamp);
        _add(
          type: IssueType.repeatedPresses,
          severity: n >= 2 * need
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          area: IssueArea.controls,
          room: room,
          subject: control,
          start: burst.first.timestamp,
          end: burst.last.timestamp,
          count: n,
          title: 'Repeated presses of ${_q(control)} in $room',
          explanation:
              '${_q(control)} was pressed ${_times(n)} within '
              '${formatDuration(span)} (threshold: $need within '
              '${formatDuration(t.buttonMashWindow)}'
              '${rep ? '; raised because the control name matches the '
                        'repeatable-control pattern' : ''}).',
          action:
              'Check what ${_q(control)} does in this room\'s control '
              'program, and look at the room timeline around this time for '
              'the events logged during and after the presses.',
          evidence: burst,
        );
      });
    }

    if (navPresses.length >= t.navigationThrashCount) {
      final times = [
        for (final ce in navPresses) ce.time.microsecondsSinceEpoch,
      ];
      for (final c in findBursts(
        times,
        t.navigationThrashWindow.inMicroseconds,
        t.navigationThrashCount,
      )) {
        final burst = navPresses.sublist(c.first, c.last + 1);
        final n = burst.length;
        final span = burst.last.time.difference(burst.first.time);
        final counts = <String, int>{};
        for (final ce in burst) {
          final name = ce.meaning.controlName!;
          counts[name] = (counts[name] ?? 0) + 1;
        }
        _add(
          type: IssueType.rapidNavigation,
          severity: n >= 2 * t.navigationThrashCount
              ? IssueSeverity.warning
              : IssueSeverity.info,
          area: IssueArea.controls,
          room: room,
          start: burst.first.time,
          end: burst.last.time,
          count: n,
          title: 'Rapid navigation presses in $room',
          explanation:
              'Controls matching the navigation pattern were pressed '
              '${_times(n)} within ${formatDuration(span)} (threshold: '
              '${t.navigationThrashCount} within '
              '${formatDuration(t.navigationThrashWindow)}): '
              '${_tally(counts)}.',
          action:
              'Look at the room timeline around this time for the controls '
              'pressed before and after. Check whether the navigation '
              'pattern in Settings matches the controls you count as '
              'navigation in this room\'s program.',
          evidence: [for (final ce in burst) ce.event],
        );
      }
    }

    // ---- rapid source changes (needs at least two distinct sources)
    if (selections.length >= t.inputHuntCount) {
      final times = [
        for (final ce in selections) ce.time.microsecondsSinceEpoch,
      ];
      for (final c in findBursts(
        times,
        t.inputHuntWindow.inMicroseconds,
        t.inputHuntCount,
      )) {
        final burst = selections.sublist(c.first, c.last + 1);
        final labels = <String, String>{
          for (final ce in burst) ce.meaning.inputKey!: ce.meaning.inputLabel!,
        };
        if (labels.length < 2) continue;
        final n = burst.length;
        final span = burst.last.time.difference(burst.first.time);
        final order = [for (final ce in burst) ce.meaning.inputLabel!];
        _add(
          type: IssueType.rapidSourceChanges,
          severity: n >= 2 * t.inputHuntCount
              ? IssueSeverity.warning
              : IssueSeverity.info,
          area: IssueArea.sources,
          room: room,
          start: burst.first.time,
          end: burst.last.time,
          count: n,
          title: 'Rapid source changes in $room',
          explanation:
              'Sources were selected ${_times(n)} within '
              '${formatDuration(span)}, across ${labels.length} sources '
              '(threshold: ${t.inputHuntCount} within '
              '${formatDuration(t.inputHuntWindow)}). Order: '
              '${order.join(' > ')}.',
          action:
              'Look at the room timeline around this time. If the program '
              'logs device communication or other events for these sources, '
              'compare them for the same period.',
          evidence: [for (final ce in burst) ce.event],
        );
      }
    }

    // ---- connection changes
    for (final target in (connByTarget.keys.toList()..sort())) {
      _bursts(
        connByTarget[target]!,
        t.connectionFlapWindow,
        t.connectionFlapCount,
        (burst) {
          final n = burst.length;
          final span = burst.last.timestamp.difference(burst.first.timestamp);
          _add(
            type: IssueType.connectionFlapping,
            severity: n >= 2 * t.connectionFlapCount
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            area: IssueArea.connectivity,
            room: room,
            subject: target,
            start: burst.first.timestamp,
            end: burst.last.timestamp,
            count: n,
            title: 'Repeated connection changes for ${_q(target)} in $room',
            explanation:
                '${_q(target)} changed between Connected and Disconnected '
                '${_times(n)} within ${formatDuration(span)} (threshold: '
                '${t.connectionFlapCount} within '
                '${formatDuration(t.connectionFlapWindow)}). The last state '
                'logged in this period was ${burst.last.action}.',
            action:
                'Compare with the device\'s own logs and, if available, the '
                'network switch logs for this period. Check the room '
                'timeline for program starts around the same time.',
            evidence: burst,
          );
        },
      );
    }

    // ---- long device sessions
    final leftOn = t.deviceLeftOnHours.toDouble();
    for (final s in sessions?.devices ?? const <DeviceSession>[]) {
      if (s.hours <= leftOn) continue;
      final unterminated = s.unterminated;
      // Sessions closed by their own Stopped keep their true length (they
      // may pass the session limit), so both tiers can be reached.
      final severity = unterminated
          ? IssueSeverity.info
          : s.hours >= 2 * leftOn || s.hours >= deviceLeftOnCriticalHours
          ? IssueSeverity.critical
          : IssueSeverity.warning;
      final hoursText = formatDuration(s.duration);
      final offs = _countBetween(
        events,
        s.start,
        s.end,
        (m) => m.category == EventCategory.systemPower && m.isStop,
      );
      final systemOff = offs == 0
          ? ' No system power Stopped was logged during this time.'
          : ' System power Stopped was logged ${_times(offs)} during this '
                'time.';
      _add(
        type: IssueType.longDeviceSession,
        severity: severity,
        area: IssueArea.devices,
        room: room,
        subject: s.deviceId,
        start: s.start,
        end: s.end,
        count: s.hours.floor(),
        title: '${_q(s.deviceId)} on for $hoursText in $room',
        explanation: unterminated
            ? '${_q(s.deviceId)} was Started and no Stopped was logged '
                  'before it was Started again or before the session limit '
                  'passed. The session is counted as $hoursText (the session '
                  'limit) so it does not inflate totals.$systemOff'
            : s.ongoing
            ? '${_q(s.deviceId)} has been on for at least $hoursText and '
                  'was still on at the end of the data (threshold: '
                  '${t.deviceLeftOnHours} hours).$systemOff'
            : '${_q(s.deviceId)} was on for $hoursText from Started to '
                  'Stopped (threshold: ${t.deviceLeftOnHours} hours).'
                  '$systemOff',
        action:
            'Compare with the device\'s own logs or hour meter. Check '
            'whether the timer and schedule settings in the room\'s program '
            'match expectations, and whether the program logs Stopped for '
            '${_q(s.deviceId)} when it powers off.',
        evidence: [
          if (s.startEvent != null) s.startEvent!,
          if (s.endEvent != null) s.endEvent!,
        ],
      );
    }

    // ---- help-labelled events
    if (help.isNotEmpty) {
      final times = [for (final ce in help) ce.time.microsecondsSinceEpoch];
      for (final c in findBursts(
        times,
        helpClusterWindow.inMicroseconds,
        1,
      )) {
        final burst = help.sublist(c.first, c.last + 1);
        final n = burst.length;
        final onsets = burst.where((ce) {
          final m = ce.meaning;
          return !m.isStop && (m.uiEvent == null || m.isPress);
        }).length;
        final counts = <String, int>{};
        for (final ce in burst) {
          final key = '${_q(ce.event.metric.trim())} ${ce.event.action.trim()}';
          counts[key] = (counts[key] ?? 0) + 1;
        }
        final span = burst.last.time.difference(burst.first.time);
        _add(
          type: IssueType.helpEvents,
          severity: onsets >= helpWarningCount
              ? IssueSeverity.warning
              : IssueSeverity.info,
          area: IssueArea.help,
          room: room,
          start: burst.first.time,
          end: burst.last.time,
          count: n,
          title: n == 1
              ? 'Help-labelled event in $room'
              : '$n help-labelled events in $room',
          explanation: n == 1
              ? 'One event with "help" in its metric was logged: '
                    '${counts.keys.single}.'
              : '$n events with "help" in their metric were logged within '
                    '${formatDuration(span)}: ${_tally(counts, quote: false)}.',
          action:
              'Check what this control does in this room\'s control '
              'program, and look at the room timeline around this time for '
              'the events logged before and after.',
          evidence: [for (final ce in burst) ce.event],
        );
      }
    }
  }

  /// [burst] plus related events within the burst's time span (so evidence
  /// shows what happened between power-ons), capped by [Issue.maxEvidence].
  List<MetricEvent> _withNearby(
    List<ClassifiedEvent> events,
    List<MetricEvent> burst,
    bool Function(ClassifiedMetric) keep,
  ) {
    final start = burst.first.timestamp, end = burst.last.timestamp;
    final ids = Set<MetricEvent>.identity()..addAll(burst);
    final out = <MetricEvent>[];
    for (var i = _firstAtOrAfter(events, start); i < events.length; i++) {
      final ce = events[i];
      if (ce.time.isAfter(end)) break;
      if (ids.contains(ce.event) || keep(ce.meaning)) out.add(ce.event);
      if (out.length >= Issue.maxEvidence) break;
    }
    return out.isEmpty ? burst : out;
  }

  void detectOffline(RoomConnectivity rc) {
    final t = ctx.config.thresholds;
    for (final p in rc.offlinePeriods) {
      final severity = p.ongoing || p.duration >= const Duration(hours: 24)
          ? IssueSeverity.critical
          : IssueSeverity.warning;
      final len = formatDuration(p.duration);
      _add(
        type: IssueType.heartbeatGap,
        severity: severity,
        area: IssueArea.reporting,
        room: rc.room,
        start: p.start,
        end: p.end,
        count: p.hours.floor(),
        title: p.ongoing
            ? 'No heartbeats from ${rc.room}'
            : 'Heartbeat gap in ${rc.room}',
        explanation: p.ongoing
            ? 'No heartbeats or events were received from ${rc.room} for at '
                  'least $len, up to the end of the data (threshold: '
                  '${formatDuration(t.offlineGap)}).'
            : 'No heartbeats or events were received from ${rc.room} for '
                  'about $len (threshold: ${formatDuration(t.offlineGap)}). '
                  'Anything that happened in the room during this time is not '
                  'in the data.',
        action:
            'Check the processor\'s power and network connection and the '
            'program\'s heartbeat timer, and compare with the server\'s '
            'ingest logs for this period.',
      );
    }
  }
}

/// Runs every detector and returns issues sorted by start time, then
/// severity (highest first), then id.
List<Issue> detectIssues(AnalysisContext ctx, List<RoomConnectivity> rooms) {
  final d = _Detector(ctx);
  for (final room in ctx.rooms) {
    d.detectRoom(room);
  }
  for (final rc in rooms) {
    d.detectOffline(rc);
  }
  d.issues.sort((a, b) {
    final c = a.start.compareTo(b.start);
    if (c != 0) return c;
    final s = b.severity.index.compareTo(a.severity.index);
    return s != 0 ? s : a.id.compareTo(b.id);
  });
  return List.unmodifiable(d.issues);
}
