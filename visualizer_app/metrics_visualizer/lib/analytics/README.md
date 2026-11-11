# Analytics engine

`lib/analytics/` turns raw `metric_events` rows into the numbers that the
Metrics Visualizer shows. This document is for two kinds of reader:

- **UI developers**: what to call and what each result contains.
- **Administrators and reviewers**: how each number is calculated, and what
  the engine assumes. Use this section when you need to explain a figure
  in a budget or design decision.

The engine is pure Dart. It has no Flutter imports, so it runs in
`Isolate.run` / `compute` and in plain tests. For the same input it always
gives the same output, and it never reads the clock.

---

## 1. API guide

```dart
import 'package:metrics_visualizer/analytics/analytics.dart';

final AnalysisResult r = analyze(dataset, config); // excludeClients defaults to {'AVSM-System'}

// Off the UI thread:
final r = await Isolate.run(() => analyze(dataset, config, excludeClients: excluded));
```

`analytics.dart` is the only import you need. It re-exports every public
type, the data model (`MetricEvent`, `Dataset`, ...), `config.dart` and the
display labels.

### `AnalysisResult`

| Field | Type | Use it for |
| --- | --- | --- |
| `rangeStart`, `rangeEnd` | `DateTime` (UTC) | The range that was analysed. It is widened if any events fall outside the dataset's declared range. |
| `timeZoneLabel`, `useLocalTime` | `String`, `bool` | Label for every hour, weekday and date bucket, for example "UTC" or "local time (UTC-05:00)". |
| `rooms`, `buildings`, `roomBuildings` | lists/map | Filters and grouping. |
| `overview` | `OverviewStats` | KPI tiles: rooms, buildings, events, system hours, average daily hours per room, most-used source, issue counts, busiest slot and day. |
| `inputs` | `InputUsage` | Source share charts and the rarely-used list. |
| `devices` | `DeviceUsage` | Device on-hours per device and type, daily/weekly trends, long-session counts. |
| `system` | `SystemUsage` | Power-on/off time of day, hour x weekday heatmap, session lengths, off reasons (`offReasons`, plus `otherOffReasons` with reasons kept as logged), utilization per room. |
| `connectivity` | `ConnectivityReport` | Connect/disconnect timeline, repeated changes, heartbeat online %, heartbeat gaps. |
| `ui` | `UiUsage` | Most-pressed controls, navigation share, wireless shares by metric. |
| `audio` | `AudioUsage` | Mute counts and time muted per channel, volume level distribution. |
| `issues` | `List<Issue>` | Issues screen (patterns worth reviewing; sorted by start time, then most severe first). |
| `forecast` | `ForecastReport` | Device life and source trend forecasts, plus `assumptions` to show next to them. |
| `roomSummaries` | `List<RoomSummary>` | Room list and the header of the room detail view. |
| `sessions` | `Map<String, RoomSessions>` | Raw reconstructed sessions for timelines in the room drill-down. |
| `dataQuality` | `DataQuality` | Skipped rows, unrecognised metrics, orphan stops, unterminated sessions, configuration warnings. |

Helpers: `roomSummary(room)`, `issuesForRoom(room)`, `devicesForRoom(room)`,
`roomsInBuilding(building)`, `isEmpty`.

### Per-room versions of the main charts

| Chart | Where to find the room's data |
| --- | --- |
| Source share | `inputs.byRoom[room]` (and `inputs.byBuilding[building]`) |
| Heatmap and utilization | `system.rooms` → `RoomUtilization.occupancy`, `.utilization` |
| Device hours | `devicesForRoom(room)` → `DeviceStat.daily` / `.weekly` |
| Connectivity | `connectivity.rooms` → `RoomConnectivity` |
| Controls | `ui.rooms` → `RoomUiStat.topButtons` |
| Sessions timeline | `sessions[room]` → `.system`, `.devices`, `.inputs`, `.mutes` |

### Conventions

- **Instants** (`start`, `end`, `time`) are UTC `DateTime`s. Convert them for
  display with `toLocal()` when `useLocalTime` is on.
