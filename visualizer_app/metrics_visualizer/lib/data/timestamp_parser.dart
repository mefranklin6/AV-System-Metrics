// Tolerant, allocation-light timestamp parsing for database exports.
//
// Pure Dart (no Flutter imports) so it can run inside import isolates.

/// Parses a timestamp exported by PostgreSQL, psql, the Analytics API or a
/// spreadsheet and returns it in UTC, or `null` when [input] is not a
/// recognisable timestamp.
///
/// Accepted forms (the date/time separator may be a space or `T`):
/// * psql `timestamptz`: `2026-11-11 00:22:09.709041+00`
/// * offsets with or without a colon: `+00:00`, `-0500`, `+05:30`, `-05`
/// * ISO 8601 / RFC 3339 with `Z`: `2026-11-10T23:31:46.654474000Z`
///   (fractions longer than microseconds are truncated)
/// * a trailing ` UTC`
/// * no offset at all, which is treated as UTC (the database stores UTC)
/// * minutes-only times (`2026-11-11 00:22`) and date-only values
/// * spreadsheet re-saves: `11/10/2026 23:31`, `11/10/2026 11:31:46 PM`
///   (month first unless [dayFirst]; treated as UTC). Use
///   [SlashDateOrder] to decide the order for a whole file.
DateTime? parseTimestamp(String input, {bool dayFirst = false}) {
  var s = input.trim();
  if (s.length >= 2 && s.codeUnitAt(0) == _quote && s.codeUnitAt(s.length - 1) == _quote) {
    s = s.substring(1, s.length - 1).trim();
  }
  if (s.length < 8) return null;
  return _parseIso(s) ?? _parseSlashDate(s, dayFirst: dayFirst);
}

/// Collects evidence about the order of `N/N/YYYY` dates in a file, so a
/// day-first re-save (en-GB, en-AU, fr-CA, ...) is not silently read as
/// month-first.
class SlashDateOrder {
  bool _seen = false;
  bool _firstOver12 = false;
  bool _secondOver12 = false;

  /// Records [value] if it is a slash date.
  void add(String value) {
    final s = value.trim();
    // Cheap pre-check: ISO timestamps start with a 4-digit year.
    if (s.length < 8 || !s.contains('/')) return;
    final m = _slashPrefix.firstMatch(s.startsWith('"') ? s.substring(1) : s);
    if (m == null) return;
    _seen = true;
    if (int.parse(m.group(1)!) > 12) _firstOver12 = true;
    if (int.parse(m.group(2)!) > 12) _secondOver12 = true;
  }

  /// Whether any slash dates were seen.
  bool get hasSlashDates => _seen;

  /// Day first: some first part is above 12 and no second part is.
  bool get dayFirst => _firstOver12 && !_secondOver12;

  /// Slash dates were seen but none had a part above 12, so the order
  /// could not be confirmed (month first is assumed).
  bool get ambiguous => _seen && !_firstOver12 && !_secondOver12;

  static final RegExp _slashPrefix = RegExp(r'^(\d{1,2})/(\d{1,2})/\d{4}');
}

const int _quote = 0x22; // "
const int _zero = 0x30;

