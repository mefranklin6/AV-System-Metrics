// Maps raw (metric, action) pairs from `metric_events` to typed meanings.
// Pure Dart: no Flutter imports, safe inside isolates.
//
// The recognition rules follow the "Event conventions" table of
// `Implementation_Guide.md` at the repository root. Every name list and
// pattern comes from [ClassifierConfig], so a program that uses other names
// can be matched in Settings without code changes.

import '../data/models.dart';
import 'config.dart';

/// Broad meaning of one metric event.
enum EventCategory {
  /// A source was routed to the main display(s): `Source - <name>`,
  /// `Source: <name>`, `Source Select: <name>`, `Input - <name>`,
  /// `Input: <name>` with `Started` or `Trace`, or a bare name from
  /// [ClassifierConfig.inputNames]. `Stopped` ends the source's time on
  /// screen.
  input,

  /// A device powered on/off: `<Device> <n>`, `<Device>_<n>`,
  /// `<Device> <n> Power` or `<Device> Power` with `Started` / `Stopped`.
  device,

  /// The room system was powered on or off: a name from
  /// [ClassifierConfig.systemPowerNames] (`System Power`, `System`), alone
  /// or followed by ` - <reason>`, with `Started` / `Stopped`.
  systemPower,

  /// Processor and room lifecycle markers: program start (`Program Start`,
  /// `Initialize`, ...) and the optional startup / shutdown complete traces.
  lifecycle,

  /// Help-labelled event: the metric contains the word `help`, whatever the
  /// action. Nothing is assumed about what the control does.
  help,

  /// A mute turned on (`Started`, or action `Muted`) or off (`Stopped`, or
  /// action `Unmuted`): metric `<Channel> Mute` / `<Channel> Muted`, or any
  /// metric with action `Muted` / `Unmuted`.
  mute,

  /// A volume level was set: action `Level <number>` followed by any text.
  volume,

  /// A wireless presentation share: action `Share`; the metric is kept as
  /// logged.
  share,

  /// A touch-panel or keypad control was used; action `Trace`, metric
  /// `<Control> <Pressed|Released|Tapped|Held|Repeated>`.
  uiTrace,

  /// Device communication up or down (action `Connected` / `Disconnected`).
  connection,

  /// Server maintenance/update traces from the synthetic `AVSM-System`
  /// client. Never treated as a room.
  adminLifecycle,

  /// An uptime ping. Datasets normally store these as heartbeat buckets
  /// instead; this only appears if a source passes them through as events.
  heartbeat,

  /// Anything not recognised (custom actions and traces). Listed in the
  /// data-quality output so the configuration can be extended.
  other,
}

/// Whether the action was `Started`, `Stopped` or something else.
enum EventPhase { started, stopped, none }

/// The reason group of a system power event, read from the text after the
/// dash (`System Power - <reason>`). See
/// [ClassifierConfig.powerReasonSynonyms].
enum PowerSource {
  /// `User` and its synonyms.
  user,

  /// `Inactivity`, `Idle`, `Timeout` and their synonyms.
  inactivity,

  /// `Schedule`, `Scheduled` and their synonyms.
  scheduled,

  /// `Restore`, `Recovery` and their synonyms: the program turned the room
  /// back on by itself after a restart or power loss.
  restore,

  /// `Remote` and its synonyms.
  remote,

  /// A reason in none of the groups. The text is kept verbatim in
  /// [ClassifiedMetric.powerReason].
  other,

  /// No reason was logged (`System Power` on its own), or the session was
  /// opened by a startup-complete trace.
  unknown,
}

/// Which lifecycle event a [EventCategory.lifecycle] event is.
enum LifecycleKind {
  /// A program start name with `Started` or `Trace`: the control program
  /// started (processor boot or program load). Every open session in the
  /// room is closed at this moment.
  programStart,

  /// A program start name with `Stopped` (some programs log the end of
  /// their start-up this way). Kept for the timeline only.
  programStartStopped,

