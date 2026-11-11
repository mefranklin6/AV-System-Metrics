// User-tunable analysis settings. Shared contract between the settings UI
// (lib/state, lib/ui) and the analytics engine (lib/analytics). Pure Dart,
// isolate-safe, JSON round-trippable for persistence.

/// How raw metric names map to categories.
///
/// The defaults follow the event conventions in `Implementation_Guide.md` at
/// the repository root: the recommended names (`System Power`,
/// `Source - <name>`, `<Device> <n>`, `Program Start`, `<Control> Pressed`,
/// `<Channel> Mute`, ...) and the "also recognized" forms listed there. The
/// latter include the names used by the first control program this project
/// was built against (`System - <reason>`, `Initialize`, `Projector_1`, bare
/// source names such as `hdmi`). Every name list and pattern can be changed
/// in Settings to match another program. Names are compared ignoring
/// capitalization and surrounding spaces; patterns are case-insensitive.
class ClassifierConfig {
  const ClassifierConfig({
    this.systemPowerNames = defaultSystemPowerNames,
    this.powerReasonSynonyms = defaultPowerReasonSynonyms,
    this.sourcePrefixes = defaultSourcePrefixes,
    this.inputNames = defaultInputNames,
    this.devicePattern = defaultDevicePattern,
    this.programStartNames = defaultProgramStartNames,
    this.startupCompleteNames = defaultStartupCompleteNames,
    this.shutdownCompleteNames = defaultShutdownCompleteNames,
    this.navigationButtonPattern = defaultNavigationButtonPattern,
    this.repeatableControlPattern = defaultRepeatableControlPattern,
    this.helpPattern = defaultHelpPattern,
    this.buildingPattern = defaultBuildingPattern,
  });

  /// Metrics treated as system power when logged with `Started` / `Stopped`.
  /// Each name matches on its own (`System Power`) or followed by a dash and
  /// a reason (`System Power - User`, `System - Inactivity`, `System -User`).
  static const List<String> defaultSystemPowerNames = [
    'System Power',
    'System',
  ];

  /// Reason words (the text after a system power metric's dash) grouped
  /// into the standard reasons. Keys are the names in [powerReasonGroups]
  /// (the matching `PowerSource` values). A reason in no group is kept and
  /// reported exactly as logged.
  static const Map<String, List<String>> defaultPowerReasonSynonyms = {
    'user': ['User', 'Manual', 'Local', 'Panel', 'Touch Panel'],
    'scheduled': ['Schedule', 'Scheduled', 'Scheduler'],
    'inactivity': [
      'Inactivity',
      'Inactive',
      'Idle',
      'Timeout',
      'Time Out',
      'Auto Off',
      'Auto-Off',
    ],
    'remote': ['Remote', 'Remote Control'],
    'restore': ['Restore', 'Restored', 'Recovery', 'Recover', 'Auto Restore'],
  };

  /// Valid keys of [powerReasonSynonyms], in display order.
  static const List<String> powerReasonGroups = [
    'user',
    'scheduled',
    'inactivity',
    'remote',
    'restore',
  ];

  /// Metric prefixes that mark a source selection (with `Started` or
  /// `Trace`; `Stopped` ends the source's time on screen). The text after
  /// the prefix is the source name, kept as logged. Spaces around the
  /// punctuation are optional when matching (`Source-HDMI 1` also matches).
  static const List<String> defaultSourcePrefixes = [
    'Source -',
    'Source:',
    'Source Select:',
    'Input -',
    'Input:',
  ];