- **Calendar dates** in series (`SeriesPoint.date`, `ConnectionDay.date`)
  are dates in the analysis time zone, stored as UTC midnight. Format them
  directly and do **not** call `toLocal()` on them. Weekly points start on
  Monday.
- `SeriesPoint.coverage` < 1 marks a partial day or week at either end of
  the range. Show partial periods differently (for example hatched or
  labelled "partial"), because their values are naturally lower.
- **Weekdays** use `DateTime.weekday` numbering (1 = Monday). Arrays indexed
  by weekday use index 0 = Monday. `HourWeekdayHeatmap.valueAt(weekday, hour)`.
- **Fractions** (`share`, `utilization`, `onlineFraction`, heatmap values)
  run from 0 to 1. Format them as percentages in the UI.
- **Display labels:** use `IssueType.label`, `IssueSeverity.label`,
  `IssueArea.label`, `OffReason.label`, `PowerSource.label`,
  `TrendDirection.label`, `UnderuseKind.label`, `EventCategory.label`,
  `weekdayNames` and `weekdayShortNames` (all in `labels.dart`), so every
  screen uses the same wording.
- Every `Issue` has `title`, `explanation` and `suggestedAction` ready to
  display. The explanation states only what the data shows; the suggested
  action lists neutral things worth checking (see 2.5). `DeviceForecast.explanation`,
  `InputTrend.explanation`, `UnderusedInput.reason` and
  `ConnectivityReport.coverageNote` are also ready to display.
- **Lists are unmodifiable.** Copy a list before sorting it in the UI.

### Configuration (`config.dart`)

`AnalysisConfig` holds `classifier` (the event recognition rules, see 2.1),
`thresholds` (issue detectors), `ratedLifeHours` (keyed by upper-case device
type), `maxSessionLength` (16 h by default), `useLocalTime`,
`businessHours` (weekdays 07:00-22:00 by default) and `deviceTypeOverrides`.
All of these round-trip through JSON. Settings saved by earlier versions
load: missing keys get their defaults, and patterns that were an earlier
default are upgraded to the current default. If a regex pattern is
invalid, the engine uses the default pattern and reports the problem in
`dataQuality.warnings`.

---

## 2. Methodology

### 2.1 What the data is, and how events are recognized

Control processors from any vendor (Extron, Crestron, AMX, Q-SYS or custom)
send events with four fields: client name, timestamp, metric and action.
The engine does not know the program running in a room or what its
controls do. It recognizes events by the naming conventions in
[`Implementation_Guide.md`](../../../../Implementation_Guide.md) at the
repository root, which is the source of these rules. The defaults accept
the guide's **recommended** names and its **also recognized** names.
Matching ignores capitalization and surrounding spaces. Every name list and
pattern below is a field of `ClassifierConfig` and can be changed in
Settings to match a program that uses other names.

| Category | Recommended | Also recognized by default | Setting |
| --- | --- | --- | --- |
| System power | `System Power` `Started` / `Stopped` | `System`, `System Power - <reason>`, `System - <reason>` | `systemPowerNames` |
| Power reason | `System Power - User`, `- Schedule`, `- Inactivity`, `- Remote`, `- Restore` | synonyms such as `Scheduled`, `Idle`, `Timeout`, `Manual`, `Recovery`; any other reason is kept and shown exactly as logged | `powerReasonSynonyms` |
| Source (source on the main display) | `Source - <name>` `Started` | `Source: <name>`, `Source Select: <name>`, `Input - <name>`, `Input: <name>`, with `Started` or `Trace`; a bare name from the source names list (`hdmi`, `doc_cam`, ...). `Stopped` ends the source's time on screen. | `sourcePrefixes`, `inputNames` |
| Device power | `<Device> <n>` `Started` / `Stopped` (`Projector 1`) | `<Device>_<n>`, `<Device> <n> Power`, `<Device> Power` | `devicePattern`, `deviceTypeOverrides` |
| Device communication | any metric with `Connected` / `Disconnected` | | |
| Program start | `Program Start` `Started` | `Initialize`, `Program Started`, `Processor Boot`, with `Started` or `Trace` | `programStartNames` |
| Startup / shutdown complete (optional) | `System Startup Complete` / `System Shutdown Complete` `Trace` | `System Startup Sequence Complete` / `System Shutdown Sequence Complete` | `startupCompleteNames`, `shutdownCompleteNames` |
| Control | `<Control> Pressed` `Trace` | `<Control> Released`, `Tapped`, `Held`, `Repeated` | `navigationButtonPattern`, `repeatableControlPattern` |
| Help-labelled | any event whose metric contains the word `help`, whatever the action | | `helpPattern` |
| Mute | `<Channel> Mute` `Started` / `Stopped` | `<Channel> Muted`; action `Muted` / `Unmuted` with the channel as metric | |
| Volume | action `Level <0-100>` | `Level <number>` followed by any text (`Level 31 (Device -18.8)`) | |
| Wireless share | action `Share`; the metric is kept as logged | | |
| Heartbeat | action `Heartbeat` | | |

