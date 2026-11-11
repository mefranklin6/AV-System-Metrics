// Turns a room's ordered events into power, device, input and mute
// sessions. Pure Dart.

import '../data/models.dart';
import 'classifier.dart';

/// Why a system power session ended.
///
/// The first values mirror the reason groups of [PowerSource] (see
/// `ClassifierConfig.powerReasonSynonyms`); the rest describe how the
/// session was closed when no reason applies.
enum OffReason {
  /// System power `Stopped` with reason `User` or a synonym.
  user,

  /// System power `Stopped` with reason `Inactivity` or a synonym.
  inactivity,

  /// System power `Stopped` with reason `Schedule` or a synonym.
  scheduled,

  /// System power `Stopped` with reason `Remote` or a synonym.
  remote,

  /// System power `Stopped` with a reason in none of the groups (or
  /// `Restore`). The text is in [SystemSession.offReasonText].
  other,

  /// A program start (`Program Start`, `Initialize`, ...) arrived while the
  /// room was on.
  reinitialized,

  /// No off event arrived within [AnalysisConfig.maxSessionLength]; the
  /// session was closed at that limit.
  capped,

  /// Still on when the data ends; the session is clipped at the end of the
  /// dataset range.
  truncated,

  /// Ended by a shutdown-complete trace or a system power `Stopped` with no
  /// reason.
  unknown,
}

/// How a device, input or mute session ended.
enum SessionEnd {
  /// The matching `Stopped` event (for sources: a `Stopped` for the source
  /// on screen).
  stopped,

  /// Another input was selected (inputs only).
  switched,

  /// The room system powered off (inputs and mutes only; devices report
  /// their own `Stopped` after cooling down).
  systemOff,

  /// A program start was logged (processor boot or program load).
  reinitialized,

  /// No end event within [AnalysisConfig.maxSessionLength]. For devices:
  /// the device was started again, or no event for it arrived within
  /// [SessionBuilder.deviceHardLimit], so the matching `Stopped` was lost.
  capped,

  /// Still open when the data ends.
  ongoing,
}

/// Common fields of every session. Times are UTC and clipped to the
/// dataset range; [end] is exclusive.
abstract class Session {
  const Session({
    required this.room,
    required this.start,
    required this.end,
    this.startClipped = false,
  });

  /// Client name of the room.
  final String room;

  final DateTime start;
  final DateTime end;

  /// The session began before the dataset range: only a stop event was
  /// seen, so [start] is the range start.
  final bool startClipped;

  /// Length of the session.
  Duration get duration => end.difference(start);

  /// Length of the session in hours.
  double get hours => duration.inMicroseconds / 3.6e9;

  /// No end event was seen before [AnalysisConfig.maxSessionLength] elapsed.
  bool get unterminated;

  /// Still open at the end of the dataset range.
  bool get ongoing;
}

/// One period during which a room's AV system was powered on.
class SystemSession extends Session {
  const SystemSession({
    required super.room,
    required super.start,
    required super.end,
    super.startClipped,
    required this.startSource,
    required this.offReason,
    this.startReason,
    this.offReasonText,
    this.startEvent,
    this.endEvent,
  });

  /// Reason group of the event that opened the session; `null` when
  /// [startClipped].
  final PowerSource? startSource;

  final OffReason offReason;

  /// Reason text of the opening event exactly as logged (`User`), or
  /// null when none was logged.
  final String? startReason;

  /// Reason text of the closing event exactly as logged, or null when none
  /// was logged or the session was not closed by a system power event.
  final String? offReasonText;

  /// Event that opened the session, when known.
  final MetricEvent? startEvent;

  /// Event that closed the session, when known.
  final MetricEvent? endEvent;

  @override
  bool get unterminated => offReason == OffReason.capped;

  @override
  bool get ongoing => offReason == OffReason.truncated;
}

/// One period during which a device (projector, camera, ...) was on.
class DeviceSession extends Session {
  const DeviceSession({
    required super.room,
    required super.start,
    required super.end,
    super.startClipped,
    required this.deviceId,
    required this.deviceType,
    required this.endKind,
    this.startEvent,
    this.endEvent,
  });

  /// Device metric as logged, such as `Projector 1`.
  final String deviceId;

  /// Upper-case type, such as `PROJECTOR`.
  final String deviceType;

