import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/config.dart';
import '../ui/theme/chart_palette.dart';

export '../ui/theme/chart_palette.dart' show ChartPaletteKind;

/// Whether times are shown (and hour-of-day statistics bucketed) in the
/// computer's local time zone or in UTC.
enum TimeDisplay {
  local('Local time'),
  utc('UTC');

  const TimeDisplay(this.label);
  final String label;
}

/// User preferences, persisted with shared_preferences and applied live.
///
/// Every setter updates memory, notifies listeners synchronously, and returns
/// the persistence future (await it in tests; UI code may ignore it).
class SettingsState extends ChangeNotifier {
  SettingsState._(this._prefs) {
    _readAll();
  }

  /// Loads settings from [prefs] (defaults to the shared instance).
  static Future<SettingsState> load([SharedPreferences? prefs]) async =>
      SettingsState._(prefs ?? await SharedPreferences.getInstance());

  final SharedPreferences _prefs;

  // Keys are versioned so a future incompatible change can migrate cleanly.
  static const _kThemeMode = 'v1.themeMode';
  static const _kHighContrast = 'v1.highContrast';
  static const _kPalette = 'v1.palette';
  static const _kTextScale = 'v1.textScale';
  static const _kReduceMotion = 'v1.reduceMotion';
  static const _kPatterns = 'v1.chartPatterns';
  static const _kTimeDisplay = 'v1.timeDisplay';
  static const _kAnalysis = 'v1.analysisConfig';
  static const _kExclude = 'v1.excludeClients';
  static const _kApiUrl = 'v1.apiBaseUrl';
  static const _kRemember = 'v1.rememberApiToken';

  static const double minTextScale = 1.0;
  static const double maxTextScale = 2.0;
  static const Set<String> defaultExcludeClients = {'AVSM-System'};

  ThemeMode _themeMode = ThemeMode.system;
  bool _highContrast = false;
  ChartPaletteKind _palette = ChartPaletteKind.standard;
  double _textScale = 1.0;
  bool _reduceMotion = false;
  bool _showChartPatterns = true;
  TimeDisplay _timeDisplay = TimeDisplay.local;
  AnalysisConfig _analysisConfig = const AnalysisConfig();
  Set<String> _excludeClients = defaultExcludeClients;
  String _apiBaseUrl = '';
  bool _rememberApiToken = false;

  ThemeMode get themeMode => _themeMode;
  bool get highContrast => _highContrast;
  ChartPaletteKind get palette => _palette;

  /// App text size multiplier, 1.0 to 2.0, combined with the system setting.
  double get textScale => _textScale;

  /// The in-app setting only; use `Motion.isReduced(context)` for the
  /// effective value, which also honours the platform setting.
  bool get reduceMotion => _reduceMotion;
  bool get showChartPatterns => _showChartPatterns;
  TimeDisplay get timeDisplay => _timeDisplay;

  /// Analysis configuration with [AnalysisConfig.useLocalTime] following
  /// [timeDisplay].
  AnalysisConfig get analysisConfig => _analysisConfig.copyWith(
      useLocalTime: _timeDisplay == TimeDisplay.local);

  /// Clients left out of room analytics (default: the server's synthetic
  /// `AVSM-System` client).
  Set<String> get excludeClients => Set.unmodifiable(_excludeClients);
  String get apiBaseUrl => _apiBaseUrl;
  bool get rememberApiToken => _rememberApiToken;

  void _readAll() {
    final p = _prefs;
    _themeMode = _enumByName(ThemeMode.values, p.getString(_kThemeMode), ThemeMode.system);
    _highContrast = p.getBool(_kHighContrast) ?? false;
    _palette = _enumByName(ChartPaletteKind.values, p.getString(_kPalette), ChartPaletteKind.standard);
    _textScale = (p.getDouble(_kTextScale) ?? 1.0).clamp(minTextScale, maxTextScale);
    _reduceMotion = p.getBool(_kReduceMotion) ?? false;
    _showChartPatterns = p.getBool(_kPatterns) ?? true;
    _timeDisplay = _enumByName(TimeDisplay.values, p.getString(_kTimeDisplay), TimeDisplay.local);
    _analysisConfig = _decodeConfig(p.getString(_kAnalysis));
    final excluded = p.getStringList(_kExclude);
    _excludeClients = excluded == null ? defaultExcludeClients : excluded.toSet();
    _apiBaseUrl = p.getString(_kApiUrl) ?? '';
    _rememberApiToken = p.getBool(_kRemember) ?? false;
  }