  /// A startup-complete trace ([ClassifierConfig.startupCompleteNames]).
  startupComplete,

  /// A shutdown-complete trace ([ClassifierConfig.shutdownCompleteNames]).
  shutdownComplete,
}

/// The event word at the end of a control trace metric.
enum UiEventKind { pressed, tapped, held, repeated, released }

/// The parsed meaning of one distinct (metric, action) pair.
///
/// Instances are cached per distinct pair by [MetricClassifier], so a
/// dataset of a million events only parses a few hundred strings.
class ClassifiedMetric {
  const ClassifiedMetric._({
    required this.category,
    this.phase = EventPhase.none,
    this.deviceId,
    this.deviceType,
    this.deviceNumber,
    this.inputKey,
    this.inputLabel,
    this.powerSource,
    this.powerReason,
    this.lifecycle,
    this.controlName,
    this.uiEvent,
    this.isNavigation = false,
    this.isSlider = false,
    this.isRepeatable = false,
    this.volumeLevel,
    this.volumeDb,
    this.volumeName,
    this.shareStation,
    this.muteName,
    this.connected,
    this.connectionTarget,
  });

  /// Shared instance for unrecognised events.
  static const ClassifiedMetric unknown = ClassifiedMetric._(
    category: EventCategory.other,
  );

  /// Shared instance for `AVSM-System` events.
  static const ClassifiedMetric admin = ClassifiedMetric._(
    category: EventCategory.adminLifecycle,
  );

  final EventCategory category;

  /// `Started` / `Stopped` / other. Action `Muted` is [EventPhase.started]
  /// and `Unmuted` is [EventPhase.stopped].
  final EventPhase phase;

  /// Device metric exactly as logged, such as `Projector 1`
  /// ([EventCategory.device] only).
  final String? deviceId;

  /// Upper-case device type read by the device pattern, such as
  /// `PROJECTOR`. Used for grouping and rated-life lookup.
  final String? deviceType;

  /// Device number, such as `1` for `Projector 1` or `Display 1 Power`.
  final int? deviceNumber;

  /// Lower-case form of [inputLabel], such as `hdmi 1` or `document camera`
  /// ([EventCategory.input] only). Sources with the same name are the same
  /// source, whichever form logged them (`Source - Document Camera` and the
  /// bare name `doc_cam` share the key `document camera`).
  final String? inputKey;

  /// Display label for the source: the name as logged after a source
  /// prefix (`HDMI 1`), or a readable form of a bare name (`doc_cam` ->
  /// `Document Camera`).
  final String? inputLabel;

  /// [EventCategory.systemPower] only.
  final PowerSource? powerSource;

  /// The reason text after the dash, exactly as logged (`User`,
  /// `User Reset`); null when none was logged.
  final String? powerReason;

  /// [EventCategory.lifecycle] only.
  final LifecycleKind? lifecycle;

  /// Control name without the event word, such as `Volume Up`. Set for
  /// [EventCategory.uiTrace] and for help-labelled events in the same form
  /// (`Help Pressed`).
  final String? controlName;

  /// The event word of a control trace; see [controlName].
  final UiEventKind? uiEvent;

  /// The control matches [ClassifierConfig.navigationButtonPattern].
  final bool isNavigation;

  /// The control name contains `Slider`, `Sldr` or `Fader` as a part.
  final bool isSlider;

  /// The control matches [ClassifierConfig.repeatableControlPattern]: its
  /// name suggests it is meant to be pressed repeatedly. The repeated-press
  /// detector needs [MetricClassifier.repeatableMashMultiplier] times more
  /// presses for these.
  final bool isRepeatable;

  /// Volume level from the action, clamped to 0-100
  /// ([EventCategory.volume] only).
  final int? volumeLevel;

  /// Device gain in dB when logged as `(Device <dB>)`, such as `-20.0`.
  final double? volumeDb;

  /// Volume metric, such as `Program Audio Volume`.
  final String? volumeName;

  /// Share metric exactly as logged ([EventCategory.share] only).
  final String? shareStation;

