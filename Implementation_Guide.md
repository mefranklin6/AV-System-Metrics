# Implementation Guide: What to Log

This guide is for AV programmers adding AV System Metrics to a control program on any platform: Extron, Crestron, AMX, Q-SYS, or anything else that can send HTTP. It describes **which events to log and how to name them** so that the data can be compared across rooms, buildings and control platforms, and so that the [Metrics Visualizer](visualizer_app/metrics_visualizer/README.md) can analyze it without knowing anything about your program.

How to *send* events (the HTTP contract, batching, retries and client methods) is covered separately in the [Client Module Developer Guide](Clients/Developer%20Guide/README.md). Every client exposes the same methods, so this guide uses them by name: `start()`, `stop()`, `trace()`, `connected()`, `disconnected()`, `custom()` and `heartbeat()`.

Nothing here is mandatory. The ingest service stores any `metric` and `action` text up to 128 characters. Follow the conventions in this guide where you can, and use the Visualizer's **Settings > Event recognition** to match names you cannot change.

## Contents

- [Principles](#principles)
- [Client names](#client-names)
- [Event conventions](#event-conventions)
- [What the Visualizer derives from each event](#what-the-visualizer-derives-from-each-event)
- [Choosing names](#choosing-names)
- [Matching an existing program](#matching-an-existing-program)
- [Checking your implementation](#checking-your-implementation)
- [Example: one room, one session](#example-one-room-one-session)

## Principles

1. **Log facts, not interpretations.** Record what the control program did or saw: "system powered on", "source HDMI 1 selected", "button Camera Preset 2 pressed". Do not log conclusions such as "user confused". The analyst draws conclusions, and the same event can mean different things in different rooms.
2. **Use `Started` and `Stopped` for things that have a duration** (system power, device power, mutes, a source being routed). Use `Trace` for momentary events (a button press). Use `Connected` and `Disconnected` for communication with a device.
3. **Log state changes, not polls.** Send `Started` when something turns on, not every time a status poll says it is still on. Duplicates are tolerated, but they add noise.
4. **Timestamp at the moment it happens**, in UTC. The clients do this for you.
5. **Be consistent across your fleet.** One name for one kind of thing in every room. Consistency matters more than which name you pick.
6. **Never log personal data.** No user names, ID numbers, meeting titles or free text typed by users. Metric and action text is visible to anyone with access to the data.

## Client names

`clientname` identifies the room or system that sent the event. Use one client name per room or independently operated system, and keep it stable over the life of the room.

- Recommended form: `<Building>-<Room>`, such as `SCI-101` or `HOLT-171`. The Visualizer groups rooms by building using the letters before the first `-`, `_` or space. If your names use another scheme, change **Building pattern** in the Visualizer settings.
- Use the same capitalization everywhere. `Sci-101` and `SCI-101` are stored as two different clients.
- Divisible rooms: use one client name per independently operated part (`BALL-A`, `BALL-B`).
- `AVSM-System` is reserved. The self-hosted server uses it to record its own update and maintenance events.

## Event conventions

The **Recommended** column is what new programs should send. The **Also recognized** column lists other forms the Visualizer accepts by default, so existing programs keep working. Matching ignores capitalization and surrounding spaces. `<...>` is a placeholder.

| What happened | Recommended | Also recognized |
| :--- | :--- | :--- |
| Room system powered on | `start("System Power")` | `System`, `System Power - <reason>`, `System - <reason>` with `Started` |
| Room system powered off | `stop("System Power")` | Same names with `Stopped` |
| Source routed to the main display(s) | `start("Source - <name>")` | `Source: <name>`, `Source Select: <name>`, `Input - <name>`, `Input: <name>`, with `Started` or `Trace`; a bare name from the Visualizer's **Source names** list, such as `start("hdmi")` |
| Device powered on / off | `start("<Device> <n>")` / `stop("<Device> <n>")`, such as `Projector 1` | `<Device>_<n>`, `<Device> <n> Power`, `<Device> Power` |
| Device communication up / down | `connected("<Device> <n>")` / `disconnected("<Device> <n>")` | Any metric, with `Connected` / `Disconnected` |
| Control program started (processor boot or program load) | `start("Program Start")` | `Initialize`, `Program Started`, `Processor Boot`, with `Started` or `Trace` |
| Room finished its power-on sequence (optional) | `trace("System Startup Complete")` | `System Startup Sequence Complete` |
| Room finished its power-off sequence (optional) | `trace("System Shutdown Complete")` | `System Shutdown Sequence Complete` |
| Touch-panel or keypad control used | `trace("<Control> Pressed")` | `<Control> Released`, `Tapped`, `Held`, `Repeated` |
| Audio muted / unmuted | `start("<Channel> Mute")` / `stop("<Channel> Mute")` | `<Channel> Muted`; `custom("Muted", "<Channel>")` / `custom("Unmuted", "<Channel>")` |
| Volume set | `custom("Level <0-100>", "<Channel> Volume")` | Action `Level <number>` followed by any text, such as `Level 31 (Device -18.8)` |
| Wireless presentation share started | `custom("Share", "<System or station name>")` | |
| Processor is alive | `heartbeat()` on a timer, for example every 5 minutes | |
| Anything else | `trace("<what happened>")` or `custom("<action>", "<metric>")` | |

### System power

- `Started` means the room is on and usable; `Stopped` means it is off. Send them when the power-on or power-off sequence begins, which is when the room's state changed from the user's point of view.
- **Optional reason.** Add a dash and a reason (`System Power - <reason>`) to say what triggered the change: `System Power - User`, `System Power - Schedule`, `System Power - Inactivity`, `System Power - Remote`, `System Power - Restore` (the program turned the room back on by itself after a restart or power loss). The Visualizer groups these reasons (Restore only applies to power-on), and synonyms such as `Scheduled`, `Idle`, `Timeout` and `Recovery`, and shows any other reason exactly as logged.
- `System Power` is checked before device rules, so do not name a device `System`.
- A `Started` while the room is already on (for example a "reset" that keeps the system on) does not start a second session and is not counted as a power-on when looking for repeated power cycling.
- If the processor restarts, the next `Program Start` closes any session that was still open.

### Sources

- Log the source when it is **routed to the room's main output**, not when a button is pressed on a preview page.
- Use the name a person in the room would recognize: `HDMI 1`, `Lectern PC`, `Document Camera`, `Wireless`. Use the same name for the same kind of source in every room so campus-wide comparisons work.
- A source counts as on screen from its `Started` until the next source is selected or the system powers off. You do not need to `stop()` a source; if you do, the Visualizer ends its on-screen time there.
- Multi-display rooms: log the main or primary display's source. If you need per-display data, put the display in the metric (`Source - Display 2 - HDMI 1`) and add a matching rule in Settings; the default rules treat the whole text after the `Source -` prefix as the source name.
- If the program selects a default source automatically at power-on, the Visualizer does not count it as a person's choice when the selection arrives within 15 seconds of power-on, or before the optional `System Startup Complete` trace if that trace arrives within 2 minutes of power-on. It still counts toward time on screen.

### Devices

- Name devices by type plus a number within the room: `Projector 1`, `Display 2`, `Camera 1`. The Visualizer takes the text before the number as the device type and uses it for grouping and for the rated-life defaults in forecasting.
- Prefer specific types (`Display` rather than `Projector` for a flat panel, `Laser Projector` if you track lamp and laser models separately). If your program cannot change names, set **Device type overrides** in the Visualizer settings.
- `Started` / `Stopped` should reflect the device's actual power state from feedback when you have it, not just the command that was sent.
- Device sessions are independent of system power, so a device that stays on after the system is off shows up as a long device session.

### Controls

- `trace("<Control> Pressed")` for each press. Use the control's on-panel label or a stable identifier from your program; the Visualizer shows it verbatim and does not try to interpret it.
- Only `Pressed` counts as a press. `Released`, `Tapped`, `Held` and `Repeated` are kept for the event timeline.
- Repeated presses of one control in a short time are reported as a pattern for you to look at. Controls whose names suggest they are meant to be pressed repeatedly (`Up`, `Down`, `Left`, `Right`, `In`, `Out`, `Volume`, `Vol`, `Zoom`, `Pan`, `Tilt`, `Focus`, sliders and faders) need more presses before they are reported.
- **Navigation controls** (page flips, menus, tabs, back and home) are recognized when the control name contains `Nav`, `Navigation`, `Page`, `Menu`, `Tab`, `Back` or `Home` as a separate word or a part separated by `_` or `-`. Change **Navigation pattern** in the Visualizer settings to match your naming.
- **Help controls.** Any event whose metric contains the word `help`, whatever the action, is counted and listed as a help-labelled event. The Visualizer does not assume what the control does in your program (open a page, call someone, send an alert), so it reports when and how often it was used and nothing more. Every matching event counts, so if your program logs a help press *and* a help page opening, each use counts twice; log one event per use if you want the counts to mean uses. Avoid `help` in metrics that are not help controls (for example a device named `Help Phone`), or change **Help pattern** in the settings.

### Heartbeats

Call `heartbeat()` on a fixed timer. The Visualizer uses heartbeats to show when each room's processor was reachable and to find gaps. A room that never sends heartbeats shows "No heartbeats" rather than "offline". The self-hosted server deletes old heartbeats after `HEARTBEAT_RETENTION_DAYS` (30 by default).

## What the Visualizer derives from each event

| Visualizer view | Built from |
| :--- | :--- |
| System usage: on-hours, sessions, on/off times by hour and weekday, power-off reasons | System power |
| Sources: share of selections and of on-screen time, campus-wide and per room | Sources, bounded by system power |
| Devices: on-hours per device, rated-life forecasts | Device power |
| Connectivity: share of time with heartbeats, heartbeat gaps, connect/disconnect history | Heartbeats, device communication |
| Patterns worth reviewing (Issues view) | All of the above: repeated power cycling, repeated presses of one control, rapid navigation presses, rapid source changes, devices that change communication state repeatedly, long device sessions, heartbeat gaps, help-labelled events |
| Room timeline | Every event except heartbeats, including ones that match no rule, each labelled with the category it was recognized as |

Events that match no rule are still loaded. The Visualizer lists the most common unmatched metric and action pairs in the **Data quality** card on the Overview page, so you can see what it is not using and add a rule if you want it to.

## Choosing names

- Keep names short and readable; the limit is 128 characters.
- Do not put changing values in the metric (`Projector 1 Lamp 1234 h`). Put the value in the action with `custom()`, the way volume levels are logged, or leave it out.
- Avoid characters that are awkward in exports: commas are fine (exports quote them), but control characters and line breaks are not.
- Changing a name splits the history into two series. If you must rename, do it in all rooms at once and note the date.

## Matching an existing program

If a program already logs events under other names, you do not need to change it. In the Visualizer, open **Settings > Event recognition** and adjust:

| Setting | Matches |
| :--- | :--- |
| System power names | Metrics treated as system power |
| Source prefixes and Source names | Metrics treated as source selections |
| Device pattern | Metrics treated as device power, and how the device type is read |
| Program start names | Metrics that mark a processor or program start |
| Power reason synonyms | Which logged reasons are grouped as User, Schedule, Inactivity, Remote or Restore |
| Startup and shutdown complete names | The optional sequence-complete traces |
| Navigation pattern | Controls counted as navigation |
| Repeatable control pattern | Controls that need more presses before repeated presses are reported |
| Help pattern | Metrics counted as help-labelled events |
| Building pattern | How a client name is split into building and room |
| Device type overrides | Per-room fixes for devices whose name does not say what they are |

The defaults already recognize the naming used by the Extron ControlScript template this project started with, for example `System - User`, `Initialize`, `Projector_1`, bare source names such as `hdmi` and `doc_cam`, and `Btn_Nav_Display Pressed`. That template is one implementation among many and is not required.

## Checking your implementation

1. Point a test room at your server and use it normally for a few minutes: power on, change sources, press a few buttons, power off.
2. Export the room's events (see the Visualizer's **Data source** page for the export command) or load them through the Analytics API.
3. In the Visualizer, check that the **Room timeline** shows each event under the expected category, and that **Data quality** lists no unmatched events you meant to be recognized.
4. Check that each `Started` has a matching `Stopped` in normal use, and that heartbeats arrive at the interval you set.

## Example: one room, one session

What a minimal, well-formed session from room `SCI-101` looks like:

| timestamp (UTC) | metric | action |
| :--- | :--- | :--- |
| 08:00:00 | Program Start | Started |
| 08:05:00 | Ok | Heartbeat |
| 13:58:02 | System Power - User | Started |
| 13:58:03 | Source - Lectern PC | Started |
| 13:58:04 | Projector 1 | Started |
| 13:58:40 | System Startup Complete | Trace |
| 14:03:11 | Source - HDMI 1 | Started |
| 14:20:45 | Program Audio Mute | Started |
| 14:21:30 | Program Audio Mute | Stopped |
| 14:30:12 | Help Pressed | Trace |
| 14:55:00 | Program Audio Volume | Level 40 |
| 15:15:09 | System Power - User | Stopped |
| 15:15:10 | Projector 1 | Stopped |
| 15:15:50 | System Shutdown Complete | Trace |

From this the Visualizer reports:

- One system session of 1 h 17 m.
- An automatic default source (`Lectern PC`), followed by one selection (`HDMI 1`) on screen for 1 h 12 m.
- 1 h 17 m of projector use.
- One mute of 45 s.
- One help-labelled event at 14:30.