  /// Bare metric names (case-insensitive) that also mean "this source was
  /// selected", for programs that log the source name on its own.
  static const List<String> defaultInputNames = [
    'pc',
    'pc_extended',
    'hdmi',
    'usb',
    'vga',
    'wireless',
    'doc_cam',
    'inst_cam',
    'aud_cam',
    'sub_switcher',
    'dvd',
    'blu_ray',
    'individual',
    'custom_input',
    'laptop',
    'station_1',
    'station_2',
    'station_3',
    'station_4',
    'station_5',
    'station_6',
    'station_7',
    'station_1_laptop',
    'station_2_laptop',
    'station_3_laptop',
    'station_4_laptop',
    'station_5_laptop',
    'station_6_laptop',
    'station_7_laptop',
  ];

  /// Regex (case-insensitive) for device power metrics logged as
  /// `Started` / `Stopped`. The device type is the first capture group that
  /// matched, with `_` and `-` turned into spaces and upper-cased, so
  /// `Projector 1`, `Projector_1`, `Projector 1 Power` and `Projector Power`
  /// all have type `PROJECTOR`, and `Laser_Projector_2` has
  /// `LASER PROJECTOR`.
  static const String defaultDevicePattern =
      r'^(?:([A-Za-z][A-Za-z0-9 _\-]*?)[ _\-]*\d+(?:[ _\-]+Power)?|([A-Za-z][A-Za-z0-9 _\-]*?)[ _\-]+Power)$';

  /// Device patterns shipped as the default by earlier versions. Saved
  /// settings that still hold one are upgraded to [defaultDevicePattern].
  static const List<String> previousDevicePatterns = [
    r'^(Projector|Display|Camera|Screen|Monitor|Recorder|TV|Lectern)_?\d+$',
  ];

  /// Metrics that mark a processor boot or program load (with `Started` or
  /// `Trace`). Every open session in the room is closed at that moment.
  static const List<String> defaultProgramStartNames = [
    'Program Start',
    'Program Started',
    'Processor Boot',
    'Initialize',
  ];

  /// Optional `Trace` metrics sent when the room finished powering on.
  static const List<String> defaultStartupCompleteNames = [
    'System Startup Complete',
    'System Startup Sequence Complete',
  ];

  /// Optional `Trace` metrics sent when the room finished powering off.
  static const List<String> defaultShutdownCompleteNames = [
    'System Shutdown Complete',
    'System Shutdown Sequence Complete',
  ];

  /// Regex (case-insensitive) for controls counted as navigation. Matched
  /// against the control name without the trailing event word (`Pressed`,
  /// `Tapped`, ...). The default matches `Nav`, `Navigation`, `Page`,
  /// `Menu`, `Tab`, `Back` or `Home` as a separate word or as a part
  /// separated by `_`, `-` or a space (`Btn_Nav_Display`, `Main Menu`,
  /// `Back`), but not inside a longer word (`Backlight`, `Table`).
  static const String defaultNavigationButtonPattern =
      r'(^|[\s_\-])(Nav|Navigation|Page|Menu|Tab|Back|Home)([\s_\-]|$)';

  /// Navigation patterns shipped as the default by earlier versions. Saved
  /// settings that still hold one are upgraded to
  /// [defaultNavigationButtonPattern].
  static const List<String> previousNavigationButtonPatterns = [
    r'(_Nav$|_Page$|^Btn_Back|_Menu$|_Tab$|^Btn_Home|^Btn_Exit)',
    r'(_Nav$|^(?!Btn_Start_Page$).*_Page$|^Btn_Back(_|$)|_Menu$|_Tab$|^Btn_Home|^Btn_Exit)',
  ];

  /// Regex (case-insensitive) for controls whose names suggest they are
  /// meant to be pressed repeatedly (volume, camera moves, sliders). The
  /// repeated-press detector needs more presses for these.
  static const String defaultRepeatableControlPattern =
      r'(^|[\s_\-])(Up|Down|Volume|Vol|Zoom|Pan|Tilt|Focus|Left|Right|In|Out|Slider|Sldr|Fader)([\s_\-]|$)';