  /// Mute channel: the metric without a trailing ` Mute` / ` Muted`
  /// (`Program Audio Mute` -> `Program Audio`), or the whole metric for
  /// actions `Muted` / `Unmuted`.
  final String? muteName;

  /// `true` for `Connected`, `false` for `Disconnected`
  /// ([EventCategory.connection] only).
  final bool? connected;

  /// Metric of a connection event (what connected), such as `Projector 1`.
  final String? connectionTarget;

  /// Shorthand for [phase] == [EventPhase.started].
  bool get isStart => phase == EventPhase.started;

  /// Shorthand for [phase] == [EventPhase.stopped].
  bool get isStop => phase == EventPhase.stopped;

  /// A control event that counts as one press. Only `Pressed` counts:
  /// panels often log `Tapped` or `Released` for the same press, and `Held`
  /// / `Repeated` describe the same physical press.
  bool get isPress => uiEvent == UiEventKind.pressed;

  /// A control event in `<Control> <event word>` form (a [EventCategory.uiTrace]
  /// event or a help-labelled control).
  bool get isControl => uiEvent != null;

  /// A source selection: [EventCategory.input] with `Started` or `Trace`.
  bool get isSourceSelection =>
      category == EventCategory.input && phase != EventPhase.stopped;
}

/// One event together with its classification. Produced once per event by
/// the engine and shared by every analysis stage.
class ClassifiedEvent {
  const ClassifiedEvent(this.event, this.meaning);

  final MetricEvent event;
  final ClassifiedMetric meaning;

  DateTime get time => event.timestamp;
}

/// Classifies metric events and derives building names from client names.
///
/// Regular expressions are compiled once per classifier and results are
/// cached per distinct (metric, action) pair, so classification is O(1)
/// amortised per event. Invalid user-supplied patterns fall back to the
/// defaults and add a message to [warnings].
class MetricClassifier {
  MetricClassifier([this.config = const ClassifierConfig()])
    : _inputNames = _nameSet(config.inputNames),
      _programStart = _nameSet(config.programStartNames),
      _startupComplete = _nameSet(config.startupCompleteNames),
      _shutdownComplete = _nameSet(config.shutdownCompleteNames),
      _systemPower = [
        for (final n in _nameSet(config.systemPowerNames)) n,
      ]..sort((a, b) => b.length.compareTo(a.length)),
      _reasons = {
        for (final e in config.powerReasonSynonyms.entries)
          for (final word in e.value)
            if (word.trim().isNotEmpty)
              _norm(word).toLowerCase(): _groupOf(e.key),
      } {
    _device = _compile(
      config.devicePattern,
      ClassifierConfig.defaultDevicePattern,
      'device pattern',
    );
    _navigation = _compile(
      config.navigationButtonPattern,
      ClassifierConfig.defaultNavigationButtonPattern,
      'navigation pattern',
    );
    _repeatable = _compile(
      config.repeatableControlPattern,
      ClassifierConfig.defaultRepeatableControlPattern,
      'repeatable control pattern',
    );
    _help = _compile(
      config.helpPattern,
      ClassifierConfig.defaultHelpPattern,
      'help pattern',
    );
    _building = _compile(
      config.buildingPattern,
      ClassifierConfig.defaultBuildingPattern,
      'building pattern',
    );
    _sourcePrefixes = [
      for (final p in config.sourcePrefixes)
        if (p.trim().isNotEmpty) _prefixRegex(p),
    ];
  }

  /// Client names (compared case-insensitively) that are server-side
  /// pseudo-clients rather than rooms.
  static const Set<String> adminClientNames = {'avsm-system'};

  /// Controls matching [ClassifierConfig.repeatableControlPattern] need
  /// this many times the normal press count before repeated presses are
  /// reported.
  static const int repeatableMashMultiplier = 3;

