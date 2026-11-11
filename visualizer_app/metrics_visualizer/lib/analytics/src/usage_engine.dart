// Internal: source, device, system, control and audio aggregates. Not
// exported.

import 'dart:math' as math;

import '../classifier.dart';
import '../series.dart';
import '../sessions.dart';
import '../time_bucketing.dart';
import '../usage.dart';
import 'context.dart';

class _InputAcc {
  int selections = 0;
  double hours = 0;
  final Set<String> rooms = {};
}

List<InputShare> _shares(
  Map<String, _InputAcc> accs,
  Map<String, String> labels,
) {
  var totalSel = 0;
  var totalHours = 0.0;
  for (final a in accs.values) {
    totalSel += a.selections;
    totalHours += a.hours;
  }
  final list = [
    for (final e in accs.entries)
      InputShare(
        key: e.key,
        label: labels[e.key] ?? MetricClassifier.inputLabelFor(e.key),
        selections: e.value.selections,
        hours: e.value.hours,
        selectionShare: totalSel == 0 ? 0 : e.value.selections / totalSel,
        timeShare: totalHours == 0 ? 0 : e.value.hours / totalHours,
        roomCount: e.value.rooms.length,
      ),
  ];
  list.sort((a, b) {
    final c = b.hours.compareTo(a.hours);
    if (c != 0) return c;
    final s = b.selections.compareTo(a.selections);
    return s != 0 ? s : a.key.compareTo(b.key);
  });
  return List.unmodifiable(list);
}

/// Source popularity.
InputUsage computeInputUsage(AnalysisContext ctx) {
  final campus = <String, _InputAcc>{};
  final byBuilding = <String, Map<String, _InputAcc>>{};
  final byRoom = <String, Map<String, _InputAcc>>{};
  final labels = <String, String>{};

  void add(String room, String key, {int selections = 0, double hours = 0}) {
    final building = ctx.buildingOf(room);
    for (final acc in [
      campus.putIfAbsent(key, _InputAcc.new),
      byBuilding
          .putIfAbsent(building, () => {})
          .putIfAbsent(key, _InputAcc.new),
      byRoom.putIfAbsent(room, () => {}).putIfAbsent(key, _InputAcc.new),
    ]) {
      acc.selections += selections;
      acc.hours += hours;
      acc.rooms.add(room);
    }
  }

  for (final room in ctx.rooms) {
    final sessions = ctx.sessions[room];
    for (final ce in ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[]) {
      final m = ce.meaning;
      if (m.isSourceSelection) {
        labels[m.inputKey!] = m.inputLabel!;
        // The automatic default source at power-on is not a selection.
        if (sessions?.isAutomaticSelection(ce.event) ?? false) continue;
        add(room, m.inputKey!, selections: 1);
      }
    }
    for (final s in ctx.sessions[room]?.inputs ?? const <InputSession>[]) {
      add(room, s.inputKey, hours: s.hours);
    }
  }

  final campusShares = _shares(campus, labels);
  final buildingShares = {
    for (final b in (byBuilding.keys.toList()..sort()))
      b: _shares(byBuilding[b]!, labels),
  };
  final roomShares = {
    for (final r in (byRoom.keys.toList()..sort()))
      r: _shares(byRoom[r]!, labels),
  };

  const threshold = InputUsage.underusedShareThreshold;
  final underused = <UnderusedInput>[];
  for (final s in campusShares) {
    if (s.timeShare < threshold && s.selectionShare < threshold) {
      underused.add(
        UnderusedInput(
          key: s.key,
          label: s.label,
          kind: UnderuseKind.rarelyUsedCampus,
          selections: s.selections,
          hours: s.hours,
          selectionShare: s.selectionShare,
          timeShare: s.timeShare,
          reason:
              '${s.label} accounts for ${_pct(s.selectionShare)} of source '
              'selections and ${_pct(s.timeShare)} of time on screen across all '
              'rooms.',
        ),
      );
    }
  }
  final roomUnderused = <UnderusedInput>[];
  for (final entry in roomShares.entries) {
    final room = entry.key;
    final building = ctx.buildingOf(room);
    final totalSel = entry.value.fold<int>(0, (a, s) => a + s.selections);
    if (totalSel < InputUsage.minRoomSelectionsForUnderuse) continue;
    for (final s in entry.value) {
      if (s.timeShare < threshold && s.selectionShare < threshold) {
        roomUnderused.add(
          UnderusedInput(
            key: s.key,
            label: s.label,
            kind: UnderuseKind.rarelyUsedInRoom,
            room: room,
            building: building,
            selections: s.selections,
            hours: s.hours,
            selectionShare: s.selectionShare,
            timeShare: s.timeShare,
            reason:
                'In $room, ${s.label} was selected ${s.selections} '
                '${s.selections == 1 ? 'time' : 'times'} '
                '(${_pct(s.selectionShare)} of selections, '
                '${_pct(s.timeShare)} of time on screen).',
          ),
        );
      }
    }
    // Inputs used by at least half of the other rooms in the building (and
    // at least two of them) but never here.
    final siblings = [
      for (final r in roomShares.keys)
        if (r != room && ctx.buildingOf(r) == building) r,
    ];
    if (siblings.length < 2) continue;
    final usedHere = {for (final s in entry.value) s.key};
    final counts = <String, int>{};
    for (final r in siblings) {
      for (final s in roomShares[r]!) {
        counts[s.key] = (counts[s.key] ?? 0) + 1;
      }
    }
    for (final key in (counts.keys.toList()..sort())) {
      final n = counts[key]!;
      if (usedHere.contains(key) || n < 2 || n * 2 < siblings.length) continue;
      final label = labels[key] ?? MetricClassifier.inputLabelFor(key);
      roomUnderused.add(
        UnderusedInput(
          key: key,
          label: label,
          kind: UnderuseKind.neverUsedInRoom,
          room: room,
          building: building,
          selections: 0,
          hours: 0,
          selectionShare: 0,
          timeShare: 0,
          reason:
              '$label was used in $n of ${siblings.length} other rooms in '
              '$building but was not selected in $room during this period.',
        ),
      );
    }
  }
  roomUnderused.sort((a, b) {
    final c = a.room!.compareTo(b.room!);
    return c != 0 ? c : a.key.compareTo(b.key);
  });

  var totalSel = 0;
  var totalHours = 0.0;
  for (final a in campus.values) {
    totalSel += a.selections;
    totalHours += a.hours;
  }
  return InputUsage(
    campus: campusShares,
    byBuilding: Map.unmodifiable(buildingShares),
    byRoom: Map.unmodifiable(roomShares),
    underused: List.unmodifiable([...underused, ...roomUnderused]),
    totalSelections: totalSel,
    totalHours: totalHours,
  );
}