  final SessionEnd endKind;
  final MetricEvent? startEvent;
  final MetricEvent? endEvent;

  /// Stable key for the physical device: `room/deviceId`.
  String get deviceKey => '$room/$deviceId';

  @override
  bool get unterminated => endKind == SessionEnd.capped;

  @override
  bool get ongoing => endKind == SessionEnd.ongoing;
}

/// One period during which a source was on screen.
class InputSession extends Session {
  const InputSession({
    required super.room,
    required super.start,
    required super.end,
    required this.inputKey,
    required this.inputLabel,
    required this.selections,
    required this.endKind,
  });

  /// Normalised lower-case source key, such as `hdmi 1`.
  final String inputKey;

  /// Display label, such as `HDMI 1`.
  final String inputLabel;

  /// Number of selections merged into this session (re-selecting the
  /// current source does not start a new session).
  final int selections;

  final SessionEnd endKind;

  @override
  bool get unterminated => endKind == SessionEnd.capped;

  @override
  bool get ongoing => endKind == SessionEnd.ongoing;
}

/// One period during which a mute was on.
class MuteSession extends Session {
  const MuteSession({
    required super.room,
    required super.start,
    required super.end,
    super.startClipped,
    required this.name,
    required this.endKind,
  });

  /// Mute channel, such as `Program Audio` (from `Program Audio Mute` or
  /// `Program Audio Muted`).
  final String name;
  final SessionEnd endKind;

  @override
  bool get unterminated => endKind == SessionEnd.capped;

  @override
  bool get ongoing => endKind == SessionEnd.ongoing;
}

/// All sessions reconstructed for one room, plus bookkeeping counters.
class RoomSessions {
  const RoomSessions({
    required this.room,
    required this.system,
    required this.devices,
    required this.inputs,
    required this.mutes,
    required this.powerOnEvents,
    required this.reboots,
    required this.orphanStops,
    required this.duplicateStarts,
    this.automaticInputStarts = const <MetricEvent>{},
  });

  final String room;

  /// Sorted by start.
  final List<SystemSession> system;

  /// Sorted by start.
  final List<DeviceSession> devices;

  /// Sorted by start.
  final List<InputSession> inputs;

  /// Sorted by start.
  final List<MuteSession> mutes;

  /// Events that opened a system session, in time order. Used for
  /// power-cycle detection. A `Started` while the system was already on is
  /// not included (it is counted in [duplicateStarts]).
  final List<MetricEvent> powerOnEvents;

  /// Number of program start events (processor boots or program loads).
  final int reboots;

  /// `Stopped` events that had nothing to stop and could not be attributed
  /// to a session that began before the data range.
  final int orphanStops;

  /// `Started` events ignored because the same thing was already on.
  final int duplicateStarts;

  /// Source selections that arrived during power-on (the first selection
  /// within [SessionBuilder.startupSelectionWindow] of power-on, or before
  /// the startup-complete trace). They are counted as the automatic default
  /// source: they count for time on screen but not as selections.
  final Set<MetricEvent> automaticInputStarts;

  /// Whether [event] (a source selection) was an automatic default source
  /// rather than a selection.
  bool isAutomaticSelection(MetricEvent event) =>
      automaticInputStarts.contains(event);
}

class _Open {
  _Open(this.start, this.event);
  final DateTime start;
  final MetricEvent? event;
  String deviceType = '';
  PowerSource? source;
  String? reason;
  String inputLabel = '';
  int selections = 1;

  /// Device sessions only: [AnalysisConfig.maxSessionLength] has passed
  /// without a `Stopped`; the session waits for the device's next event.
  bool pastCap = false;
}