  static final RegExp _slider = RegExp(
    r'(^|[\s_\-])(Slider|Sldr|Fader)([\s_\-]|$)',
    caseSensitive: false,
  );
  static final RegExp _lastNumber = RegExp(r'(\d+)\D*$');
  static final RegExp _spaces = RegExp(r'\s+');
  static final RegExp _volumeAction = RegExp(
    r'^Level\s+(-?\d+(?:\.\d+)?)(?:\s*\(\s*Device\s+(-?\d+(?:\.\d+)?)\s*\))?',
    caseSensitive: false,
  );
  static final RegExp _muteSuffix = RegExp(
    r'^(.*\S)\s+Muted?$',
    caseSensitive: false,
  );

  static const Map<String, String> _knownInputLabels = {
    'pc': 'PC',
    'pc_extended': 'PC Extended',
    'hdmi': 'HDMI',
    'usb': 'USB',
    'vga': 'VGA',
    'wireless': 'Wireless',
    'doc_cam': 'Document Camera',
    'inst_cam': 'Instructor Camera',
    'aud_cam': 'Audience Camera',
    'sub_switcher': 'Sub-Switcher',
    'dvd': 'DVD',
    'blu_ray': 'Blu-ray',
    'custom_input': 'Custom Input',
    'laptop': 'Laptop',
    'individual': 'Individual',
  };

  final ClassifierConfig config;
  final Set<String> _inputNames;
  final Set<String> _programStart;
  final Set<String> _startupComplete;
  final Set<String> _shutdownComplete;

  /// Lower-case system power names, longest first.
  final List<String> _systemPower;

  /// Lower-case reason word -> group.
  final Map<String, PowerSource> _reasons;
  late final RegExp _device;
  late final RegExp _navigation;
  late final RegExp _repeatable;
  late final RegExp _help;
  late final RegExp _building;
  late final List<RegExp> _sourcePrefixes;

  /// Problems found while compiling the configuration (for display).
  final List<String> warnings = [];

  final Map<String, Map<String, ClassifiedMetric>> _cache = {};
  final Map<String, String> _buildingCache = {};

  /// Trims and collapses runs of whitespace to one space.
  static String _norm(String s) => s.trim().replaceAll(_spaces, ' ');

  static Set<String> _nameSet(List<String> names) => {
    for (final n in names)
      if (n.trim().isNotEmpty) _norm(n).toLowerCase(),
  };

  static PowerSource _groupOf(String key) => switch (key) {
    'user' => PowerSource.user,
    'scheduled' || 'schedule' => PowerSource.scheduled,
    'inactivity' => PowerSource.inactivity,
    'remote' => PowerSource.remote,
    'restore' => PowerSource.restore,
    _ => PowerSource.other,
  };

  /// `Source -` -> `^Source\s*-\s*(.+)$`: spaces in the prefix are optional
  /// and may be repeated.
  static RegExp _prefixRegex(String prefix) {
    final parts = _norm(prefix).split(' ').map(RegExp.escape);
    return RegExp('^${parts.join(r'\s*')}\\s*(.*\\S)\\s*\$', caseSensitive: false);
  }

  RegExp _compile(String pattern, String fallback, String what) {
    try {
      return RegExp(pattern, caseSensitive: false);
    } on FormatException {
      warnings.add(
        'The $what "$pattern" is not a valid regular expression; '
        'the default was used instead.',
      );
      return RegExp(fallback, caseSensitive: false);
    }
  }

  /// Whether [clientName] is a server pseudo-client such as `AVSM-System`.
  static bool isAdminClient(String clientName) =>
      adminClientNames.contains(clientName.toLowerCase());

