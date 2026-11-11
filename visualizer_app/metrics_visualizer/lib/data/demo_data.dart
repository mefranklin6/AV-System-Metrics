// Deterministic synthetic campus for demos, screenshots and tests.
//
// Pure Dart (no Flutter imports). The same `end` and `seed` always produce the
// same dataset. Most rooms log the recommended names from
// `Implementation_Guide.md` (`System Power - User`, `Source - HDMI`,
// `Projector 1`, `Program Start`, `Volume Up Pressed`, `Microphone Mute`,
// ...). The rooms in [demoLegacyRooms] log the "also recognized" forms
// instead (`System - User`, bare source names such as `hdmi`, `Projector_1`,
// `Initialize`, `Btn_Volume_Up Pressed`, `Microphone Muted`), so both
// recognition paths are visible. The generator injects every pattern the
// analytics engine detects, so each screen has something to show:
//
// * weekday class schedules with fewer evening and Friday classes, rare
//   weekend use and a usage trend that grows week over week;
// * an automatic default source at power-on in the recommended-name rooms,
//   and source selections where PC dominates and DVD / Blu-ray are almost
//   never selected;
// * projectors, displays and cameras with Started/Stopped sessions;
// * the power reasons User, Inactivity, Schedule, Remote and Restore,
//   program starts, and a `Started` while the system is already on;
// * mutes, volume levels, control and slider traces, help-labelled events
//   and wireless shares;
// * Connected/Disconnected device events;
// * hourly heartbeats limited to the last 30 days (server retention) with a
//   room that stops sending them and a room with a several-hour gap;
// * injected patterns: repeated power cycling, repeated presses of one
//   control, rapid navigation presses, rapid source changes, repeated
//   connection changes, a long device session and clusters of help-labelled
//   events;
// * the synthetic `AVSM-System` client with server lifecycle traces.

import 'dart:math';

import 'models.dart';

/// Default seed; any int works.
const int demoSeed = 20261110;

/// Heartbeat retention used for the demo, like the server default.
const int demoHeartbeatRetentionDays = 30;

/// The rooms in the demo campus, grouped by building prefix.
const List<String> demoRooms = [
  'BSS_108', 'BSS_112', 'BSS_238', 'BSS_241', 'BSS_245', //
  'Holt_171', 'HOLT_155', 'HOLT_185', 'Holt_210', //
  'ARTS_107', 'ARTS_120', 'Arts_215', //
  'AJH_125A', 'AJH_130', 'AJH_204', //
  'SCI_101', 'SCI_150', 'Sci_220', 'SCI_305', //
  'LIB_014', 'LIB_120', 'LIB_201', 'LIB_202', 'LIB_310',
];

/// Rooms that log the "also recognized" (legacy) names from
/// `Implementation_Guide.md` instead of the recommended ones.
const Set<String> demoLegacyRooms = {'BSS_112', 'ARTS_120'};

/// Rooms that carry the injected patterns, so tests and docs can refer to
/// them.
abstract final class DemoScenario {
  static const rapidPowerCycling = 'HOLT_155';
  static const repeatedPresses = 'BSS_245';
  static const rapidNavigation = 'ARTS_107';
  static const rapidSourceChanges = 'SCI_150';
  static const connectionFlapping = 'AJH_125A';
  static const longDeviceSession = 'LIB_120';

  /// Stops sending heartbeats and events [offlineDays] before the end.
  static const heartbeatGapRoom = 'Sci_220';

  /// Has a several-hour gap in heartbeats and events.
  static const outageRoom = 'HOLT_185';

  /// Logs help-labelled events far more often than other rooms (legacy
  /// names: `Btn_Help Pressed` plus `Help` Started / Stopped).
  static const helpEvents = 'BSS_112';

  /// Logs a system power `Started` while the system is already on (legacy
  /// names).
  static const startedWhileOnRoom = 'ARTS_120';

  /// Has a program start mid-session followed by `System Power - Restore`.
  static const restoreRoom = 'Holt_171';
  static const activeLearningRoom = 'LIB_201';