/// Rebuilds sessions for one room. See `lib/analytics/README.md` for the
/// full rules; in short:
///
/// * System sessions open on a system power `Started` (or a startup-complete
///   trace when nothing is open) and close on a system power `Stopped`, a
///   shutdown-complete trace, a program start, the [maxSessionLength] cap,
///   or the range end. A `Started` while the system is already on is a
///   marker only: it neither opens a second session nor counts as a
///   power-on.
/// * Device sessions open on `Started` (a repeated `Started` is ignored)
///   and close on `Stopped`, a program start, the cap or the range end. They do
///   not close when the system powers off: a device still on long after
///   power-off is exactly the "left on" case worth reporting. A device
///   session that passes the cap is not closed straight away: if the
///   device's next event is its `Stopped` (or a program start) within
///   [deviceHardLimit], the session ends there with its true length. If the
///   device is `Started` again first, or nothing arrives in time, the
///   `Stopped` was lost and the session is closed at the cap.
/// * The first source selection after power-on is the automatic default
///   source when it arrives within [startupSelectionWindow] of power-on, or
///   before the startup-complete trace when that trace follows within
///   [startupTraceLimit]. It is listed in [RoomSessions.automaticInputStarts].
/// * Source sessions run from a selection (`Started` or `Trace`) until
///   another source, a `Stopped` for the source on screen, system
///   power-off, a program start, the cap or the range end.
/// * Mute sessions run from `Started` (or `Muted`) to `Stopped` (or
///   `Unmuted`), system power-off, a program start, the cap or the range
///   end.
/// * A `Stopped` that is the first event for its subject and arrives within
///   [maxSessionLength] of the range start becomes a session starting at
///   the range start ([Session.startClipped]); otherwise it is counted in
///   [RoomSessions.orphanStops]. Scheduled shut-downs never do this because
///   they are logged nightly even when the room is already off.
/// * A device `Stopped` with nothing to stop that arrives within
///   [stateSyncWindow] after a program start, or more than [stateSyncWindow]
///   after the system was turned off, is treated as a status re-sync (some
///   programs log `Stopped` for devices that report "off" after a reboot or
///   a lost connection). It neither starts a clipped session nor counts as
///   an orphan. A device's first `Stopped` after any program start in range
///   never starts a clipped session either.
class SessionBuilder {
  SessionBuilder({
    required this.room,
    required this.rangeStart,
    required this.rangeEnd,
    required this.maxSessionLength,
  });

  final String room;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final Duration maxSessionLength;

  /// The first source selected this soon after power-on is counted as the
  /// automatic default source.
  static const Duration startupSelectionWindow = Duration(seconds: 15);

  /// A later first selection still counts as automatic when the
  /// startup-complete trace arrives after it and within this long of
  /// power-on.
  static const Duration startupTraceLimit = Duration(minutes: 2);

  /// A device session past [maxSessionLength] waits at most this long from
  /// its start (or [maxSessionLength], if longer) for its `Stopped`.
  static const Duration deviceHardLimit = Duration(days: 7);

  /// See the class documentation on status re-syncs.
  static const Duration stateSyncWindow = Duration(minutes: 15);

  final List<SystemSession> _system = [];
  final List<DeviceSession> _devices = [];
  final List<InputSession> _inputs = [];
  final List<MuteSession> _mutes = [];
  final List<MetricEvent> _powerOn = [];
  int _reboots = 0;
  int _orphanStops = 0;
  int _duplicateStarts = 0;

  _Open? _sys;
  bool _seenPower = false;
  final Map<String, _Open> _dev = {};
  final Set<String> _seenDevice = {};
  _Open? _input;
  String? _inputKey;
  final Map<String, _Open> _mute = {};
  final Set<String> _seenMute = {};
  final Set<MetricEvent> _automatic = Set.identity();

  /// Power-on time while waiting for the startup's default source.
  DateTime? _startupAt;

  /// First input after power-on that came later than
  /// [startupSelectionWindow]; automatic if the startup trace follows.
  MetricEvent? _startupCandidate;
  DateTime? _candidatePowerOn;
  DateTime? _lastInit;
  DateTime? _lastSysOff;

  /// Convenience: builds sessions for [events] (time-ordered, one room).
  static RoomSessions build({
    required String room,
    required List<ClassifiedEvent> events,
    required DateTime rangeStart,
    required DateTime rangeEnd,
    required Duration maxSessionLength,
  }) {
    final b = SessionBuilder(
      room: room,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      maxSessionLength: maxSessionLength,
    );
    for (final e in events) {
      b.add(e);
    }
    return b.finish();
  }

  DateTime _capOf(DateTime start) => start.add(maxSessionLength);

  bool _withinCapOfRangeStart(DateTime t) => !t.isAfter(_capOf(rangeStart));

  /// Latest time a device session may still be closed by its own `Stopped`.
  DateTime _deviceLimitOf(DateTime start) => start.add(
    maxSessionLength > deviceHardLimit ? maxSessionLength : deviceHardLimit,
  );