String _pct(double f) {
  final p = f * 100;
  return p > 0 && p < 0.1 ? '<0.1%' : '${p.toStringAsFixed(1)}%';
}

/// Device on-hours.
DeviceUsage computeDeviceUsage(AnalysisContext ctx) {
  final leftOnHours = ctx.config.thresholds.deviceLeftOnHours.toDouble();
  final byDevice = <String, List<DeviceSession>>{};
  for (final room in ctx.rooms) {
    for (final s in ctx.sessions[room]?.devices ?? const <DeviceSession>[]) {
      byDevice.putIfAbsent(s.deviceKey, () => []).add(s);
    }
  }
  final keys = byDevice.keys.toList()..sort();
  final devices = <DeviceStat>[];
  final typeDaily = <String, List<double>>{};
  final typeAcc = <String, List<DeviceStat>>{};
  final hoursByRoom = <String, double>{};
  var total = 0.0;
  var leftOnTotal = 0;
  for (final key in keys) {
    final sessions = byDevice[key]!;
    final first = sessions.first;
    final daily = ctx.newDaily();
    var hours = 0.0, longest = 0.0;
    var leftOn = 0, unterminated = 0;
    var onAtEnd = false;
    for (final s in sessions) {
      final h = s.hours;
      hours += h;
      longest = math.max(longest, h);
      if (h > leftOnHours) leftOn++;
      if (s.unterminated) unterminated++;
      if (s.ongoing) onAtEnd = true;
      ctx.addHoursByDay(daily, s.start, s.end);
    }
    final type = ctx.config.deviceTypeFor(
      first.room,
      first.deviceId,
      first.deviceType,
    );
    final td = typeDaily.putIfAbsent(type, ctx.newDaily);
    for (var i = 0; i < daily.length; i++) {
      td[i] += daily[i];
    }
    final stat = DeviceStat(
      room: first.room,
      building: ctx.buildingOf(first.room),
      deviceId: first.deviceId,
      deviceType: type,
      sessions: sessions.length,
      onHours: hours,
      averageSessionHours: hours / sessions.length,
      longestSessionHours: longest,
      leftOnSessions: leftOn,
      unterminatedSessions: unterminated,
      onAtEnd: onAtEnd,
      daily: ctx.dailySeries(daily),
      weekly: ctx.weeklySeries(daily),
    );
    devices.add(stat);
    typeAcc.putIfAbsent(type, () => []).add(stat);
    hoursByRoom[first.room] = (hoursByRoom[first.room] ?? 0) + hours;
    total += hours;
    leftOnTotal += leftOn;
  }
  final types =
      [
        for (final e in typeAcc.entries)
          () {
            final hours = e.value.fold<double>(0, (a, d) => a + d.onHours);
            return DeviceTypeStat(
              type: e.key,
              deviceCount: e.value.length,
              sessions: e.value.fold<int>(0, (a, d) => a + d.sessions),
              onHours: hours,
              averageHoursPerDevice: hours / e.value.length,
              leftOnSessions: e.value.fold<int>(
                0,
                (a, d) => a + d.leftOnSessions,
              ),
              daily: ctx.dailySeries(typeDaily[e.key]!),
              weekly: ctx.weeklySeries(typeDaily[e.key]!),
            );
          }(),
      ]..sort((a, b) {
        final c = b.onHours.compareTo(a.onHours);
        return c != 0 ? c : a.type.compareTo(b.type);
      });
  return DeviceUsage(
    devices: List.unmodifiable(devices),
    types: List.unmodifiable(types),
    hoursByRoom: Map.unmodifiable(hoursByRoom),
    totalOnHours: total,
    leftOnSessions: leftOnTotal,
  );
}