Other names are classified in this order, so an event matches the first
rule that applies: heartbeat, help-labelled, communication, mute action,
volume action, share; then for `Started` / `Stopped`: system power, program
start, mute name, source, device; then for `Trace`: program start,
startup / shutdown complete, source, control. Everything else is kept for
the room timeline and listed under data quality.

The ControlScript template this project started with is one program among
many. Its names (`System - User`, `Initialize`, `Projector_1`, bare source
names such as `hdmi`, `Btn_Nav_Display Pressed`) are among the also
recognized forms, so its data needs no settings changes.

Device type is the text before the device number with `_` and `-` turned
into spaces, upper-cased: `Projector 1` and `Projector_1` are `PROJECTOR`,
`Laser Projector 2` is `LASER PROJECTOR`. A source's key is its name in
lower case, so `Source - Document Camera` and the bare name `doc_cam` (shown
as `Document Camera`) are the same source.

Rooms are client names such as `SCI-101` or `BSS_245`. The building is the
leading letters of the client name in upper case (`buildingPattern`), so
`Holt_171` and `HOLT_155` are both in building `HOLT`. Rooms are not
merged, because client names are kept exactly as they are. The
`AVSM-System` client is the server itself, so it is never counted as a
room.

### 2.2 Sessions (how "on time" is measured)

Events are processed room by room in time order.

**System power sessions** start at a system power `Started`. A
startup-complete trace also starts a session if none is open. The session's
`startSource` is the reason group of the opening event and `startReason` is
the reason text as logged. A session ends at the first of these:

| End | Off reason |
| --- | --- |
| System power `Stopped` with reason `User` (or a synonym) | user |
| ... `Inactivity`, `Idle`, `Timeout` ... | inactivity |
| ... `Schedule`, `Scheduled` ... | scheduled |
| ... `Remote` ... | remote |
| ... any other reason, including `Restore` | other, with the text in `offReasonText` |
| System power `Stopped` with no reason, or a shutdown-complete trace | unknown (no reason logged) |
| A program start | reinitialized |
| No end event within `maxSessionLength` (16 h) | capped. The session is marked *unterminated* and ends at the cap, so a lost event cannot inflate totals. |
| Still on when the data ends | truncated. The session ends at the end of the range and is marked *ongoing*. |

The off event does not need to match the on event. For example,
`System Power - Inactivity` Stopped ends a session that
`System Power - User` started. A `Started` while a session is already open
(for example a reset that keeps the system on) is a marker only: it does
not start a second session, is not a power-on for power-cycling detection,
and is counted in `dataQuality.duplicateStarts`.

**Device sessions** run from a device's `Started` to its own `Stopped`, or
to a program start, the cap, or the end of the range. A repeated `Started`
is ignored. Device sessions do **not** end when the system powers off:
devices often report their own `Stopped` after cooling down, and a device
that stays on after the system is off should show up as a long session. So
a device session that passes the cap is kept open: if the device's next
event is its `Stopped` (or a program start)
within 7 days of the start, the session ends there with its **true
length**, which can be longer than the cap. If the device is `Started`
again first, or nothing arrives within 7 days, the `Stopped` was lost and
the session ends at the cap (*unterminated*).