  /// Regex (case-insensitive) for help-labelled events: any event whose
  /// metric matches, whatever its action. The default matches the word
  /// `help` on its own or separated by `_`, `-`, a space or punctuation
  /// (`Help`, `Help Pressed`, `Btn_Help`), but not `Helper`.
  static const String defaultHelpPattern =
      r'(^|[^A-Za-z0-9])help([^A-Za-z0-9]|$)';

  /// Regex applied to client names. Capture group 1 is the building.
  /// `SCI-101` -> `SCI`, `Holt_171` -> `HOLT` (buildings are upper-cased).
  static const String defaultBuildingPattern = r'^([A-Za-z]+)[_\- ]?';

  /// See [defaultSystemPowerNames].
  final List<String> systemPowerNames;

  /// See [defaultPowerReasonSynonyms].
  final Map<String, List<String>> powerReasonSynonyms;

  /// See [defaultSourcePrefixes].
  final List<String> sourcePrefixes;

  /// Bare source names; see [defaultInputNames].
  final List<String> inputNames;

  /// See [defaultDevicePattern].
  final String devicePattern;

  /// See [defaultProgramStartNames].
  final List<String> programStartNames;

  /// See [defaultStartupCompleteNames].
  final List<String> startupCompleteNames;

  /// See [defaultShutdownCompleteNames].
  final List<String> shutdownCompleteNames;

  /// See [defaultNavigationButtonPattern].
  final String navigationButtonPattern;

  /// See [defaultRepeatableControlPattern].
  final String repeatableControlPattern;

  /// See [defaultHelpPattern].
  final String helpPattern;

  /// See [defaultBuildingPattern].
  final String buildingPattern;

  ClassifierConfig copyWith({
    List<String>? systemPowerNames,
    Map<String, List<String>>? powerReasonSynonyms,
    List<String>? sourcePrefixes,
    List<String>? inputNames,
    String? devicePattern,
    List<String>? programStartNames,
    List<String>? startupCompleteNames,
    List<String>? shutdownCompleteNames,
    String? navigationButtonPattern,
    String? repeatableControlPattern,
    String? helpPattern,
    String? buildingPattern,
  }) => ClassifierConfig(
    systemPowerNames: systemPowerNames ?? this.systemPowerNames,
    powerReasonSynonyms: powerReasonSynonyms ?? this.powerReasonSynonyms,
    sourcePrefixes: sourcePrefixes ?? this.sourcePrefixes,
    inputNames: inputNames ?? this.inputNames,
    devicePattern: devicePattern ?? this.devicePattern,
    programStartNames: programStartNames ?? this.programStartNames,
    startupCompleteNames: startupCompleteNames ?? this.startupCompleteNames,
    shutdownCompleteNames: shutdownCompleteNames ?? this.shutdownCompleteNames,
    navigationButtonPattern:
        navigationButtonPattern ?? this.navigationButtonPattern,
    repeatableControlPattern:
        repeatableControlPattern ?? this.repeatableControlPattern,
    helpPattern: helpPattern ?? this.helpPattern,
    buildingPattern: buildingPattern ?? this.buildingPattern,
  );

  Map<String, Object?> toJson() => {
    'systemPowerNames': systemPowerNames,
    'powerReasonSynonyms': powerReasonSynonyms,
    'sourcePrefixes': sourcePrefixes,
    'inputNames': inputNames,
    'devicePattern': devicePattern,
    'programStartNames': programStartNames,
    'startupCompleteNames': startupCompleteNames,
    'shutdownCompleteNames': shutdownCompleteNames,
    'navigationButtonPattern': navigationButtonPattern,
    'repeatableControlPattern': repeatableControlPattern,
    'helpPattern': helpPattern,
    'buildingPattern': buildingPattern,
  };