int _digits(String s, int start, int count) {
  if (start + count > s.length) return -1;
  var value = 0;
  for (var i = start; i < start + count; i++) {
    final d = s.codeUnitAt(i) - _zero;
    if (d < 0 || d > 9) return -1;
    value = value * 10 + d;
  }
  return value;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

DateTime? _parseIso(String s) {
  final year = _digits(s, 0, 4);
  if (year < 0 || s.length < 10) return null;
  final sep1 = s.codeUnitAt(4);
  if (sep1 != 0x2D && sep1 != 0x2F) return null; // - or /
  final month = _digits(s, 5, 2);
  if (month < 0 || s.codeUnitAt(7) != sep1) return null;
  final day = _digits(s, 8, 2);
  if (day < 0) return null;

  var hour = 0, minute = 0, second = 0, micro = 0;
  var i = 10;
  if (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c != 0x20 && c != 0x54 && c != 0x74) return null; // ' ', T, t
    i++;
    hour = _digits(s, i, 2);
    if (hour < 0 || i + 2 >= s.length || s.codeUnitAt(i + 2) != 0x3A) {
      return null;
    }
    minute = _digits(s, i + 3, 2);
    if (minute < 0) return null;
    i += 5;
    if (i < s.length && s.codeUnitAt(i) == 0x3A) {
      second = _digits(s, i + 1, 2);
      if (second < 0) return null;
      i += 3;
      if (i < s.length && (s.codeUnitAt(i) == 0x2E || s.codeUnitAt(i) == 0x2C)) {
        i++;
        var digits = 0;
        while (i < s.length && _isDigit(s.codeUnitAt(i))) {
          if (digits < 6) {
            micro = micro * 10 + (s.codeUnitAt(i) - _zero);
          }
          digits++;
          i++;
        }
        if (digits == 0) return null;
        for (var pad = digits; pad < 6; pad++) {
          micro *= 10;
        }
      }
    }
  }

  // Optional whitespace then the zone designator.
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  var offsetMinutes = 0;
  if (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == 0x5A || c == 0x7A) {
      // Z
      i++;
    } else if (c == 0x2B || c == 0x2D) {
      // + or -
      final sign = c == 0x2D ? -1 : 1;
      final oh = _digits(s, i + 1, 2);
      if (oh < 0 || oh > 23) return null;
      i += 3;
      var om = 0;
      if (i < s.length && s.codeUnitAt(i) == 0x3A) {
        om = _digits(s, i + 1, 2);
        if (om < 0) return null;
        i += 3;
      } else if (i + 1 < s.length && _isDigit(s.codeUnitAt(i))) {
        om = _digits(s, i, 2);
        if (om < 0) return null;
        i += 2;
      }
      if (om > 59) return null;
      offsetMinutes = sign * (oh * 60 + om);
    } else if (s.startsWith('UTC', i) || s.startsWith('utc', i)) {
      i += 3;
    } else {
      return null;
    }
  }
  while (i < s.length && s.codeUnitAt(i) == 0x20) {
    i++;
  }
  if (i != s.length) return null;
  return _build(year, month, day, hour, minute, second, micro, offsetMinutes);
}

DateTime? _build(int year, int month, int day, int hour, int minute,
    int second, int micro, int offsetMinutes) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  if (hour > 24 || minute > 59 || second > 60) return null;
  if (hour == 24 && (minute != 0 || second != 0 || micro != 0)) return null;
  final leap = second == 60;
  final dt = DateTime.utc(year, month, day, hour, minute, leap ? 59 : second,
      micro ~/ 1000, micro % 1000);
  // Reject impossible dates such as 2026-02-30 (DateTime would roll over).
  if (hour != 24 && (dt.month != month || dt.day != day)) return null;
  final adjusted = leap ? dt.add(const Duration(seconds: 1)) : dt;
  return offsetMinutes == 0
      ? adjusted
      : adjusted.subtract(Duration(minutes: offsetMinutes));
}

final RegExp _usPattern = RegExp(
  r'^(\d{1,2})/(\d{1,2})/(\d{4})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?\s*([AaPp][Mm])?)?$',
);

DateTime? _parseSlashDate(String s, {required bool dayFirst}) {
  final m = _usPattern.firstMatch(s);
  if (m == null) return null;
  final a = int.parse(m.group(1)!);
  final b = int.parse(m.group(2)!);
  final month = dayFirst ? b : a;
  final day = dayFirst ? a : b;
  final year = int.parse(m.group(3)!);
  var hour = m.group(4) == null ? 0 : int.parse(m.group(4)!);
  final minute = m.group(5) == null ? 0 : int.parse(m.group(5)!);
  final second = m.group(6) == null ? 0 : int.parse(m.group(6)!);
  var micro = 0;
  final frac = m.group(7);
  if (frac != null) {
    final six = frac.length >= 6 ? frac.substring(0, 6) : frac.padRight(6, '0');
    micro = int.parse(six);
  }
  final ampm = m.group(8)?.toLowerCase();
  if (ampm != null) {
    if (hour < 1 || hour > 12) return null;
    if (ampm == 'am' && hour == 12) hour = 0;
    if (ampm == 'pm' && hour != 12) hour += 12;
  }
  return _build(year, month, day, hour, minute, second, micro, 0);
}

/// Formats [t] as RFC 3339 UTC with microseconds, the format the Analytics
/// API uses (e.g. `2026-11-11T00:22:09.709041Z`).
String formatRfc3339Utc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final micros = (u.millisecond * 1000 + u.microsecond).toString().padLeft(6, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}.${micros}Z';
}