  static T _enumByName<T extends Enum>(List<T> values, String? name, T fallback) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return fallback;
  }

  static AnalysisConfig _decodeConfig(String? raw) {
    if (raw == null || raw.isEmpty) return const AnalysisConfig();
    try {
      final json = jsonDecode(raw);
      if (json is Map) {
        final config = AnalysisConfig.fromJson(json.cast<String, Object?>());
        // Never load a config that would break analysis (e.g. edited prefs).
        return validateAnalysisConfig(config) == null ? config : const AnalysisConfig();
      }
    } catch (_) {
      // Corrupt or incompatible stored value: fall back to defaults.
    }
    return const AnalysisConfig();
  }

  Future<void> _save(String key, Object value) {
    notifyListeners();
    return switch (value) {
      bool v => _prefs.setBool(key, v),
      double v => _prefs.setDouble(key, v),
      String v => _prefs.setString(key, v),
      List<String> v => _prefs.setStringList(key, v),
      _ => throw ArgumentError.value(value, 'value', 'unsupported type'),
    };
  }

  Future<void> setThemeMode(ThemeMode mode) {
    if (mode == _themeMode) return Future.value();
    _themeMode = mode;
    return _save(_kThemeMode, mode.name);
  }

  Future<void> setHighContrast(bool value) {
    if (value == _highContrast) return Future.value();
    _highContrast = value;
    return _save(_kHighContrast, value);
  }

  Future<void> setPalette(ChartPaletteKind kind) {
    if (kind == _palette) return Future.value();
    _palette = kind;
    return _save(_kPalette, kind.name);
  }

  Future<void> setTextScale(double scale) {
    final s = (scale * 10).round() / 10;
    final clamped = s.clamp(minTextScale, maxTextScale).toDouble();
    if (clamped == _textScale) return Future.value();
    _textScale = clamped;
    return _save(_kTextScale, clamped);
  }

  Future<void> setReduceMotion(bool value) {
    if (value == _reduceMotion) return Future.value();
    _reduceMotion = value;
    return _save(_kReduceMotion, value);
  }

  Future<void> setShowChartPatterns(bool value) {
    if (value == _showChartPatterns) return Future.value();
    _showChartPatterns = value;
    return _save(_kPatterns, value);
  }

  Future<void> setTimeDisplay(TimeDisplay value) {
    if (value == _timeDisplay) return Future.value();
    _timeDisplay = value;
    return _save(_kTimeDisplay, value.name);
  }

  /// Replaces the analysis configuration. Throws [ArgumentError] with a
  /// user-facing message when [config] is invalid (see
  /// [validateAnalysisConfig]); the UI validates fields before calling.
  Future<void> setAnalysisConfig(AnalysisConfig config) {
    final problem = validateAnalysisConfig(config);
    if (problem != null) throw ArgumentError(problem);
    final encoded = jsonEncode(config.toJson());
    if (encoded == jsonEncode(_analysisConfig.toJson())) return Future.value();
    _analysisConfig = config;
    return _save(_kAnalysis, encoded);
  }

  Future<void> setExcludeClients(Set<String> clients) {
    final cleaned = {
      for (final c in clients)
        if (c.trim().isNotEmpty) c.trim()
    };
    if (_setEquals(cleaned, _excludeClients)) return Future.value();
    _excludeClients = cleaned;
    return _save(_kExclude, cleaned.toList()..sort());
  }

  Future<void> setApiBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed == _apiBaseUrl) return Future.value();
    _apiBaseUrl = trimmed;
    return _save(_kApiUrl, trimmed);
  }

  Future<void> setRememberApiToken(bool value) {
    if (value == _rememberApiToken) return Future.value();
    _rememberApiToken = value;
    return _save(_kRemember, value);
  }

  /// Restores every display and analysis setting to its default. The API
  /// address and the "remember token" choice are kept because they are
  /// connection details, not preferences.
  Future<void> resetToDefaults() async {
    _themeMode = ThemeMode.system;
    _highContrast = false;
    _palette = ChartPaletteKind.standard;
    _textScale = 1.0;
    _reduceMotion = false;
    _showChartPatterns = true;
    _timeDisplay = TimeDisplay.local;
    _analysisConfig = const AnalysisConfig();
    _excludeClients = defaultExcludeClients;
    notifyListeners();
    await Future.wait([
      for (final k in [
        _kThemeMode,
        _kHighContrast,
        _kPalette,
        _kTextScale,
        _kReduceMotion,
        _kPatterns,
        _kTimeDisplay,
        _kAnalysis,
        _kExclude,
      ])
        _prefs.remove(k),
    ]);
  }

  static bool _setEquals(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);
}