  /// Reads settings saved by this or an earlier version. Missing keys get
  /// their defaults, and patterns that were the default in an earlier
  /// version are upgraded to the current default.
  factory ClassifierConfig.fromJson(Map<String, Object?> json) {
    List<String> list(String key, List<String> fallback) {
      final v = json[key];
      return v is List ? v.whereType<String>().toList() : fallback;
    }

    String pattern(
      String key,
      String fallback, [
      List<String> previous = const [],
    ]) {
      final v = json[key];
      if (v is! String || previous.contains(v)) return fallback;
      return v;
    }

    Map<String, List<String>> synonyms() {
      final v = json['powerReasonSynonyms'];
      if (v is! Map) return defaultPowerReasonSynonyms;
      return {
        for (final e in v.entries)
          if (e.value is List)
            e.key.toString(): (e.value as List).whereType<String>().toList(),
      };
    }

    return ClassifierConfig(
      systemPowerNames: list('systemPowerNames', defaultSystemPowerNames),
      powerReasonSynonyms: synonyms(),
      sourcePrefixes: list('sourcePrefixes', defaultSourcePrefixes),
      inputNames: list('inputNames', defaultInputNames),
      devicePattern: pattern(
        'devicePattern',
        defaultDevicePattern,
        previousDevicePatterns,
      ),
      programStartNames: list('programStartNames', defaultProgramStartNames),
      startupCompleteNames: list(
        'startupCompleteNames',
        defaultStartupCompleteNames,
      ),
      shutdownCompleteNames: list(
        'shutdownCompleteNames',
        defaultShutdownCompleteNames,
      ),
      navigationButtonPattern: pattern(
        'navigationButtonPattern',
        defaultNavigationButtonPattern,
        previousNavigationButtonPatterns,
      ),
      repeatableControlPattern: pattern(
        'repeatableControlPattern',
        defaultRepeatableControlPattern,
      ),
      helpPattern: pattern('helpPattern', defaultHelpPattern),
      buildingPattern: pattern('buildingPattern', defaultBuildingPattern),
    );
  }

  /// Returns a user-facing message when the configuration cannot be used,
  /// otherwise null. Regex syntax is checked by the caller (settings
  /// validation); this checks the name lists.
  String? listProblem() {
    if (inputNames.every((n) => n.trim().isEmpty) &&
        sourcePrefixes.every((p) => p.trim().isEmpty)) {
      return 'Add at least one source prefix or source name.';
    }
    for (final key in powerReasonSynonyms.keys) {
      if (!powerReasonGroups.contains(key)) {
        return 'Unknown power reason group "$key".';
      }
    }
    return null;
  }
}

/// Thresholds for the "potential issue" detectors. A detector fires when at
/// least `count` qualifying events happen within `window` in one room.
class IssueThresholds {
  const IssueThresholds({
    this.powerCycleCount = 3,
    this.powerCycleWindow = const Duration(minutes: 10),
    this.buttonMashCount = 6,
    this.buttonMashWindow = const Duration(seconds: 10),
    this.navigationThrashCount = 8,
    this.navigationThrashWindow = const Duration(seconds: 30),
    this.inputHuntCount = 5,
    this.inputHuntWindow = const Duration(minutes: 2),
    this.connectionFlapCount = 4,
    this.connectionFlapWindow = const Duration(minutes: 15),
    this.deviceLeftOnHours = 12,
    this.offlineGap = const Duration(hours: 2),
  });

  /// System power `Started` logged repeatedly ("Repeated power cycling").
  final int powerCycleCount;
  final Duration powerCycleWindow;

  /// Repeated presses of one control. Field and JSON key names are kept
  /// from earlier versions so saved settings still load.
  final int buttonMashCount;
  final Duration buttonMashWindow;

  /// Rapid navigation presses.
  final int navigationThrashCount;
  final Duration navigationThrashWindow;

  /// Rapid source changes (at least two different sources).
  final int inputHuntCount;
  final Duration inputHuntWindow;

  /// Changes between `Connected` and `Disconnected` for one metric.
  final int connectionFlapCount;
  final Duration connectionFlapWindow;

  /// A device session longer than this is reported.
  final int deviceLeftOnHours;

