// Internal: state shared by the analysis stages. Not exported.

import '../../data/models.dart';
import '../classifier.dart';
import '../config.dart';
import '../series.dart';
import '../sessions.dart';
import '../time_bucketing.dart';

/// Pre-computed inputs for every analysis stage.
class AnalysisContext {
  AnalysisContext({
    required this.config,
    required this.classifier,
    required this.bucketer,
    required this.rangeStart,
    required this.rangeEnd,
    required this.rooms,
    required this.roomBuildings,
    required this.eventsByRoom,
    required this.heartbeatsByRoom,
    required this.heartbeatRetentionDays,
  }) {
    _computeCalendar();
  }

  final AnalysisConfig config;
  final MetricClassifier classifier;
  final TimeBucketer bucketer;
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Sorted room names (excluded and admin clients removed).
  final List<String> rooms;
  final Map<String, String> roomBuildings;

  /// Room -> time-ordered classified events.
  final Map<String, List<ClassifiedEvent>> eventsByRoom;

  /// Room -> heartbeat buckets.
  final Map<String, List<HeartbeatBucket>> heartbeatsByRoom;
  final int? heartbeatRetentionDays;

  /// Room -> sessions (filled by the session stage).
  final Map<String, RoomSessions> sessions = {};

  // ---- calendar

  /// First and last day numbers touched by the range.
  late final int firstDay;
  late final int lastDay;

  /// Covered microseconds per day index (day - firstDay).
  late final List<int> dayCoveredUs;

  /// Length of each day in microseconds (23/24/25 h around DST).
  late final List<int> dayLengthUs;

  late final int firstWeek;
  late final int lastWeek;

  /// Observed microseconds per weekday/hour slot ((weekday-1)*24 + hour).
  late final List<int> slotObservedUs;

  int get dayCount => lastDay - firstDay + 1;
  int get weekCount => lastWeek - firstWeek + 1;

  void _computeCalendar() {
    final b = bucketer;
    final endIncl = rangeEnd.subtract(const Duration(microseconds: 1));
    firstDay = b.dayOf(rangeStart);
    lastDay = endIncl.isBefore(rangeStart) ? firstDay : b.dayOf(endIncl);
    dayCoveredUs = List.filled(dayCount, 0);
    b.splitByDay(rangeStart, rangeEnd, (day, us) {
      final i = day - firstDay;
      if (i >= 0 && i < dayCoveredUs.length) dayCoveredUs[i] += us;
    });
    firstWeek = TimeBucketer.weekOfDay(firstDay);
    lastWeek = TimeBucketer.weekOfDay(lastDay);
    // Day lengths for every day of every touched week (for week coverage).
    final firstWeekDay = TimeBucketer.firstDayOfWeek(firstWeek);
    final weekDays = weekCount * 7;
    _weekDayLengthUs = List.generate(weekDays, (i) {
      final d = firstWeekDay + i;
      return b.startOfDay(d + 1).microsecondsSinceEpoch -
          b.startOfDay(d).microsecondsSinceEpoch;
    });
    dayLengthUs = List.generate(
      dayCount,
      (i) => _weekDayLengthUs[firstDay + i - firstWeekDay],
    );
    slotObservedUs = List.filled(168, 0);
    b.splitByHour(rangeStart, rangeEnd, (wallHour, us) {
      slotObservedUs[slotOfWall(wallHour)] += us;
    });
  }

  late final List<int> _weekDayLengthUs;

  /// Heatmap slot index for a wall-clock hour start.
  static int slotOfWall(int wallHour) {
    final day = floorDiv(wallHour, usPerDay);
    return (TimeBucketer.weekdayOfDay(day) - 1) * 24 +
        TimeBucketer.hourOfWall(wallHour);
  }

  /// Coverage (0-1) of day index [i].
  double dayCoverage(int i) =>
      dayLengthUs[i] <= 0 ? 0 : (dayCoveredUs[i] / dayLengthUs[i]).clamp(0, 1);

  /// Coverage (0-1) of week index [w] (week - firstWeek).
  double weekCoverage(int w) {
    final firstWeekDay = TimeBucketer.firstDayOfWeek(firstWeek);
    var covered = 0, total = 0;
    for (var k = 0; k < 7; k++) {
      final d = TimeBucketer.firstDayOfWeek(firstWeek + w) + k;
      total += _weekDayLengthUs[d - firstWeekDay];
      final di = d - firstDay;
      if (di >= 0 && di < dayCount) covered += dayCoveredUs[di];
    }
    return total <= 0 ? 0 : (covered / total).clamp(0, 1);
  }

  /// New zeroed per-day accumulator.
  List<double> newDaily() => List.filled(dayCount, 0.0);

  /// Adds the hours of `[start, end)` to [daily], split by calendar day.
  void addHoursByDay(List<double> daily, DateTime start, DateTime end) {
    bucketer.splitByDay(start, end, (day, us) {
      final i = day - firstDay;
      if (i >= 0 && i < daily.length) daily[i] += us / usPerHour;
    });
  }

  /// Converts a per-day accumulator into a dense daily series.
  List<SeriesPoint> dailySeries(List<double> daily) => List.unmodifiable([
    for (var i = 0; i < daily.length; i++)
      SeriesPoint(
        TimeBucketer.dateOfDay(firstDay + i),
        daily[i],
        coverage: dayCoverage(i),
      ),
  ]);

  /// Sums a per-day accumulator into per-week values (index = week -
  /// firstWeek).
  List<double> weeklyValues(List<double> daily) {
    final out = List.filled(weekCount, 0.0);
    for (var i = 0; i < daily.length; i++) {
      out[TimeBucketer.weekOfDay(firstDay + i) - firstWeek] += daily[i];
    }
    return out;
  }

  /// Converts a per-day accumulator into a dense weekly series.
  List<SeriesPoint> weeklySeries(List<double> daily) {
    final values = weeklyValues(daily);
    return List.unmodifiable([
      for (var w = 0; w < values.length; w++)
        SeriesPoint(
          TimeBucketer.weekStartDate(firstWeek + w),
          values[w],
          coverage: weekCoverage(w),
        ),
    ]);
  }

  /// Building of [room].
  String buildingOf(String room) =>
      roomBuildings[room] ?? classifier.buildingOf(room);
}