/// Session-length histogram bucket edges in minutes.
const List<(String, double, double?)> sessionLengthEdges = [
  ('Under 5 min', 0, 5),
  ('5-15 min', 5, 15),
  ('15-30 min', 15, 30),
  ('30-60 min', 30, 60),
  ('1-2 h', 60, 120),
  ('2-4 h', 120, 240),
  ('4-8 h', 240, 480),
  ('8 h+', 480, null),
];

HourWeekdayHeatmap _heatmap(List<double> slots) => HourWeekdayHeatmap(
  List.unmodifiable([
    for (var d = 0; d < 7; d++)
      List<double>.unmodifiable(slots.sublist(d * 24, d * 24 + 24)),
  ]),
);

/// System power-session statistics, including occupancy and utilization.
SystemUsage computeSystemUsage(AnalysisContext ctx) {
  final b = ctx.bucketer;
  final business = ctx.config.businessHours;
  final onByHour = List.filled(24, 0);
  final offByHour = List.filled(24, 0);
  final onByWeekday = List.filled(7, 0);
  final lengthCounts = List.filled(sessionLengthEdges.length, 0);
  final offReasons = {for (final r in OffReason.values) r: 0};
  final otherOffReasons = <String, int>{};
  final campusSlots = List.filled(168, 0.0);
  final campusDaily = ctx.newDaily();
  final allHours = <double>[];
  final rooms = <RoomUtilization>[];

  final businessSlot = List.generate(
    168,
    (i) => business.contains(i ~/ 24 + 1, i % 24),
    growable: false,
  );
  var businessAvailableUs = 0;
  for (var i = 0; i < 168; i++) {
    if (businessSlot[i]) businessAvailableUs += ctx.slotObservedUs[i];
  }

  for (final room in ctx.rooms) {
    final sessions = ctx.sessions[room]?.system ?? const <SystemSession>[];
    final slots = List.filled(168, 0.0);
    var hours = 0.0;
    for (final s in sessions) {
      final h = s.hours;
      hours += h;
      allHours.add(h);
      offReasons[s.offReason] = offReasons[s.offReason]! + 1;
      if (s.offReason == OffReason.other) {
        final text = s.offReasonText ?? '';
        otherOffReasons[text] = (otherOffReasons[text] ?? 0) + 1;
      }
      final minutes = h * 60;
      for (var i = 0; i < sessionLengthEdges.length; i++) {
        final max = sessionLengthEdges[i].$3;
        if (max == null || minutes < max) {
          lengthCounts[i]++;
          break;
        }
      }
      if (!s.startClipped) {
        onByHour[b.hourOf(s.start)]++;
        onByWeekday[b.weekdayOf(s.start) - 1]++;
      }
      if (!s.ongoing && !s.unterminated) offByHour[b.hourOf(s.end)]++;
      b.splitByHour(s.start, s.end, (wallHour, us) {
        slots[AnalysisContext.slotOfWall(wallHour)] += us.toDouble();
      });
      ctx.addHoursByDay(campusDaily, s.start, s.end);
    }
    var businessUsed = 0.0, afterHours = 0.0;
    final occupancy = List.filled(168, 0.0);
    for (var i = 0; i < 168; i++) {
      campusSlots[i] += slots[i];
      if (businessSlot[i]) {
        businessUsed += slots[i];
      } else {
        afterHours += slots[i];
      }
      final obs = ctx.slotObservedUs[i];
      occupancy[i] = obs <= 0 ? 0 : (slots[i] / obs).clamp(0.0, 1.0);
    }
    rooms.add(
      RoomUtilization(
        room: room,
        building: ctx.buildingOf(room),
        sessions: sessions.length,
        hours: hours,
        averageSessionHours: sessions.isEmpty ? 0 : hours / sessions.length,
        businessHoursInUse: businessUsed / usPerHour,
        businessHoursAvailable: businessAvailableUs / usPerHour,
        afterHoursHours: afterHours / usPerHour,
        occupancy: _heatmap(occupancy),
      ),
    );
  }

  final roomCount = ctx.rooms.length;
  final campusOcc = List.filled(168, 0.0);
  for (var i = 0; i < 168; i++) {
    final denom = ctx.slotObservedUs[i] * roomCount;
    campusOcc[i] = denom <= 0 ? 0 : (campusSlots[i] / denom).clamp(0.0, 1.0);
  }
  allHours.sort();
  final total = allHours.fold<double>(0, (a, h) => a + h);
  final median = allHours.isEmpty
      ? 0.0
      : allHours.length.isOdd
      ? allHours[allHours.length ~/ 2]
      : (allHours[allHours.length ~/ 2 - 1] + allHours[allHours.length ~/ 2]) /
            2;
  return SystemUsage(
    sessionCount: allHours.length,
    totalHours: total,
    averageSessionHours: allHours.isEmpty ? 0 : total / allHours.length,
    medianSessionHours: median,
    powerOnByHour: List.unmodifiable(onByHour),
    powerOffByHour: List.unmodifiable(offByHour),
    powerOnByWeekday: List.unmodifiable(onByWeekday),
    occupancy: _heatmap(campusOcc),
    sessionLengths: List.unmodifiable([
      for (var i = 0; i < sessionLengthEdges.length; i++)
        DurationBucket(
          label: sessionLengthEdges[i].$1,
          minMinutes: sessionLengthEdges[i].$2,
          maxMinutes: sessionLengthEdges[i].$3,
          count: lengthCounts[i],
        ),
    ]),
    offReasons: Map.unmodifiable(offReasons),
    otherOffReasons: Map.unmodifiable(otherOffReasons),
    rooms: List.unmodifiable(rooms),
    daily: ctx.dailySeries(campusDaily),
    weekly: ctx.weeklySeries(campusDaily),
    businessHours: business,
    roomCount: roomCount,
  );
}