  /// Closes everything whose cap has passed before [t]. Device sessions past
  /// the cap are only marked [_Open.pastCap] until [_deviceLimitOf].
  void _expire(DateTime t) {
    final sys = _sys;
    if (sys != null && _capOf(sys.start).isBefore(t)) {
      _closeSystem(_capOf(sys.start), OffReason.capped, null);
    }
    if (_dev.isNotEmpty) {
      final expired = <String>[];
      for (final entry in _dev.entries) {
        final o = entry.value;
        if (_deviceLimitOf(o.start).isBefore(t)) {
          expired.add(entry.key);
        } else if (_capOf(o.start).isBefore(t)) {
          o.pastCap = true;
        }
      }
      for (final id in expired) {
        _closeDevice(id, _capOf(_dev[id]!.start), SessionEnd.capped, null);
      }
    }
    final input = _input;
    if (input != null && _capOf(input.start).isBefore(t)) {
      _closeInput(_capOf(input.start), SessionEnd.capped);
    }
    if (_mute.isNotEmpty) {
      final expired = [
        for (final entry in _mute.entries)
          if (_capOf(entry.value.start).isBefore(t)) entry.key,
      ];
      for (final name in expired) {
        _closeMute(name, _capOf(_mute[name]!.start), SessionEnd.capped);
      }
    }
  }

  /// Feeds the next event. Events must arrive in time order.
  void add(ClassifiedEvent ce) {
    final t = ce.time;
    if (t.isBefore(rangeStart) || !t.isBefore(rangeEnd)) return;
    _expire(t);
    final m = ce.meaning;
    switch (m.category) {
      case EventCategory.systemPower:
        _onPower(ce, m);
      case EventCategory.lifecycle:
        _onLifecycle(ce, m);
      case EventCategory.device:
        _onDevice(ce, m);
      case EventCategory.input:
        if (m.isSourceSelection) {
          _onInput(ce, m);
        } else if (m.isStop) {
          _onInputStop(ce, m);
        }
      case EventCategory.mute:
        _onMute(ce, m);
      default:
        break;
    }
  }

  void _openSystem(
    ClassifiedEvent ce,
    PowerSource source, {
    bool startupDone = false,
  }) {
    _sys = _Open(ce.time, ce.event)
      ..source = source
      ..reason = ce.meaning.powerReason;
    _seenPower = true;
    _powerOn.add(ce.event);
    if (startupDone) {
      _endStartup();
    } else {
      _beginStartup(ce.time);
    }
  }

  // ---- automatic startup source selection

  void _beginStartup(DateTime t) {
    _startupAt = t;
    _startupCandidate = null;
    _candidatePowerOn = null;
  }

  void _endStartup() {
    _startupAt = null;
    _startupCandidate = null;
    _candidatePowerOn = null;
  }

  /// Called for every source selection.
  void _checkStartupSelection(ClassifiedEvent ce) {
    final on = _startupAt;
    if (on == null) return;
    _startupAt = null; // only the first input after power-on can qualify
    final since = ce.time.difference(on);
    if (since <= startupSelectionWindow) {
      _automatic.add(ce.event);
    } else if (since <= startupTraceLimit) {
      _startupCandidate = ce.event;
      _candidatePowerOn = on;
    }
  }

  /// Called for the startup-complete trace.
  void _onStartupComplete(DateTime t) {
    final candidate = _startupCandidate;
    final on = _candidatePowerOn;
    if (candidate != null &&
        on != null &&
        t.difference(on) <= startupTraceLimit) {
      _automatic.add(candidate);
    }
    _endStartup();
  }

  // ---- status re-syncs

  /// A device `Stopped` with nothing to stop at [t] is a status re-sync:
  /// shortly after a processor boot, or well after the system was turned
  /// off (so it is not the device's normal cool-down `Stopped`).
  bool _isStateSync(DateTime t) {
    final init = _lastInit;
    if (init != null && !t.isAfter(init.add(stateSyncWindow))) return true;
    final off = _lastSysOff;
    return _sys == null && off != null && t.isAfter(off.add(stateSyncWindow));
  }