  /// A gap with no heartbeats or events longer than this (inside heartbeat
  /// coverage) is reported.
  final Duration offlineGap;

  IssueThresholds copyWith({
    int? powerCycleCount,
    Duration? powerCycleWindow,
    int? buttonMashCount,
    Duration? buttonMashWindow,
    int? navigationThrashCount,
    Duration? navigationThrashWindow,
    int? inputHuntCount,
    Duration? inputHuntWindow,
    int? connectionFlapCount,
    Duration? connectionFlapWindow,
    int? deviceLeftOnHours,
    Duration? offlineGap,
  }) => IssueThresholds(
    powerCycleCount: powerCycleCount ?? this.powerCycleCount,
    powerCycleWindow: powerCycleWindow ?? this.powerCycleWindow,
    buttonMashCount: buttonMashCount ?? this.buttonMashCount,
    buttonMashWindow: buttonMashWindow ?? this.buttonMashWindow,
    navigationThrashCount: navigationThrashCount ?? this.navigationThrashCount,
    navigationThrashWindow:
        navigationThrashWindow ?? this.navigationThrashWindow,
    inputHuntCount: inputHuntCount ?? this.inputHuntCount,
    inputHuntWindow: inputHuntWindow ?? this.inputHuntWindow,
    connectionFlapCount: connectionFlapCount ?? this.connectionFlapCount,
    connectionFlapWindow: connectionFlapWindow ?? this.connectionFlapWindow,
    deviceLeftOnHours: deviceLeftOnHours ?? this.deviceLeftOnHours,
    offlineGap: offlineGap ?? this.offlineGap,
  );

  Map<String, Object?> toJson() => {
    'powerCycleCount': powerCycleCount,
    'powerCycleWindowSeconds': powerCycleWindow.inSeconds,
    'buttonMashCount': buttonMashCount,
    'buttonMashWindowSeconds': buttonMashWindow.inSeconds,
    'navigationThrashCount': navigationThrashCount,
    'navigationThrashWindowSeconds': navigationThrashWindow.inSeconds,
    'inputHuntCount': inputHuntCount,
    'inputHuntWindowSeconds': inputHuntWindow.inSeconds,
    'connectionFlapCount': connectionFlapCount,
    'connectionFlapWindowSeconds': connectionFlapWindow.inSeconds,
    'deviceLeftOnHours': deviceLeftOnHours,
    'offlineGapSeconds': offlineGap.inSeconds,
  };

  factory IssueThresholds.fromJson(Map<String, Object?> json) {
    const d = IssueThresholds();
    int i(String k, int fallback) => (json[k] as num?)?.toInt() ?? fallback;
    Duration s(String k, Duration fallback) =>
        Duration(seconds: i(k, fallback.inSeconds));
    return IssueThresholds(
      powerCycleCount: i('powerCycleCount', d.powerCycleCount),
      powerCycleWindow: s('powerCycleWindowSeconds', d.powerCycleWindow),
      buttonMashCount: i('buttonMashCount', d.buttonMashCount),
      buttonMashWindow: s('buttonMashWindowSeconds', d.buttonMashWindow),
      navigationThrashCount: i(
        'navigationThrashCount',
        d.navigationThrashCount,
      ),
      navigationThrashWindow: s(
        'navigationThrashWindowSeconds',
        d.navigationThrashWindow,
      ),
      inputHuntCount: i('inputHuntCount', d.inputHuntCount),
      inputHuntWindow: s('inputHuntWindowSeconds', d.inputHuntWindow),
      connectionFlapCount: i('connectionFlapCount', d.connectionFlapCount),
      connectionFlapWindow: s(
        'connectionFlapWindowSeconds',
        d.connectionFlapWindow,
      ),
      deviceLeftOnHours: i('deviceLeftOnHours', d.deviceLeftOnHours),
      offlineGap: s('offlineGapSeconds', d.offlineGap),
    );
  }
}