**Status re-syncs.** Some programs log `Stopped` for devices that report
"off" after a processor boot or a lost connection. A device `Stopped` with
nothing to stop is treated as a re-sync, not as a session or an orphan,
when it comes within 15 minutes after a program start, or more than 15
minutes after the room was turned off. A device's first `Stopped` after any
program start in the range never creates a start-clipped session.

**Source sessions** ("time on screen") run from a source's selection until
the next of these: a different source is selected, a `Stopped` for the
source on screen, the system powers off, a program start, or the cap.
Selecting the current source again counts as a selection but does not
split the session.

**Automatic default source.** Many programs select a default source
themselves at power-on. Following the guide, the first selection after a
power-on is counted as the automatic default source when it comes within
15 seconds of the power-on, or before the optional startup-complete trace
when that trace follows within 2 minutes of the power-on. It is **not
counted as a selection** (it still counts for time on screen), and it is
left out of rapid source changes and source trends. These events are listed
in `RoomSessions.automaticInputStarts`.

**Mute sessions** run from `Started` / `Muted` to `Stopped` / `Unmuted`,
power-off, a program start or the cap. The session name is the channel
(`Program Audio` for `Program Audio Mute` and `Program Audio Muted`).

**Range edges.** Sometimes the first event for a subject in the data is
`Stopped`, which means it was already on when the data begins. If that
`Stopped` comes within `maxSessionLength` of the start of the range, the
session is counted from the start of the range and marked *start
clipped*. Otherwise the `Stopped` is counted as an orphan in
`dataQuality.orphanStops`. Scheduled shut-downs are logged every night even
when the room is already off, so they never create clipped sessions. Events
outside the analysed range are ignored.

### 2.3 Usage figures

- **Source share:** *selections* is the number of source selections,
  leaving out the automatic default source (see 2.2). *Time on screen* is
  the total length of source sessions. Shares are calculated campus-wide,
  per building and per room. A source is listed as **rarely used** in
  three cases:
  - campus-wide, it has under 2% of both selections and time;
  - in a room with at least 20 selections, it has under 2% of both
    selections and time;
  - it was selected in at least half (and at least 2) of the other rooms in
    the same building but never in this room. The data only shows sources
    that were selected, so it cannot say whether the source exists in this
    room.
- **Device on-hours:** the total length of device sessions, split across
  calendar days and Monday-based weeks. **Long sessions** are longer than
  `deviceLeftOnHours` (12 h). Devices are grouped by the type read from
  their metric (see 2.1) unless `deviceTypeOverrides` sets a type for that
  `room/device`, for example a flat panel that a program logs as
  `Projector 1`.
- **Occupancy heatmap:** for each weekday and hour, the share of time that
  rooms had the system on:
  (system-on time of all rooms in that hour slot) ÷ (time that slot
  appears in the range × number of rooms). Partial hours at either end of
  the range are weighted correctly. Every room in the data counts, even
  rooms that only sent heartbeats.
- **Utilization** for a room is the system-on time inside the business-hours
  window (weekdays 07:00-22:00 by default; you can change it) ÷ the
  business-hours time in the range. **After-hours** is the system-on time
  outside that window, which is useful for energy planning.
- **Power-on/off time of day:** the hour of each session's start, leaving
  out start-clipped sessions, and of each session's end, leaving out ongoing
  and capped sessions.
- **Session length buckets:** under 5 min, 5-15 min, 15-30 min, 30-60 min,
  1-2 h, 2-4 h, 4-8 h, and 8 h or more.