  void _onPower(ClassifiedEvent ce, ClassifiedMetric m) {
    final source = m.powerSource ?? PowerSource.unknown;
    if (m.isStart) {
      if (_sys != null) {
        // Already on: a marker only (for example a reset that keeps the
        // system on).
        _duplicateStarts++;
        _seenPower = true;
        return;
      }
      _openSystem(ce, source);
      return;
    }
    // Stopped.
    final reason = switch (source) {
      PowerSource.user => OffReason.user,
      PowerSource.inactivity => OffReason.inactivity,
      PowerSource.scheduled => OffReason.scheduled,
      PowerSource.remote => OffReason.remote,
      PowerSource.restore || PowerSource.other => OffReason.other,
      PowerSource.unknown => OffReason.unknown,
    };
    if (_sys != null) {
      _closeSystem(ce.time, reason, ce.event, m.powerReason);
    } else if (!_seenPower &&
        source != PowerSource.scheduled &&
        _withinCapOfRangeStart(ce.time)) {
      _system.add(
        SystemSession(
          room: room,
          start: rangeStart,
          end: ce.time,
          startClipped: true,
          startSource: null,
          offReason: reason,
          offReasonText: m.powerReason,
          endEvent: ce.event,
        ),
      );
    } else {
      _orphanStops++;
    }
    _seenPower = true;
    _systemOff(ce.time);
  }

  void _onLifecycle(ClassifiedEvent ce, ClassifiedMetric m) {
    switch (m.lifecycle) {
      case LifecycleKind.programStart:
        _reboots++;
        final t = ce.time;
        _lastInit = t;
        _endStartup();
        if (_sys != null) _closeSystem(t, OffReason.reinitialized, ce.event);
        for (final id in _dev.keys.toList()) {
          _closeDevice(id, t, SessionEnd.reinitialized, ce.event);
        }
        if (_input != null) _closeInput(t, SessionEnd.reinitialized);
        for (final name in _mute.keys.toList()) {
          _closeMute(name, t, SessionEnd.reinitialized);
        }
      case LifecycleKind.startupComplete:
        if (_sys == null) {
          _openSystem(ce, PowerSource.unknown, startupDone: true);
        } else {
          _onStartupComplete(ce.time);
        }
      case LifecycleKind.shutdownComplete:
        if (_sys != null) {
          _closeSystem(ce.time, OffReason.unknown, ce.event);
          _systemOff(ce.time);
        }
        _lastSysOff = ce.time;
      case LifecycleKind.programStartStopped:
      case null:
        break;
    }
  }

  void _systemOff(DateTime t) {
    _lastSysOff = t;
    _endStartup();
    if (_input != null) _closeInput(t, SessionEnd.systemOff);
    for (final name in _mute.keys.toList()) {
      _closeMute(name, t, SessionEnd.systemOff);
    }
  }

  void _onDevice(ClassifiedEvent ce, ClassifiedMetric m) {
    final id = m.deviceId!;
    final first = _seenDevice.add(id);
    if (m.isStart) {
      final open = _dev[id];
      if (open != null && !open.pastCap) {
        _duplicateStarts++;
        return;
      }
      if (open != null) {
        // Started again after the cap: the Stopped was lost.
        _closeDevice(id, _capOf(open.start), SessionEnd.capped, null);
      }
      _dev[id] = _Open(ce.time, ce.event)..deviceType = m.deviceType ?? '';
      return;
    }
    if (_dev.containsKey(id)) {
      // Also for a session past the cap: this is its real end.
      _closeDevice(id, ce.time, SessionEnd.stopped, ce.event);
    } else if (first && _reboots > 0) {
      // Re-sync after a processor boot: there is no earlier session to clip.
    } else if (_isStateSync(ce.time)) {
      // Status re-sync, not the end of a session.
    } else if (first && _withinCapOfRangeStart(ce.time)) {
      _devices.add(
        DeviceSession(
          room: room,
          start: rangeStart,
          end: ce.time,
          startClipped: true,
          deviceId: id,
          deviceType: m.deviceType ?? '',
          endKind: SessionEnd.stopped,
          endEvent: ce.event,
        ),
      );
    } else {
      _orphanStops++;
    }
  }

  void _onInput(ClassifiedEvent ce, ClassifiedMetric m) {
    _checkStartupSelection(ce);
    final key = m.inputKey!;
    final open = _input;
    if (open != null && _inputKey == key) {
      open.selections++;
      return;
    }
    if (open != null) _closeInput(ce.time, SessionEnd.switched);
    _input = _Open(ce.time, ce.event)..inputLabel = m.inputLabel ?? key;
    _inputKey = key;
  }