class _ButtonAcc {
  _ButtonAcc(this.meaning);
  final ClassifiedMetric meaning;
  int presses = 0, taps = 0, holds = 0, repeats = 0;
  final Set<String> rooms = {};

  ButtonStat toStat(String control) => ButtonStat(
    control: control,
    presses: presses,
    taps: taps,
    holds: holds,
    repeats: repeats,
    isNavigation: meaning.isNavigation,
    isSlider: meaning.isSlider,
    roomCount: rooms.length,
  );

  void add(ClassifiedMetric m, String room) {
    rooms.add(room);
    switch (m.uiEvent) {
      case UiEventKind.pressed:
        presses++;
      case UiEventKind.tapped:
        taps++;
      case UiEventKind.held:
        holds++;
      case UiEventKind.repeated:
        repeats++;
      case UiEventKind.released:
      case null:
        break;
    }
  }
}

List<ButtonStat> _sortedButtons(Map<String, _ButtonAcc> accs) {
  final list = [for (final e in accs.entries) e.value.toStat(e.key)];
  list.sort((a, b) {
    final c = b.presses.compareTo(a.presses);
    return c != 0 ? c : a.control.compareTo(b.control);
  });
  return list;
}

/// Touch-panel usage.
UiUsage computeUiUsage(AnalysisContext ctx) {
  final campus = <String, _ButtonAcc>{};
  final rooms = <RoomUiStat>[];
  final shares = <String, int>{};
  final shareRooms = <String, Set<String>>{};
  var total = 0, nav = 0;
  for (final room in ctx.rooms) {
    final local = <String, _ButtonAcc>{};
    var presses = 0, navPresses = 0;
    for (final ce in ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[]) {
      final m = ce.meaning;
      if (m.isControl) {
        final c = m.controlName!;
        campus.putIfAbsent(c, () => _ButtonAcc(m)).add(m, room);
        local.putIfAbsent(c, () => _ButtonAcc(m)).add(m, room);
        if (m.isPress) {
          presses++;
          if (m.isNavigation) navPresses++;
        }
      } else if (m.category == EventCategory.share) {
        final st = m.shareStation!;
        shares[st] = (shares[st] ?? 0) + 1;
        shareRooms.putIfAbsent(st, () => {}).add(room);
      }
    }
    total += presses;
    nav += navPresses;
    if (local.isNotEmpty) {
      rooms.add(
        RoomUiStat(
          room: room,
          presses: presses,
          navigationPresses: navPresses,
          topButtons: List.unmodifiable(_sortedButtons(local).take(10)),
        ),
      );
    }
  }
  final shareStats =
      [
        for (final e in shares.entries)
          ShareStat(
            station: e.key,
            count: e.value,
            roomCount: shareRooms[e.key]!.length,
          ),
      ]..sort((a, b) {
        final c = b.count.compareTo(a.count);
        return c != 0 ? c : a.station.compareTo(b.station);
      });
  return UiUsage(
    totalPresses: total,
    navigationPresses: nav,
    buttons: List.unmodifiable(_sortedButtons(campus)),
    rooms: List.unmodifiable(rooms),
    shares: List.unmodifiable(shareStats),
  );
}