  /// How many days before the dataset end [heartbeatGapRoom] went silent.
  static const offlineDays = 5;
}

/// Builds the demo dataset covering [weeks] whole weeks that end at [end]
/// (default: the start of the current UTC day).
Dataset generateDemoDataset({DateTime? end, int seed = demoSeed, int weeks = 10}) =>
    _DemoGenerator(
      end: _startOfUtcDay(end ?? DateTime.now().toUtc()),
      seed: seed,
      weeks: weeks,
    ).build();

/// Isolate-friendly entry point: [endMicros] is the end as microseconds
/// since epoch (UTC).
Dataset generateDemoDatasetFromMicros(int endMicros) => generateDemoDataset(
    end: DateTime.fromMicrosecondsSinceEpoch(endMicros, isUtc: true));

/// Unlike String.hashCode this is identical on every platform (the
/// intermediate values stay below 2^53, so web numbers are exact too), which
/// keeps the demo identical on desktop and web.
int _stableHash(String s) {
  var h = 7;
  for (final c in s.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

DateTime _startOfUtcDay(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

class _RoomProfile {
  _RoomProfile({
    required this.name,
    required this.legacy,
    required this.projectors,
    required this.displays,
    required this.cameras,
    required this.busyness,
    required this.inputWeights,
    required this.mics,
    required this.stations,
  });

  final String name;

  /// Logs the "also recognized" names instead of the recommended ones.
  final bool legacy;
  final int projectors;
  final int displays;
  final int cameras;
  final double busyness;

  /// Source keys (see [_sourceNames]) and their selection weights.
  final Map<String, double> inputWeights;

  /// Microphone mute channels, such as `Microphone`.
  final List<String> mics;
  final int stations;

  List<String> get devices => [
        for (var i = 1; i <= projectors; i++) device('Projector', i),
        for (var i = 1; i <= displays; i++) device('Display', i),
      ];

  // ---- names: the recommended form, or the legacy form for legacy rooms

  String device(String type, int n) => legacy ? '${type}_$n' : '$type $n';

  String power(String reason) => legacy ? 'System - $reason' : 'System Power - $reason';

  String get programStart => legacy ? 'Initialize' : 'Program Start';

  String get startupComplete => legacy ? 'System Startup Sequence Complete' : 'System Startup Complete';

  String get shutdownComplete => legacy ? 'System Shutdown Sequence Complete' : 'System Shutdown Complete';

  /// Source metric for a source key.
  String source(String key) => legacy ? key : 'Source - ${_sourceNames[key] ?? key}';

  /// Control name (without the event word) for a control id.
  String control(String id) => legacy ? (_legacyControls[id] ?? 'Btn_$id') : (_controls[id] ?? id);

  /// Mute metric for a channel such as `Microphone`.
  String mute(String channel) => legacy ? '$channel Muted' : '$channel Mute';

  String volume(int level) => legacy
      ? 'Level $level (Device ${(-20 + (level - 50) * 0.4).toStringAsFixed(1)})'
      : 'Level $level';

  static final Map<String, String> _sourceNames = {
    'pc': 'PC',
    'hdmi': 'HDMI',
    'wireless': 'Wireless',
    'doc_cam': 'Document Camera',
    'usb': 'USB',
    'pc_extended': 'PC Extended',
    'inst_cam': 'Instructor Camera',
    'vga': 'VGA',
    'aud_cam': 'Audience Camera',
    'sub_switcher': 'Sub-Switcher',
    'dvd': 'DVD',
    'blu_ray': 'Blu-ray',
    'custom_input': 'Custom Input',
    for (var i = 1; i <= 4; i++) 'station_$i': 'Station $i',
    for (var i = 1; i <= 4; i++) 'station_${i}_laptop': 'Station $i Laptop',
  };

  static const Map<String, String> _controls = {
    'power_on': 'Power On',
    'power_off': 'Power Off',
    'power_off_confirm': 'Power Off Confirm',
    'volume_up': 'Volume Up',
    'volume_down': 'Volume Down',
    'volume_slider': 'Volume Slider',
    'video_mute': 'Video Mute',
    'mic_mute': 'Mic Mute',
    'camera_page': 'Camera Page',
    'audio_page': 'Audio Page',
    'display_page': 'Display Page',
    'settings_menu': 'Settings Menu',
    'home': 'Home',
    'back': 'Back',
    'help': 'Help',
  };

  static const Map<String, String> _legacyControls = {
    'power_on': 'Btn_Start',
    'power_off': 'Btn_Power_Down',
    'power_off_confirm': 'Btn_Power_Down_Confirm',
    'volume_up': 'Btn_Volume_Up',
    'volume_down': 'Btn_Volume_Down',
    'volume_slider': 'Sldr_Volume',
    'video_mute': 'Btn_Video_Mute',
    'mic_mute': 'Btn_Mic_Mute',
    'camera_page': 'Btn_Inst_Cam_Nav',
    'audio_page': 'Btn_Audio_Nav',
    'display_page': 'Btn_Display_Nav',
    'settings_menu': 'Btn_Settings_Menu',
    'home': 'Btn_Home_Page',
    'back': 'Btn_Back',
    'help': 'Btn_Help',
  };
}

class _DemoGenerator {
  _DemoGenerator({required this.end, required int seed, required this.weeks})
      : rng = Random(seed),
        start = end.subtract(Duration(days: weeks * 7));

  final DateTime end;
  final DateTime start;
  final int weeks;
  final Random rng;
  final List<MetricEvent> events = [];
  final Map<String, Map<int, int>> heartbeatHours = {};

  /// Campus wall clock is UTC-8 (Pacific standard time, no DST for
  /// simplicity), matching the production sample.
  static const Duration campusOffset = Duration(hours: -8);

  static const Map<String, double> _baseInputs = {
    'pc': 40,
    'hdmi': 18,
    'wireless': 12,
    'doc_cam': 10,
    'usb': 6,
    'pc_extended': 4,
    'inst_cam': 3,
    'vga': 2,
    'aud_cam': 1,
    'sub_switcher': 1,
    'dvd': 0.25,
    'blu_ray': 0.15,
  };

  late final List<_RoomProfile> rooms = [
    for (final name in demoRooms) _profileFor(name),
  ];

  late final Map<String, _RoomProfile> _profiles = {for (final p in rooms) p.name: p};

  _RoomProfile _profileFor(String name) {
    final weights = Map<String, double>.of(_baseInputs);
    // Variety between rooms: some lack legacy inputs, art rooms love doc cams.
    if (name.startsWith('ARTS') || name.startsWith('Arts')) {
      weights['doc_cam'] = 22;
    }
    if (name.startsWith('LIB')) {
      weights.remove('vga');
      weights['wireless'] = 20;
    }
    var stations = 0;
    if (name == DemoScenario.activeLearningRoom) {
      stations = 4;
      weights
        ..clear()
        ..addAll({
          'pc': 20,
          'wireless': 10,
          for (var i = 1; i <= 4; i++) 'station_$i': 8,
          for (var i = 1; i <= 4; i++) 'station_${i}_laptop': 4,
          'custom_input': 1,
        });
    }
    final h = _stableHash(name);
    return _RoomProfile(
      name: name,
      legacy: demoLegacyRooms.contains(name),
      projectors: name.startsWith('LIB_0') ? 0 : (h % 3 == 0 ? 2 : 1),
      displays: name.startsWith('LIB_0') ? 2 : (h % 5 == 0 ? 1 : 0),
      cameras: name.startsWith('SCI') || name.startsWith('BSS') ? 2 : (h % 4 == 0 ? 1 : 0),
      busyness: 0.45 + (h % 50) / 100.0,
      inputWeights: weights,
      mics: [
        'Microphone',
        if (h % 2 == 0) 'Ceiling Microphones',
        if (h % 7 == 0) 'VoiceLift In-Room',
      ],
      stations: stations,
    );
  }

  // ------------------------------------------------------------- helpers

  DateTime _local(DateTime day, int hour, int minute, [int second = 0]) =>
      DateTime.utc(day.year, day.month, day.day, hour, minute, second)
          .subtract(campusOffset);

  Duration _secs(num s) => Duration(microseconds: (s * 1e6).round());

  String _uuid() {
    String hex(int n) {
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        sb.write(rng.nextInt(16).toRadixString(16));
      }
      return sb.toString();
    }

    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + rng.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  void _add(String room, DateTime t, String metric, String action) {
    if (t.isBefore(start) || !t.isBefore(end)) return;
    if (_isOffline(room, t)) return;
    events.add(MetricEvent(
      clientName: room,
      timestamp: t,
      metric: metric,
      action: action,
      eventId: _uuid(),
      receivedAt: t.add(_secs(2 + rng.nextDouble() * 9)),
    ));
  }

  /// Logs `<control> <event>` as a Trace. [control] is a control id that
  /// the room's naming turns into a control name.
  void _trace(String room, DateTime t, String control, [String event = 'Pressed']) =>
      _add(room, t, '${_profiles[room]!.control(control)} $event', 'Trace');

  T _pick<T>(Map<T, double> weights) {
    final total = weights.values.fold<double>(0, (a, b) => a + b);
    var r = rng.nextDouble() * total;
    for (final e in weights.entries) {
      r -= e.value;
      if (r <= 0) return e.key;
    }
    return weights.keys.last;
  }

  DateTime get _offlineSince =>
      end.subtract(const Duration(days: DemoScenario.offlineDays, hours: 3));

  late final DateTime _outageStart = _local(
      _weekdayBefore(end.subtract(const Duration(days: 9))), 6, 40);
  late final DateTime _outageEnd = _outageStart.add(const Duration(hours: 6, minutes: 30));

  bool _isOffline(String room, DateTime t) {
    if (room == DemoScenario.heartbeatGapRoom && !t.isBefore(_offlineSince)) return true;
    if (room == DemoScenario.outageRoom &&
        !t.isBefore(_outageStart) &&
        t.isBefore(_outageEnd)) {
      return true;
    }
    return false;
  }

  DateTime _weekdayBefore(DateTime day) {
    var d = DateTime.utc(day.year, day.month, day.day);
    while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      d = d.subtract(const Duration(days: 1));
    }
    return d;
  }

  // ------------------------------------------------------------ building

  Dataset build() {
    final days = weeks * 7;
    for (final room in rooms) {
      for (var d = 0; d < days; d++) {
        final day = start.add(Duration(days: d));
        final week = d ~/ 7;
        _simulateDay(room, day, week);
      }
    }
    _injectIssues();
    _systemClient();
    _heartbeats();

    final heartbeats = <HeartbeatBucket>[];
    for (final client in heartbeatHours.keys.toList()..sort()) {
      final hours = heartbeatHours[client]!;
      for (final h in hours.keys.toList()..sort()) {
        heartbeats.add(HeartbeatBucket(
          clientName: client,
          hourStart: DateTime.fromMicrosecondsSinceEpoch(
              h * Duration.microsecondsPerHour,
              isUtc: true),
          count: hours[h]!,
        ));
      }
    }
    return Dataset(
      events: events,
      heartbeats: heartbeats,
      rangeStart: start,
      rangeEnd: end,
      origin: DatasetOrigin.demo,
      description: 'Demo campus (synthetic data)',
      heartbeatRetentionDays: demoHeartbeatRetentionDays,
    );
  }

  static const List<(int, int)> _blocks = [
    (8, 0), (9, 30), (11, 0), (12, 30), (14, 0), (15, 30), (17, 0), (18, 30), (20, 0),
  ];

  void _simulateDay(_RoomProfile room, DateTime day, int week) {
    // `day` is a UTC midnight; treat its calendar date as the campus date.
    final weekday = day.weekday;
    final weekend = weekday == DateTime.saturday || weekday == DateTime.sunday;
    final trend = 0.82 + 0.035 * week; // usage grows ~3.5 points per week

    if (weekday == DateTime.sunday && _stableHash(room.name) % 3 == 0) {
      // Weekly processor restart at 03:00.
      final t = _local(day, 3, 0, rng.nextInt(50));
      _add(room.name, t, room.programStart, 'Started');
      if (room.legacy) {
        _add(room.name, t.add(_secs(35 + rng.nextInt(20))), room.programStart, 'Stopped');
      }
      for (final dev in room.devices) {
        _add(room.name, t.add(_secs(60 + rng.nextInt(30))), dev, 'Connected');
      }
    }

    DateTime? lastEnd;
    for (var b = 0; b < _blocks.length; b++) {
      final (hour, minute) = _blocks[b];
      var p = room.busyness * trend;
      if (hour >= 17) p *= 0.45;
      if (hour == 20) p *= 0.5;
      if (weekday == DateTime.friday) p *= 0.65;
      if (weekend) p *= 0.04;
      if (rng.nextDouble() >= p.clamp(0.0, 0.97)) continue;

      final on = _local(day, hour, minute).subtract(_secs(60 + rng.nextInt(540)));
      if (lastEnd != null && on.isBefore(lastEnd.add(const Duration(minutes: 2)))) {
        continue;
      }
      final length = Duration(minutes: 60 + rng.nextInt(30));
      if (room.name == DemoScenario.longDeviceSession &&
          on.isBefore(_leftOnEnd) &&
          on.add(length + const Duration(hours: 2)).isAfter(_leftOnStart)) {
        continue; // keep the injected long session undisturbed
      }
      final isLastOfDay = b == _blocks.length - 1 || hour >= 17;
      lastEnd = _session(room, on, on.add(length), allowScheduled: isLastOfDay);
    }

    // Occasional communication changes (normal background noise).
    if (rng.nextDouble() < 0.025) {
      final t = _local(day, 7 + rng.nextInt(12), rng.nextInt(60));
      final dev = room.devices.isEmpty ? room.device('DSP', 1) : room.devices.first;
      _add(room.name, t, dev, 'Disconnected');
      _add(room.name, t.add(_secs(20 + rng.nextInt(200))), dev, 'Connected');
    }
  }

  /// Simulates one class session and returns when the room was off again.
  DateTime _session(_RoomProfile room, DateTime on, DateTime classEnd,
      {bool allowScheduled = false, bool forceUserOff = false}) {
    final r = room.name;
    // Remote power is only logged by the recommended-name rooms.
    final remote = !room.legacy && rng.nextDouble() < 0.04;
    if (!remote) _trace(r, on.subtract(_secs(1.2)), 'power_on');
    _add(r, on, room.power(remote ? 'Remote' : 'User'), 'Started');
    _add(r, on.add(_secs(24 + rng.nextDouble() * 6)), room.startupComplete, 'Trace');
    if (!room.legacy) {
      // The program's automatic default source at power-on.
      _add(r, on.add(_secs(1 + rng.nextDouble())), room.source('pc'), 'Started');
    }
    var t = on.add(_secs(2));
    for (final dev in room.devices) {
      t = t.add(_secs(0.3 + rng.nextDouble()));
      _add(r, t, dev, 'Started');
    }
    for (final mic in room.mics) {
      _add(r, on.add(_secs(5 + rng.nextDouble())), room.mute(mic), 'Stopped');
    }
    _add(r, on.add(_secs(6)), 'Program Audio Volume', room.volume(50));

    final usesCamera = room.cameras > 0 && rng.nextDouble() < 0.55;
    if (usesCamera) {
      for (var c = 1; c <= room.cameras; c++) {
        _add(r, on.add(_secs(40 + c)), room.device('Camera', c), 'Started');
      }
    }

    // First selection, then a few changes during class.
    var cursor = on.add(_secs(30 + rng.nextInt(60)));
    _selectInput(room, cursor);
    final switches = rng.nextInt(4);
    final span = classEnd.difference(cursor).inSeconds;
    final times = [
      for (var i = 0; i < switches; i++) cursor.add(Duration(seconds: rng.nextInt(span)))
    ]..sort();
    for (final st in times) {
      _selectInput(room, st);
    }

    // Volume, mutes, sliders, navigation and help during class.
    final extras = 2 + rng.nextInt(6);
    for (var i = 0; i < extras; i++) {
      final et = cursor.add(Duration(seconds: rng.nextInt(span)));
      switch (rng.nextInt(7)) {
        case 0:
          _trace(r, et, 'volume_up');
          _add(r, et.add(_secs(0.2)), 'Program Audio Volume', room.volume(50 + rng.nextInt(30)));
        case 1:
          _trace(r, et, 'volume_down');
        case 2:
          _trace(r, et, 'volume_slider');
          _trace(r, et.add(_secs(1.5)), 'volume_slider', 'Released');
        case 3:
          _trace(r, et, 'video_mute');
          _add(r, et.add(_secs(0.3)), room.mute('Video'), 'Started');
          _trace(r, et.add(_secs(90 + rng.nextInt(400))), 'video_mute');
          _add(r, et.add(_secs(91 + rng.nextInt(400))), room.mute('Video'), 'Stopped');
        case 4:
          final mic = room.mics[rng.nextInt(room.mics.length)];
          _trace(r, et, 'mic_mute');
          _add(r, et.add(_secs(0.2)), room.mute(mic), 'Started');
          _add(r, et.add(_secs(60 + rng.nextInt(600))), room.mute(mic), 'Stopped');
        case 5:
          _trace(r, et, room.cameras > 0 ? 'camera_page' : 'audio_page');
          _trace(r, et.add(_secs(8 + rng.nextInt(30))), 'back');
        case 6:
          _add(r, et, room.mute('Program Audio'), 'Started');
          _add(r, et.add(_secs(30 + rng.nextInt(300))), room.mute('Program Audio'), 'Stopped');
      }
    }
    if (rng.nextDouble() < (r == DemoScenario.helpEvents ? 0.18 : 0.012)) {
      final ht = cursor.add(Duration(seconds: rng.nextInt(span)));
      _trace(r, ht, 'help');
      if (room.legacy) {
        _add(r, ht.add(_secs(0.2)), 'Help', 'Started');
        _add(r, ht.add(_secs(45 + rng.nextInt(150))), 'Help', 'Stopped');
      }
    }
    if (room.stations > 0 && rng.nextDouble() < 0.5) {
      final st = cursor.add(Duration(seconds: rng.nextInt(span)));
      _add(r, st, 'Station ${1 + rng.nextInt(room.stations)}', 'Share');
    }

    // Power off.
    final roll = rng.nextDouble();
    String offMetric;
    var off = classEnd.add(_secs(rng.nextInt(240)));
    if (forceUserOff || roll < 0.6) {
      offMetric = room.power('User');
      _trace(r, off.subtract(_secs(4)), 'power_off');
      _trace(r, off.subtract(_secs(0.01)), 'power_off_confirm');
    } else if (roll < 0.86 || !allowScheduled) {
      offMetric = room.power('Inactivity');
      off = off.add(Duration(minutes: 30 + rng.nextInt(30)));
    } else if (roll < 0.97) {
      offMetric = room.power(room.legacy ? 'Scheduled' : 'Schedule');
      final day = off.add(campusOffset);
      final scheduled = _local(DateTime.utc(day.year, day.month, day.day), 22, 0);
      if (scheduled.isAfter(off)) off = scheduled;
    } else {
      offMetric = room.power(remote ? 'Remote' : 'User');
    }
    _add(r, off, offMetric, 'Stopped');
    for (final mic in room.mics) {
      _add(r, off.add(_secs(1.5 + rng.nextDouble())), room.mute(mic), 'Started');
    }
    _add(r, off.add(_secs(1.9)), room.shutdownComplete, 'Trace');
    _add(r, off.add(_secs(2.4)), 'Program Audio Volume', room.volume(50));
    var d = off.add(_secs(8));
    for (final dev in room.devices) {
      if (r == DemoScenario.longDeviceSession && dev == room.device('Projector', 1) && _leftOnPending) {
        continue; // stopped by the injected long session
      }
      d = d.add(_secs(0.2 + rng.nextDouble()));
      _add(r, d, dev, 'Stopped');
    }
    if (usesCamera) {
      for (var c = 1; c <= room.cameras; c++) {
        _add(r, off.add(_secs(10 + c)), room.device('Camera', c), 'Stopped');
      }
    }
    return off.add(_secs(30));
  }

  bool _leftOnPending = false;

  /// The injected long projector session (about 18 hours).
  late final DateTime _leftOnStart = _local(_issueDay(8), 15, 25, 3);
  late final DateTime _leftOnEnd = _leftOnStart.add(const Duration(hours: 18, minutes: 12));

  void _selectInput(_RoomProfile room, DateTime t) {
    final input = _pick(room.inputWeights);
    final button = room.legacy ? 'Btn_Source_$input' : 'Source ${input.replaceAll('_', ' ')}';
    _add(room.name, t.subtract(_secs(0.15)), '$button Pressed', 'Trace');
    if (rng.nextBool()) {
      _add(room.name, t.subtract(_secs(0.1)), '$button Tapped', 'Trace');
    }
    _add(room.name, t, room.source(input), 'Started');
  }

  // ------------------------------------------------------- injected patterns

  DateTime _issueDay(int daysBeforeEnd) =>
      _weekdayBefore(end.subtract(Duration(days: daysBeforeEnd)));

  void _injectIssues() {
    // 1. Repeated power cycling: four on/off cycles in about eight minutes.
    {
      final r = DemoScenario.rapidPowerCycling;
      final p = _profiles[r]!;
      var t = _local(_issueDay(3), 10, 2, 11);
      for (var i = 0; i < 4; i++) {
        _trace(r, t.subtract(_secs(1)), 'power_on');
        _add(r, t, p.power('User'), 'Started');
        _add(r, t.add(_secs(3)), p.device('Projector', 1), 'Started');
        final off = t.add(_secs(70 + i * 9));
        _trace(r, off.subtract(_secs(3)), 'power_off');
        _trace(r, off.subtract(_secs(0.05)), 'power_off_confirm');
        _add(r, off, p.power('User'), 'Stopped');
        _add(r, off.add(_secs(9)), p.device('Projector', 1), 'Stopped');
        t = off.add(_secs(45));
      }
      // A second, smaller episode a week earlier.
      var t2 = _local(_issueDay(10), 13, 58, 4);
      for (var i = 0; i < 3; i++) {
        _add(r, t2, p.power('User'), 'Started');
        _add(r, t2.add(_secs(80)), p.power('User'), 'Stopped');
        t2 = t2.add(_secs(150));
      }
    }

    // 2. Repeated presses: a volume control pressed ten times in six seconds
    //    (below its raised threshold) and another control pressed eight
    //    times in about seven seconds.
    {
      final r = DemoScenario.repeatedPresses;
      final t = _local(_issueDay(2), 11, 14, 30);
      for (var i = 0; i < 10; i++) {
        _trace(r, t.add(_secs(i * 0.6)), 'volume_up');
      }
      final t2 = _local(_issueDay(12), 9, 41, 2);
      for (var i = 0; i < 8; i++) {
        _trace(r, t2.add(_secs(i * 0.9)), 'video_mute');
        _trace(r, t2.add(_secs(i * 0.9 + 0.05)), 'video_mute', 'Tapped');
      }
    }

    // 3. Rapid navigation: twelve navigation presses in under 25 seconds.
    {
      final r = DemoScenario.rapidNavigation;
      final t = _local(_issueDay(4), 14, 7, 0);
      const nav = [
        'camera_page', 'back', 'audio_page', 'home',
        'display_page', 'back', 'settings_menu', 'back',
        'camera_page', 'home', 'audio_page', 'back',
      ];
      for (var i = 0; i < nav.length; i++) {
        _trace(r, t.add(_secs(i * 1.9)), nav[i]);
      }
    }

    // 4. Rapid source changes: six selections in 70 seconds.
    {
      final r = DemoScenario.rapidSourceChanges;
      final p = _profiles[r]!;
      final t = _local(_issueDay(5), 9, 33, 0);
      const order = ['hdmi', 'pc', 'usb', 'wireless', 'hdmi', 'pc'];
      for (var i = 0; i < order.length; i++) {
        _add(r, t.add(_secs(i * 14)), p.source(order[i]), 'Started');
      }
    }

    // 5. Repeated connection changes: a projector disconnects and
    //    reconnects six times.
    {
      final r = DemoScenario.connectionFlapping;
      final p = _profiles[r]!;
      final proj = p.device('Projector', 1), dsp = p.device('DSP', 1);
      final t = _local(_issueDay(6), 12, 20, 0);
      for (var i = 0; i < 6; i++) {
        _add(r, t.add(Duration(seconds: i * 110)), proj, 'Disconnected');
        _add(r, t.add(Duration(seconds: i * 110 + 35)), proj, 'Connected');
      }
      _add(r, t.add(const Duration(minutes: 3)), dsp, 'Disconnected');
      _add(r, t.add(const Duration(minutes: 4)), dsp, 'Connected');
    }

    // 6. Long device session: a projector on for about 18 hours.
    {
      final r = DemoScenario.longDeviceSession;
      final room = _profiles[r]!;
      _leftOnPending = true;
      _session(room, _leftOnStart, _leftOnStart.add(const Duration(minutes: 70)), forceUserOff: true);
      _leftOnPending = false;
      _add(r, _leftOnEnd, room.device('Projector', 1), 'Stopped');
    }

    // 7. Program start mid-session, then the program turns the room back on.
    {
      final r = DemoScenario.restoreRoom;
      final p = _profiles[r]!;
      final t = _local(_issueDay(15), 11, 40, 0);
      _add(r, t, p.programStart, 'Started');
      _add(r, t.add(_secs(44)), p.power('Restore'), 'Started');
      _add(r, t.add(_secs(70)), p.startupComplete, 'Trace');
      _add(r, t.add(const Duration(minutes: 50)), p.power('User'), 'Stopped');
    }

    // 8. A system power Started while the system is already on. The legacy
    //    reason text is kept verbatim.
    _add(DemoScenario.startedWhileOnRoom, _local(_issueDay(7), 10, 5, 0), 'System - User Reset', 'Started');
  }

  void _systemClient() {
    const c = 'AVSM-System';
    for (var d = 3; d < weeks * 7; d += 14) {
      final t = start.add(Duration(days: d, hours: 10, minutes: 15));
      _add(c, t, 'Update started', 'Trace');
      _add(c, t.add(const Duration(minutes: 2, seconds: 37)), 'Update stopped: success', 'Trace');
    }
    final m = start.add(Duration(days: weeks * 7 - 20, hours: 11));
    _add(c, m, 'Maintenance started', 'Trace');
    _add(c, m.add(const Duration(minutes: 9)), 'Maintenance stopped: success', 'Trace');
  }

  void _heartbeats() {
    final hbStart = end.subtract(const Duration(days: demoHeartbeatRetentionDays));
    const perHour = 60;
    final startHour = hbStart.microsecondsSinceEpoch ~/ Duration.microsecondsPerHour;
    final endHour = end.microsecondsSinceEpoch ~/ Duration.microsecondsPerHour;
    for (final room in demoRooms) {
      final map = heartbeatHours.putIfAbsent(room, () => {});
      for (var h = startHour; h < endHour; h++) {
        final hourStart = DateTime.fromMicrosecondsSinceEpoch(
            h * Duration.microsecondsPerHour,
            isUtc: true);
        // Count minutes in this hour during which the room was online.
        var online = 0;
        for (var m = 0; m < 60; m++) {
          if (!_isOffline(room, hourStart.add(Duration(minutes: m)))) online++;
        }
        if (online == 0) continue;
        final jitter = rng.nextInt(3) - 1;
        map[h] = ((perHour * online) ~/ 60 + (online == 60 ? jitter : 0))
            .clamp(1, perHour + 1);
      }
    }
  }
}