/// The weekly window used as the denominator for room utilization
/// ("percent of teaching hours the room was in use").
///
/// Hours are whole wall-clock hours in the analysis time zone (local or UTC,
/// see [AnalysisConfig.useLocalTime]). The window covers
/// `[startHour:00, endHour:00)` on each day in [weekdays].
class BusinessHours {
  const BusinessHours({
    this.weekdays = defaultWeekdays,
    this.startHour = 7,
    this.endHour = 22,
  });

  /// Monday to Friday, using [DateTime.monday] (1) .. [DateTime.sunday] (7).
  static const List<int> defaultWeekdays = [1, 2, 3, 4, 5];

  /// Days of the week included, using [DateTime.weekday] numbering
  /// (1 = Monday .. 7 = Sunday).
  final List<int> weekdays;

  /// First included hour of the day, 0-23.
  final int startHour;

  /// First excluded hour of the day, 1-24 (24 = until midnight).
  final int endHour;

  /// Whether the wall-clock hour [hour] (0-23) on [weekday] (1-7) is inside
  /// the window.
  bool contains(int weekday, int hour) =>
      weekdays.contains(weekday) && hour >= startHour && hour < endHour;

  /// Number of hours per week inside the window.
  int get hoursPerWeek {
    final days = weekdays.toSet().where((d) => d >= 1 && d <= 7).length;
    final perDay = (endHour.clamp(0, 24) - startHour.clamp(0, 24));
    return perDay <= 0 ? 0 : days * perDay;
  }

  BusinessHours copyWith({List<int>? weekdays, int? startHour, int? endHour}) =>
      BusinessHours(
        weekdays: weekdays ?? this.weekdays,
        startHour: startHour ?? this.startHour,
        endHour: endHour ?? this.endHour,
      );

  Map<String, Object?> toJson() => {
    'weekdays': weekdays,
    'startHour': startHour,
    'endHour': endHour,
  };

  factory BusinessHours.fromJson(Map<String, Object?> json) => BusinessHours(
    weekdays:
        (json['weekdays'] as List?)
            ?.whereType<num>()
            .map((n) => n.toInt())
            .toList() ??
        defaultWeekdays,
    startHour: (json['startHour'] as num?)?.toInt() ?? 7,
    endHour: (json['endHour'] as num?)?.toInt() ?? 22,
  );
}

/// Top-level configuration passed to `analyze()`.
class AnalysisConfig {
  const AnalysisConfig({
    this.classifier = const ClassifierConfig(),
    this.thresholds = const IssueThresholds(),
    this.ratedLifeHours = defaultRatedLifeHours,
    this.maxSessionLength = const Duration(hours: 16),
    this.useLocalTime = true,
    this.businessHours = const BusinessHours(),
    this.deviceTypeOverrides = const {},
  });

  /// Rated service life in hours, keyed by upper-case device type (read
  /// from the metric by [ClassifierConfig.devicePattern]). Used for replacement
  /// forecasting. Users should edit these to match their equipment.
  static const Map<String, double> defaultRatedLifeHours = {
    'PROJECTOR': 20000, // typical laser light source
    'DISPLAY': 50000,
    'CAMERA': 30000,
    'SCREEN': 20000,
    'MONITOR': 50000,
    'RECORDER': 30000,
    'TV': 50000,
    'LECTERN': 50000,
  };

  final ClassifierConfig classifier;
  final IssueThresholds thresholds;
  final Map<String, double> ratedLifeHours;

  /// Sessions with no matching stop are closed after this long and marked
  /// as unterminated, so a lost `Stopped` event cannot inflate on-hours.
  /// A device session past this limit still ends at its real `Stopped` if
  /// that is the device's next event within 7 days (see `SessionBuilder`).
  final Duration maxSessionLength;

  /// Bucket hour-of-day / weekday statistics in the machine's local time
  /// zone (true) or in UTC (false).
  final bool useLocalTime;