- **Controls:** only `Pressed` counts as a press. Panels often log
  `Tapped` or `Released` for the same press, and `Held` and `Repeated`
  describe the same physical press; all of them stay on the timeline.
  Control names are shown verbatim and are not interpreted. **Navigation**
  controls are those whose name contains `Nav`, `Navigation`, `Page`,
  `Menu`, `Tab`, `Back` or `Home` as a separate word or as a part
  separated by `_`, `-` or a space (`navigationButtonPattern`).
  **Repeatable** controls are those whose name contains `Up`, `Down`,
  `Volume`, `Vol`, `Zoom`, `Pan`, `Tilt`, `Focus`, `Left`, `Right`, `In`,
  `Out`, `Slider`, `Sldr` or `Fader` as a part
  (`repeatableControlPattern`). Help-labelled events in control form
  (`Help Pressed`) also count in the control statistics.
- **Help-labelled events:** every event whose metric contains the word
  `help`, whatever its action (`helpPattern`). The engine counts them and
  reports when they happened; it does not assume what the control does in
  the room's program. `RoomSummary.helpEvents` counts all of them, so a
  program that logs both a press and a `Started` / `Stopped` pair counts
  three events for one use.
- **Time zone:** hour-of-day, weekday and date buckets use the computer's
  local time zone when `useLocalTime` is on, and UTC otherwise. The offset
  is looked up for every UTC hour, so daylight-saving changes are handled.
  In the rare zones whose offset changes at a time other than the top of
  the hour, a bucket next to that change can be off by part of an hour.

### 2.4 Connectivity and uptime

- **Connection events** are listed exactly as they were logged. Counts per
  day, room and device, and flapping, use **state changes** only: a repeated
  report of the same state (some programs report a device as connected at
  once and again 10 s later) is not counted. A **burst of changes** is
  `connectionFlapCount` (4) or more changes for the same device within
  `connectionFlapWindow` (15 min).
- **Heartbeat coverage** is the period that heartbeat data actually covers.
  It runs from the first to the last heartbeat hour in the data, limited
  to the analysed range and to the server's retention period when that is
  known. Online figures are only calculated inside coverage, because the
  server has deleted older heartbeats.
- Each room is judged from its **first sign of life** (heartbeat or event)
  to the end of coverage, so a room commissioned or renamed partway through
  has no "offline" time before it joined, while a room that stopped
  reporting is still flagged. A room that sent **no heartbeats at all**
  (heartbeats can be turned off in its program) has no online figure and
  no offline periods.
- An hour counts as **online** for a room when the room sent at least one
  heartbeat or any event in that hour. **Online %** is online hours ÷
  the room's covered hours, for the whole range and for each day.
- An **offline period** (heartbeat gap) is a run of silent hours inside
  coverage that is longer than `offlineGap` (2 h). Heartbeats are counted per hour, so the
  real outage can be up to two hours longer than the reported one.
- **Last seen** is the exact time of the room's last event, or the start of
  its last heartbeat hour when that is later.

### 2.5 Patterns worth reviewing (issue detection)

The detectors look for **bursts**: a burst is `count` or more qualifying
events in one room within `window`. The window includes events exactly
`window` apart. Bursts that overlap are merged into one issue, so one
episode produces one issue. Severity rises to the next level at twice the
threshold.

An issue reports a pattern in the data, not a cause. The engine does not
know the room's control program, what its controls do, or why people used
them. So each `explanation` states only what the data shows (counts,
durations, metric names quoted as logged), and each `suggestedAction` lists
neutral follow-ups for an analyst, such as looking at the room timeline,
checking what a control does in the room's program, or comparing with a
device's own logs. `Issue.area` (`IssueArea`) says which data the pattern
comes from.