/// Returns null when [pattern] is a valid regular expression with at least
/// [minGroups] capture groups, otherwise a user-facing error message.
String? validateRegexPattern(String pattern, {int minGroups = 0}) {
  if (pattern.trim().isEmpty) return 'Enter a regular expression.';
  if (pattern.length > 500) return 'Keep the pattern under 500 characters.';
  try {
    final re = RegExp(pattern, caseSensitive: false);
    // Matching the empty alternative reveals how many groups the pattern has.
    final groups = RegExp('(?:$pattern)|', caseSensitive: false).firstMatch('')?.groupCount ?? 0;
    if (groups < minGroups) {
      return minGroups == 1
          ? 'Add a capture group in parentheses, e.g. ^([A-Za-z]+)_, to mark the part to use.'
          : 'The pattern needs at least $minGroups capture groups.';
    }
    re.hasMatch('');
    return null;
  } on FormatException catch (e) {
    final reason = e.message.isEmpty ? 'invalid syntax' : e.message;
    return 'This is not a valid regular expression ($reason). '
        'Check for unbalanced brackets or parentheses.';
  }
}

/// Returns null when [config] is usable, otherwise a user-facing message.
String? validateAnalysisConfig(AnalysisConfig config) {
  final c = config.classifier;
  final listProblem = c.listProblem();
  if (listProblem != null) return listProblem;
  final regexProblem = validateRegexPattern(c.devicePattern, minGroups: 1) ??
      validateRegexPattern(c.navigationButtonPattern) ??
      validateRegexPattern(c.repeatableControlPattern) ??
      validateRegexPattern(c.helpPattern) ??
      validateRegexPattern(c.buildingPattern, minGroups: 1);
  if (regexProblem != null) return regexProblem;
  final t = config.thresholds;
  for (final count in [
    t.powerCycleCount,
    t.buttonMashCount,
    t.navigationThrashCount,
    t.inputHuntCount,
    t.connectionFlapCount,
  ]) {
    if (count < 2 || count > 1000) return 'Issue counts must be between 2 and 1000.';
  }
  for (final window in [
    t.powerCycleWindow,
    t.buttonMashWindow,
    t.navigationThrashWindow,
    t.inputHuntWindow,
    t.connectionFlapWindow,
  ]) {
    if (window <= Duration.zero || window > const Duration(days: 1)) {
      return 'Issue time windows must be between 1 second and 24 hours.';
    }
  }
  if (t.deviceLeftOnHours < 1 || t.deviceLeftOnHours > 168) {
    return '"Long device session after" must be between 1 and 168 hours.';
  }
  if (t.offlineGap < const Duration(minutes: 5) || t.offlineGap > const Duration(days: 30)) {
    return 'The heartbeat gap must be between 5 minutes and 30 days.';
  }
  for (final e in config.ratedLifeHours.entries) {
    if (e.key.trim().isEmpty) return 'Device types cannot be blank.';
    if (!(e.value > 0) || e.value > 1000000) {
      return 'Rated life for ${e.key} must be between 1 and 1,000,000 hours.';
    }
  }
  if (config.maxSessionLength < const Duration(hours: 1) ||
      config.maxSessionLength > const Duration(days: 14)) {
    return 'Maximum session length must be between 1 hour and 14 days.';
  }
  if (config.deviceTypeOverrides.length > 5000) {
    return 'Keep the device type overrides under 5,000 entries.';
  }
  for (final e in config.deviceTypeOverrides.entries) {
    final key = e.key.trim();
    final slash = key.indexOf('/');
    if (slash <= 0 || slash == key.length - 1) {
      return 'Device type overrides must name a room and a device, '
          'such as SCI-101/Projector 1.';
    }
    if (e.value.trim().isEmpty) {
      return 'Choose a device type for ${e.key}.';
    }
  }
  return null;
}
