// Wall-clock bucketing (hour of day, weekday, calendar day, ISO week) in
// either UTC or the machine's local time zone. Pure Dart.

/// Microseconds per hour.
const int usPerHour = 3600 * 1000 * 1000;

/// Microseconds per day.
const int usPerDay = 24 * usPerHour;

/// Microseconds per 7-day week.
const int usPerWeek = 7 * usPerDay;

/// Floor division that rounds toward negative infinity.
int floorDiv(int a, int b) {
  final q = a ~/ b;
  return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q;
}

/// Converts UTC instants into wall-clock buckets for the analysis time zone.
///
/// "Wall-clock" values are encoded as microseconds since the epoch of a UTC
/// [DateTime] whose fields equal the local wall-clock fields. Calendar
/// dates returned to callers ([dateOfDay], [weekStartDate]) are UTC midnight
/// [DateTime]s that represent a calendar date in the analysis zone; format
/// them without calling `toLocal()`.
///
/// The local offset is looked up once per UTC hour and cached, so bucketing
/// a million timestamps costs a few thousand time-zone lookups. Offsets are
/// assumed constant within a UTC hour (true for every zone that changes
/// offset on the hour, which is all of North America and Europe).
class TimeBucketer {
  TimeBucketer({required this.useLocalTime});

  /// `true`: buckets use [DateTime.toLocal]; `false`: UTC.
  final bool useLocalTime;

  final Map<int, int> _offsetByHour = {};

  /// Offset of the analysis zone at [utcMicros], in microseconds.
  int offsetAt(int utcMicros) {
    if (!useLocalTime) return 0;
    final hour = floorDiv(utcMicros, usPerHour);
    return _offsetByHour.putIfAbsent(
      hour,
      () => DateTime.fromMicrosecondsSinceEpoch(
        hour * usPerHour,
        isUtc: true,
      ).toLocal().timeZoneOffset.inMicroseconds,
    );
  }

  /// Wall-clock microseconds for a UTC instant.
  int wallMicros(DateTime utc) {
    final us = utc.microsecondsSinceEpoch;
    return us + offsetAt(us);
  }

  /// Hour of day 0-23 of [utc] in the analysis zone.
  int hourOf(DateTime utc) => hourOfWall(wallMicros(utc));

  /// Weekday 1 (Monday) .. 7 (Sunday) of [utc] in the analysis zone.
  int weekdayOf(DateTime utc) => weekdayOfDay(dayOf(utc));

  /// Day number (days since 1970-01-01) of [utc] in the analysis zone.
  int dayOf(DateTime utc) => floorDiv(wallMicros(utc), usPerDay);

  /// Monday-based week number of [utc] in the analysis zone.
  int weekOf(DateTime utc) => weekOfDay(dayOf(utc));

  /// Hour of day 0-23 for wall-clock microseconds.
  static int hourOfWall(int wall) => floorDiv(wall, usPerHour) % 24;

  /// Weekday 1 (Monday) .. 7 (Sunday) of a day number.
  static int weekdayOfDay(int day) => ((day + 3) % 7 + 7) % 7 + 1;

  /// Monday-based week number of a day number (1970-01-01 was a Thursday).
  static int weekOfDay(int day) => floorDiv(day + 3, 7);

  /// First day number (a Monday) of a week number.
  static int firstDayOfWeek(int week) => week * 7 - 3;

  /// Calendar date for a day number, as UTC midnight.
  static DateTime dateOfDay(int day) =>
      DateTime.fromMicrosecondsSinceEpoch(day * usPerDay, isUtc: true);

  /// Calendar date of the Monday that starts [week], as UTC midnight.
  static DateTime weekStartDate(int week) => dateOfDay(firstDayOfWeek(week));

  /// The UTC instant at which the analysis zone shows the wall-clock time
  /// [wall]. For wall times skipped or repeated by a DST change the result
  /// is within one hour of the intended instant.
  DateTime instantOfWall(int wall) {
    if (!useLocalTime) {
      return DateTime.fromMicrosecondsSinceEpoch(wall, isUtc: true);
    }
    var utc = wall - offsetAt(wall);
    utc = wall - offsetAt(utc);
    return DateTime.fromMicrosecondsSinceEpoch(utc, isUtc: true);
  }

  /// UTC instant at which calendar day [day] starts in the analysis zone.
  DateTime startOfDay(int day) => instantOfWall(day * usPerDay);

  /// Splits `[start, end)` at wall-clock hour boundaries and calls
  /// [onHour] with the wall-clock microseconds of each hour's start and the
  /// microseconds of the interval that fall into it.
  void splitByHour(
    DateTime start,
    DateTime end,
    void Function(int wallHourStart, int micros) onHour,
  ) {
    var t = start.microsecondsSinceEpoch;
    final e = end.microsecondsSinceEpoch;
    while (t < e) {
      final off = offsetAt(t);
      final wall = t + off;
      final wallHour = floorDiv(wall, usPerHour) * usPerHour;
      var next = wallHour + usPerHour - off;
      if (next <= t) next = t + usPerHour;
      final segEnd = next < e ? next : e;
      onHour(wallHour, segEnd - t);
      t = segEnd;
    }
  }

  /// Splits `[start, end)` at wall-clock midnight and calls [onDay] with the
  /// day number and the microseconds that fall into that day.
  void splitByDay(
    DateTime start,
    DateTime end,
    void Function(int day, int micros) onDay,
  ) {
    var t = start.microsecondsSinceEpoch;
    final e = end.microsecondsSinceEpoch;
    while (t < e) {
      final wall = t + offsetAt(t);
      final day = floorDiv(wall, usPerDay);
      var next = instantOfWall((day + 1) * usPerDay).microsecondsSinceEpoch;
      if (next <= t) next = t + usPerHour;
      final segEnd = next < e ? next : e;
      onDay(day, segEnd - t);
      t = segEnd;
    }
  }

  /// Short label of the analysis zone for display, such as `UTC` or
  /// `local time (UTC-05:00)` (offset at [at]).
  String zoneLabel(DateTime at) {
    if (!useLocalTime) return 'UTC';
    final off = Duration(microseconds: offsetAt(at.microsecondsSinceEpoch));
    final sign = off.isNegative ? '-' : '+';
    final abs = off.abs();
    final h = abs.inHours.toString().padLeft(2, '0');
    final m = (abs.inMinutes % 60).toString().padLeft(2, '0');
    return 'local time (UTC$sign$h:$m)';
  }
}