| Issue (`IssueType`) | Qualifying events | Default threshold | Severity | Area |
| --- | --- | --- | --- | --- |
| Repeated power cycling (`rapidPowerCycling`) | system power `Started` that opened a session | 3 in 10 min | warning, critical at 2x | `systemPower` |
| Repeated presses of one control (`repeatedPresses`) | `Pressed` of the **same** control | 6 in 10 s (18 for repeatable controls, see 2.3) | warning, critical at 2x | `controls` |
| Rapid navigation presses (`rapidNavigation`) | navigation `Pressed` events | 8 in 30 s | info, warning at 2x | `controls` |
| Rapid source changes (`rapidSourceChanges`) | source selections covering at least 2 different sources | 5 in 2 min | info, warning at 2x | `sources` |
| Repeated connection changes (`connectionFlapping`) | Connected/Disconnected changes of the same metric | 4 in 15 min | warning, critical at 2x | `connectivity` |
| Long device session (`longDeviceSession`) | one device session longer than 12 h | > 12 h | warning. Info if capped (the `Stopped` may be missing). Critical at 2x or at 24 h. | `devices` |
| Heartbeat gap (`heartbeatGap`) | offline period (see 2.4) | > 2 h | warning, critical if 24 h or more or continuing at the end of the data | `reporting` |
| Help-labelled events (`helpEvents`) | help-labelled events (any action), grouped within 1 h | each group | info; warning when the group holds 3 or more events other than `Stopped`, `Released`, `Tapped`, `Held` and `Repeated` | `help` |

The threshold fields keep their original names (`buttonMashCount`,
`navigationThrashCount`, `inputHuntCount`, `connectionFlapCount`,
`deviceLeftOnHours`, `offlineGap`) so saved settings still load.

Each issue keeps up to 50 evidence events for the drill-down.

### 2.6 Forecasting

- **Observed hours only.** Hours a device ran before metrics collection
  began are unknown. A projector installed years ago has used more of its
  rated life than these figures show, so the real replacement date may be
  **sooner** than the projection.
- **Weekly series.** Device on-hours and source selections are totalled per
  Monday-based week. Only **complete** weeks are used for a fit, and a
  device's fit starts with its room's first reporting week (the week after
  it, when the room started reporting partway through the data, because
  that first week is only partly reported). At least
  **3 complete weeks** are needed. With fewer, the result is "not enough
  data" and there are no projections.
- **Trend.** The engine fits an ordinary least-squares line to weekly hours
  (or selections), reporting the slope, intercept, R², the slope's standard
  error and the residual standard error.
- **Projections** at 1, 3 and 5 years add the projected weekly hours to the
  observed hours (`TrendRules.projectedWeeklyHours`, also available as
  `DeviceForecast.projectedWeeklyHours` for charts). Each week's projected
  hours stay between the quietest and the busiest complete week observed
  (and within 0-168).
  - *Expected*: for a **stable** trend, the average weekly hours (a slope
    the rules call "no clear trend" is never extrapolated). For a growing
    or declining trend, the fitted line for up to 52 weeks, then held at
    that week's level.
  - The *low* and *high* band uses the slope minus or plus one standard
    error, pivoting on the average week, with the same rules.
  - *Flat rate* assumes the average weekly hours continue unchanged.
- **Rated life date:** the date when observed plus projected hours reach the
  rated life for the device type (`ratedLifeHours`). It is calculated for
  the expected trend, the band (earliest and latest) and the flat rate. The
  date is `null` when no rated life is configured for the type, when the
  rated life has already been reached (`ratedLifeReached`), or when it
  would take more than 50 years.
- **Classification:** a trend is growing or declining only when two things
  are true: the slope is at least 2% of the weekly average per week, and the
  fit's R² is at least 0.25. Otherwise the trend is stable. Source trends
  also need at least 10 selections across the complete weeks.
- **Device types** come from metric names (see 2.1). A device whose name
  does not say what it is is forecast with the rated life of the logged
  type unless `deviceTypeOverrides` sets its type.

A straight-line forecast from a few weeks of data, especially data that
includes term breaks, is a rough guide and not a prediction. Prefer at
least a full term of data before making budget decisions.

### 2.7 Performance

Classification is cached per distinct (metric, action) pair, and
regular expressions are compiled once per analysis. The engine makes a
small number of linear passes over the data, so its cost is O(n) for
n events. Sorting the output adds O(k log k) for k results. The test
suite analyses 1,000,000 events plus 250,000 hourly heartbeat buckets in
about 2 seconds on a developer laptop.