  /// Human label for a bare source name: `doc_cam` -> `Document Camera`,
  /// `station_2_laptop` -> `Station 2 Laptop`, `my_input` -> `My Input`.
  static String inputLabelFor(String key) {
    final lower = key.toLowerCase();
    final known = _knownInputLabels[lower];
    if (known != null) return known;
    return lower
        .split(RegExp(r'[_\s]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  /// Building code for a client: first capture group of
  /// [ClassifierConfig.buildingPattern], upper-cased (`Holt_171` -> `HOLT`).
  /// Falls back to the whole client name upper-cased when nothing matches.
  String buildingOf(String clientName) {
    return _buildingCache.putIfAbsent(clientName, () {
      final m = _building.firstMatch(clientName);
      if (m != null) {
        final g = m.groupCount >= 1 ? m.group(1) : m.group(0);
        if (g != null && g.trim().isNotEmpty) return g.trim().toUpperCase();
      }
      return clientName.toUpperCase();
    });
  }

  /// Classifies one event, taking the sending client into account
  /// (`AVSM-System` events are [EventCategory.adminLifecycle]).
  ClassifiedMetric classifyEvent(MetricEvent e) => isAdminClient(e.clientName)
      ? ClassifiedMetric.admin
      : classify(e.metric, e.action);

  /// Classifies a (metric, action) pair. Cached.
  ClassifiedMetric classify(String metric, String action) {
    final byAction = _cache.putIfAbsent(metric, () => {});
    return byAction.putIfAbsent(action, () => _classify(metric, action));
  }

  ClassifiedMetric _classify(String rawMetric, String rawAction) {
    final metric = _norm(rawMetric);
    final action = _norm(rawAction);
    final actionLower = action.toLowerCase();
    final metricLower = metric.toLowerCase();
    final phase = switch (actionLower) {
      'started' => EventPhase.started,
      'stopped' => EventPhase.stopped,
      _ => EventPhase.none,
    };
    final isTrace = actionLower == 'trace';

    if (actionLower == heartbeatAction.toLowerCase()) {
      return const ClassifiedMetric._(category: EventCategory.heartbeat);
    }

    // Help-labelled: any action. Control fields are kept when the metric is
    // in control form, so such presses also appear in control statistics.
    if (_help.hasMatch(metric)) {
      final control = isTrace ? _control(metric) : null;
      return ClassifiedMetric._(
        category: EventCategory.help,
        phase: phase,
        controlName: control?.$1,
        uiEvent: control?.$2,
      );
    }

    if (actionLower == 'connected' || actionLower == 'disconnected') {
      return ClassifiedMetric._(
        category: EventCategory.connection,
        connected: actionLower == 'connected',
        connectionTarget: metric,
      );
    }

    if (actionLower == 'muted' || actionLower == 'unmuted') {
      return ClassifiedMetric._(
        category: EventCategory.mute,
        phase: actionLower == 'muted' ? EventPhase.started : EventPhase.stopped,
        muteName: metric,
      );
    }

    final vm = _volumeAction.firstMatch(action);
    if (vm != null) {
      final level = num.tryParse(vm.group(1)!)?.round();
      final db = vm.group(2) == null ? null : double.tryParse(vm.group(2)!);
      return ClassifiedMetric._(
        category: EventCategory.volume,
        volumeLevel: level?.clamp(0, 100),
        volumeDb: db,
        volumeName: metric,
      );
    }

    if (actionLower == 'share') {
      return ClassifiedMetric._(
        category: EventCategory.share,
        shareStation: metric,
      );
    }

    if (phase != EventPhase.none) {
      final power = _systemPowerReason(metric, metricLower);
      if (power != null) {
        final reason = power.isEmpty ? null : power;
        return ClassifiedMetric._(
          category: EventCategory.systemPower,
          phase: phase,
          powerSource: reason == null
              ? PowerSource.unknown
              : _reasons[reason.toLowerCase()] ?? PowerSource.other,
          powerReason: reason,
        );
      }
      if (_programStart.contains(metricLower)) {
        return ClassifiedMetric._(
          category: EventCategory.lifecycle,
          phase: phase,
          lifecycle: phase == EventPhase.started
              ? LifecycleKind.programStart
              : LifecycleKind.programStartStopped,
        );
      }
      final mute = _muteSuffix.firstMatch(metric);
      if (mute != null) {
        return ClassifiedMetric._(
          category: EventCategory.mute,
          phase: phase,
          muteName: mute.group(1),
        );
      }
      final source = _source(metric, metricLower, phase);
      if (source != null) return source;
      final dm = _device.firstMatch(metric);
      if (dm != null) {
        String? rawType;
        for (var g = 1; g <= dm.groupCount; g++) {
          final v = dm.group(g);
          if (v != null && v.trim().isNotEmpty) {
            rawType = v;
            break;
          }
        }
        rawType ??= metric.replaceAll(RegExp(r'[_\-\s]*\d+\D*$'), '');
        final type = _norm(rawType.replaceAll(RegExp(r'[_\-]+'), ' '))
            .toUpperCase();
        final number = _lastNumber.firstMatch(metric)?.group(1);
        return ClassifiedMetric._(
          category: EventCategory.device,
          phase: phase,
          deviceId: metric,
          deviceType: type.isEmpty ? metric.toUpperCase() : type,
          deviceNumber: number == null ? null : int.tryParse(number),
        );
      }
      return ClassifiedMetric._(category: EventCategory.other, phase: phase);
    }

    if (isTrace) {
      if (_programStart.contains(metricLower)) {
        return const ClassifiedMetric._(
          category: EventCategory.lifecycle,
          lifecycle: LifecycleKind.programStart,
        );
      }
      if (_startupComplete.contains(metricLower)) {
        return const ClassifiedMetric._(
          category: EventCategory.lifecycle,
          lifecycle: LifecycleKind.startupComplete,
        );
      }
      if (_shutdownComplete.contains(metricLower)) {
        return const ClassifiedMetric._(
          category: EventCategory.lifecycle,
          lifecycle: LifecycleKind.shutdownComplete,
        );
      }
      final source = _source(metric, metricLower, phase);
      if (source != null) return source;
      final control = _control(metric);
      if (control != null) {
        final (name, kind) = control;
        final slider = _slider.hasMatch(name);
        return ClassifiedMetric._(
          category: EventCategory.uiTrace,
          controlName: name,
          uiEvent: kind,
          isNavigation: _navigation.hasMatch(name),
          isSlider: slider,
          isRepeatable: slider || _repeatable.hasMatch(name),
        );
      }
    }

    return ClassifiedMetric.unknown;
  }

  /// The reason text ('' when none) when [metric] is a system power name,
  /// alone or followed by a dash and a reason; otherwise null.
  String? _systemPowerReason(String metric, String metricLower) {
    for (final name in _systemPower) {
      if (metricLower == name) return '';
      if (!metricLower.startsWith(name)) continue;
      final rest = metric.substring(name.length).trimLeft();
      if (rest.startsWith('-')) return rest.substring(1).trim();
    }
    return null;
  }

  /// A source selection by prefix or bare name, or null.
  ClassifiedMetric? _source(String metric, String metricLower, EventPhase p) {
    for (final re in _sourcePrefixes) {
      final m = re.firstMatch(metric);
      if (m == null) continue;
      final name = _norm(m.group(1)!);
      return ClassifiedMetric._(
        category: EventCategory.input,
        phase: p,
        inputKey: name.toLowerCase(),
        inputLabel: name,
      );
    }
    if (_inputNames.contains(metricLower)) {
      final label = inputLabelFor(metricLower);
      return ClassifiedMetric._(
        category: EventCategory.input,
        phase: p,
        inputKey: label.toLowerCase(),
        inputLabel: label,
      );
    }
    return null;
  }

  /// Splits `<Control> <event word>`, or returns null.
  static (String, UiEventKind)? _control(String metric) {
    final space = metric.lastIndexOf(' ');
    if (space <= 0) return null;
    final control = metric.substring(0, space).trim();
    final kind = switch (metric.substring(space + 1).toLowerCase()) {
      'pressed' => UiEventKind.pressed,
      'tapped' => UiEventKind.tapped,
      'held' => UiEventKind.held,
      'repeated' => UiEventKind.repeated,
      'released' => UiEventKind.released,
      _ => null,
    };
    if (kind == null || control.isEmpty) return null;
    return (control, kind);
  }
}