/// Mute and volume usage.
AudioUsage computeAudioUsage(AnalysisContext ctx) {
  final muteCount = <String, int>{};
  final muteHours = <String, double>{};
  final muteRooms = <String, Set<String>>{};
  final volChanges = <String, int>{};
  final volSum = <String, double>{};
  final volMin = <String, int>{};
  final volMax = <String, int>{};
  final volHist = <String, List<int>>{};
  for (final room in ctx.rooms) {
    for (final s in ctx.sessions[room]?.mutes ?? const <MuteSession>[]) {
      if (!s.startClipped) muteCount[s.name] = (muteCount[s.name] ?? 0) + 1;
      muteHours[s.name] = (muteHours[s.name] ?? 0) + s.hours;
      muteRooms.putIfAbsent(s.name, () => {}).add(room);
    }
    for (final ce in ctx.eventsByRoom[room] ?? const <ClassifiedEvent>[]) {
      final m = ce.meaning;
      if (m.category != EventCategory.volume || m.volumeLevel == null) continue;
      final name = m.volumeName!;
      final level = m.volumeLevel!;
      volChanges[name] = (volChanges[name] ?? 0) + 1;
      volSum[name] = (volSum[name] ?? 0) + level;
      volMin[name] = math.min(volMin[name] ?? level, level);
      volMax[name] = math.max(volMax[name] ?? level, level);
      volHist.putIfAbsent(name, () => List.filled(10, 0))[math.min(
        level ~/ 10,
        9,
      )]++;
    }
  }
  final mutes = [
    for (final name in (muteHours.keys.toList()..sort()))
      MuteStat(
        name: name,
        muteCount: muteCount[name] ?? 0,
        mutedHours: muteHours[name]!,
        roomCount: muteRooms[name]!.length,
      ),
  ];
  final volumes = [
    for (final name in (volChanges.keys.toList()..sort()))
      VolumeStat(
        name: name,
        changes: volChanges[name]!,
        averageLevel: volSum[name]! / volChanges[name]!,
        minLevel: volMin[name]!,
        maxLevel: volMax[name]!,
        levelHistogram: List.unmodifiable(volHist[name]!),
      ),
  ];
  return AudioUsage(
    mutes: List.unmodifiable(mutes),
    volumes: List.unmodifiable(volumes),
  );
}
