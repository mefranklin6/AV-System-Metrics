import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../state/settings_state.dart';

/// Consistent, locale-aware number/date formatting for every screen.
///
/// Get one with `Fmt.of(context)`; it follows the user's local/UTC setting
/// and rebuilds the caller when that setting changes.
///
/// ```dart
/// final fmt = Fmt.of(context);
/// Text(fmt.count(1234));          // 1,234
/// Text(fmt.percent(0.256));       // 25.6%
/// Text(fmt.hours(12.5));          // 12.5 h
/// Text(fmt.dateTime(event.timestamp)); // Nov 10, 2026 3:31 PM
/// ```
class Fmt {
  Fmt({required this.utc});

  /// Formatting for [context], following [SettingsState.timeDisplay].
  /// Falls back to local time when no SettingsState is provided.
  /// Call it from `build` only (it subscribes to the setting); in callbacks
  /// use `Fmt(utc: context.read<SettingsState>().timeDisplay == TimeDisplay.utc)`.
  static Fmt of(BuildContext context) {
    try {
      final display = context.select<SettingsState, TimeDisplay>((s) => s.timeDisplay);
      return Fmt(utc: display == TimeDisplay.utc);
    } on ProviderNotFoundException {
      return Fmt(utc: false);
    }
  }

  /// Show times in UTC (true) or local time (false).
  final bool utc;

  static final NumberFormat _int = NumberFormat.decimalPattern();
  static final NumberFormat _oneDecimal = NumberFormat('#,##0.0');
  static final NumberFormat _compact = NumberFormat.compact();
  static final NumberFormat _pct = NumberFormat.decimalPercentPattern(decimalDigits: 1);

  /// Converts a UTC instant to the display zone.
  DateTime display(DateTime t) => utc ? t.toUtc() : t.toLocal();

  /// Zone suffix for labels, e.g. " UTC" (empty for local time).
  String get zoneSuffix => utc ? ' UTC' : '';

  String count(num n) => _int.format(n);
  String compact(num n) => _compact.format(n);
  String decimal(num n) => _oneDecimal.format(n);

  /// [fraction] 0..1 as a percentage with one decimal.
  String percent(double fraction) => _pct.format(fraction);

  /// Hours with one decimal and unit, e.g. "1,234.5 h".
  String hours(double h) => '${_oneDecimal.format(h)} h';

  /// A duration in words, e.g. "2 h 05 min", "45 s".
  String duration(Duration d) {
    if (d.inHours >= 48) return '${_oneDecimal.format(d.inMinutes / 1440)} days';
    if (d.inHours >= 1) {
      return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
    }
    if (d.inMinutes >= 1) return '${d.inMinutes} min';
    return '${d.inSeconds} s';
  }

  String date(DateTime t) => DateFormat.yMMMd().format(display(t));
  String shortDate(DateTime t) => DateFormat.MMMd().format(display(t));
  String time(DateTime t) => '${DateFormat.jm().format(display(t))}$zoneSuffix';
  String dateTime(DateTime t) =>
      '${DateFormat.yMMMd().add_jm().format(display(t))}$zoneSuffix';

  // ---------------------------------------------------------- calendar dates
  //
  // Analytics series dates (SeriesPoint.date, ConnectionDay.date, week
  // starts) are calendar dates in the analysis time zone, encoded as UTC
  // midnight. They are NOT instants: never pass them to [date] or
  // [display] (toLocal() would shift them by a day west of UTC). Use these
  // helpers instead. To format an instant as a calendar date, convert it
  // first: `Fmt.calendarDateIso(fmt.display(instant))`.

  /// A series calendar date with the year, e.g. "Nov 3, 2026".
  static String calendarDate(DateTime date) => DateFormat.yMMMd().format(date);

  /// A short series calendar date for axis labels, e.g. "Nov 3".
  static String calendarDateShort(DateTime date) => DateFormat.MMMd().format(date);

  /// An ISO calendar date for CSV export, e.g. "2026-11-03".
  static String calendarDateIso(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  /// Weekday name for ISO weekday 1 (Monday) .. 7 (Sunday).
  static String weekday(int isoWeekday, {bool short = false}) {
    final d = DateTime.utc(2024, 1, isoWeekday); // 2024-01-01 is a Monday
    return short ? DateFormat.E().format(d) : DateFormat.EEEE().format(d);
  }

  /// Hour-of-day label, e.g. "8 AM".
  static String hourOfDay(int hour) =>
      DateFormat.j().format(DateTime.utc(2024, 1, 1, hour));
}