  /// Window used for the per-room utilization percentage. Defaults to
  /// weekdays 07:00-22:00.
  final BusinessHours businessHours;

  /// Device type for particular devices, keyed by `room/deviceId` (such as
  /// `BSS_112/Projector_1`, compared case-insensitively) with an upper-case
  /// type such as `DISPLAY`. The type sets the device's grouping and its
  /// rated life ([ratedLifeHours]). Useful when a program's device names do
  /// not say what the device is (a flat panel logged as `Projector 1`).
  final Map<String, String> deviceTypeOverrides;

  /// The type to use for [deviceId] in [room]: an entry in
  /// [deviceTypeOverrides], otherwise [loggedType].
  String deviceTypeFor(String room, String deviceId, String loggedType) {
    if (deviceTypeOverrides.isEmpty) return loggedType;
    final key = '$room/$deviceId'.toLowerCase();
    for (final e in deviceTypeOverrides.entries) {
      if (e.key.trim().toLowerCase() == key) {
        final t = e.value.trim().toUpperCase();
        return t.isEmpty ? loggedType : t;
      }
    }
    return loggedType;
  }

  AnalysisConfig copyWith({
    ClassifierConfig? classifier,
    IssueThresholds? thresholds,
    Map<String, double>? ratedLifeHours,
    Duration? maxSessionLength,
    bool? useLocalTime,
    BusinessHours? businessHours,
    Map<String, String>? deviceTypeOverrides,
  }) => AnalysisConfig(
    classifier: classifier ?? this.classifier,
    thresholds: thresholds ?? this.thresholds,
    ratedLifeHours: ratedLifeHours ?? this.ratedLifeHours,
    maxSessionLength: maxSessionLength ?? this.maxSessionLength,
    useLocalTime: useLocalTime ?? this.useLocalTime,
    businessHours: businessHours ?? this.businessHours,
    deviceTypeOverrides: deviceTypeOverrides ?? this.deviceTypeOverrides,
  );

  Map<String, Object?> toJson() => {
    'classifier': classifier.toJson(),
    'thresholds': thresholds.toJson(),
    'ratedLifeHours': ratedLifeHours,
    'maxSessionLengthSeconds': maxSessionLength.inSeconds,
    'useLocalTime': useLocalTime,
    'businessHours': businessHours.toJson(),
    'deviceTypeOverrides': deviceTypeOverrides,
  };

  factory AnalysisConfig.fromJson(Map<String, Object?> json) => AnalysisConfig(
    classifier: json['classifier'] is Map
        ? ClassifierConfig.fromJson(
            (json['classifier'] as Map).cast<String, Object?>(),
          )
        : const ClassifierConfig(),
    thresholds: json['thresholds'] is Map
        ? IssueThresholds.fromJson(
            (json['thresholds'] as Map).cast<String, Object?>(),
          )
        : const IssueThresholds(),
    ratedLifeHours: json['ratedLifeHours'] is Map
        ? (json['ratedLifeHours'] as Map).map(
            (k, v) => MapEntry(k.toString(), (v as num).toDouble()),
          )
        : defaultRatedLifeHours,
    maxSessionLength: Duration(
      seconds:
          (json['maxSessionLengthSeconds'] as num?)?.toInt() ??
          const Duration(hours: 16).inSeconds,
    ),
    useLocalTime: json['useLocalTime'] as bool? ?? true,
    businessHours: json['businessHours'] is Map
        ? BusinessHours.fromJson(
            (json['businessHours'] as Map).cast<String, Object?>(),
          )
        : const BusinessHours(),
    deviceTypeOverrides: json['deviceTypeOverrides'] is Map
        ? {
            for (final e in (json['deviceTypeOverrides'] as Map).entries)
              if (e.value is String) e.key.toString(): e.value as String,
          }
        : const {},
  );
}