  void _onInputStop(ClassifiedEvent ce, ClassifiedMetric m) {
    // Ends the source's time on screen; a Stopped for any other source has
    // nothing to end.
    if (_input != null && _inputKey == m.inputKey) {
      _closeInput(ce.time, SessionEnd.stopped);
    }
  }

  void _onMute(ClassifiedEvent ce, ClassifiedMetric m) {
    final name = m.muteName!;
    final first = _seenMute.add(name);
    if (m.isStart) {
      if (_mute.containsKey(name)) {
        _duplicateStarts++;
        return;
      }
      _mute[name] = _Open(ce.time, ce.event);
      return;
    }
    if (_mute.containsKey(name)) {
      _closeMute(name, ce.time, SessionEnd.stopped);
    } else if (first && _withinCapOfRangeStart(ce.time)) {
      _mutes.add(
        MuteSession(
          room: room,
          start: rangeStart,
          end: ce.time,
          startClipped: true,
          name: name,
          endKind: SessionEnd.stopped,
        ),
      );
    }
    // A later unmatched unmute is normal (state sync at startup) and is not
    // counted as an orphan.
  }

  void _closeSystem(
    DateTime end,
    OffReason reason,
    MetricEvent? endEvent, [
    String? reasonText,
  ]) {
    final o = _sys!;
    _system.add(
      SystemSession(
        room: room,
        start: o.start,
        end: end,
        startSource: o.source,
        offReason: reason,
        startReason: o.reason,
        offReasonText: reasonText,
        startEvent: o.event,
        endEvent: endEvent,
      ),
    );
    _sys = null;
  }

  void _closeDevice(
    String id,
    DateTime end,
    SessionEnd kind,
    MetricEvent? endEvent,
  ) {
    final o = _dev.remove(id)!;
    _devices.add(
      DeviceSession(
        room: room,
        start: o.start,
        end: end,
        deviceId: id,
        deviceType: o.deviceType,
        endKind: kind,
        startEvent: o.event,
        endEvent: endEvent,
      ),
    );
  }

  void _closeInput(DateTime end, SessionEnd kind) {
    final o = _input!;
    _inputs.add(
      InputSession(
        room: room,
        start: o.start,
        end: end,
        inputKey: _inputKey!,
        inputLabel: o.inputLabel,
        selections: o.selections,
        endKind: kind,
      ),
    );
    _input = null;
    _inputKey = null;
  }

  void _closeMute(String name, DateTime end, SessionEnd kind) {
    final o = _mute.remove(name)!;
    _mutes.add(
      MuteSession(
        room: room,
        start: o.start,
        end: end,
        name: name,
        endKind: kind,
      ),
    );
  }

  /// Closes everything still open at the range end (or at the cap, if that
  /// comes first) and returns the result.
  RoomSessions finish() {
    _expire(rangeEnd);
    final sys = _sys;
    if (sys != null) _closeSystem(rangeEnd, OffReason.truncated, null);
    for (final id in _dev.keys.toList()) {
      final o = _dev[id]!;
      if (o.pastCap) {
        // No Stopped by the end of the data, already past the cap: treat it
        // as lost, as for system sessions.
        _closeDevice(id, _capOf(o.start), SessionEnd.capped, null);
      } else {
        _closeDevice(id, rangeEnd, SessionEnd.ongoing, null);
      }
    }
    if (_input != null) _closeInput(rangeEnd, SessionEnd.ongoing);
    for (final name in _mute.keys.toList()) {
      _closeMute(name, rangeEnd, SessionEnd.ongoing);
    }
    int byStart(Session a, Session b) {
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.end.compareTo(b.end);
    }

    _devices.sort((a, b) {
      final c = byStart(a, b);
      return c != 0 ? c : a.deviceId.compareTo(b.deviceId);
    });
    _mutes.sort((a, b) {
      final c = byStart(a, b);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    _system.sort(byStart);
    _inputs.sort(byStart);
    return RoomSessions(
      room: room,
      system: List.unmodifiable(_system),
      devices: List.unmodifiable(_devices),
      inputs: List.unmodifiable(_inputs),
      mutes: List.unmodifiable(_mutes),
      powerOnEvents: List.unmodifiable(_powerOn),
      reboots: _reboots,
      orphanStops: _orphanStops,
      duplicateStarts: _duplicateStarts,
      automaticInputStarts: Set.unmodifiable(_automatic),
    );
  }
}
