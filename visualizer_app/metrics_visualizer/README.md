# AV Metrics Visualizer

An accessible desktop and web app that turns AV System Metrics data into
answers for higher-education AV professionals, managers and administrators.
It shows how rooms and devices are really used, so budget and system-design
decisions can be based on evidence instead of anecdotes.

The Visualizer is **optional** and **read-only**. It never writes to the
metrics database and it is completely separate from the services that collect
the data. You can run it from a CSV export without changing the server at
all.

- [What it answers](#what-it-answers)
- [Get the app](#get-the-app)
- [Quick start](#quick-start)
- [Hosting the web build](#hosting-the-web-build)
- [Getting data in](#getting-data-in)
- [Screens and features](#screens-and-features)
- [How the numbers are calculated](#how-the-numbers-are-calculated)
- [Accessibility](#accessibility)
- [Security and privacy](#security-and-privacy)
- [Development and testing](#development-and-testing)

## What it answers

| Question | Where to look |
| --- | --- |
| Which video inputs do people actually use, campus-wide, per building and per room? Which inputs could be removed at the next refresh? | Video inputs |
| How many hours are projectors, displays and cameras on? Which devices are left on overnight? | Devices |
| When are rooms turned on and off? How long are sessions? How often does auto-off or a schedule turn rooms off instead of people? How well used is each room in teaching hours? | System usage |
| Are room processors online? When were rooms offline? Which devices keep dropping their connection? | Connectivity |
| Where are people struggling? Rapid power cycling, repeated button presses, navigation confusion, searching for an input, unstable connections, devices left on, offline rooms and help requests | Issues |
| When will a projector reach its rated lamp or light-source life at current usage? Which inputs are growing or declining? | Forecast |
| How is one specific room used? | Rooms |

## Get the app

You do not need the Flutter SDK to use the Visualizer. Ready-to-run builds
are attached to the repository's GitHub Releases (tags named
`visualizer-v<version>`), together with a `SHA256SUMS.txt` file to check the
downloads against.

- **Windows:** download `metrics-visualizer-windows-x64.zip`, unzip it to a
  folder (for example in your user folder) and run `metrics_visualizer.exe`.
  Keep the files in the folder together. The build is not code-signed, so
  Windows SmartScreen may ask you to confirm the first time. If Windows
  reports that `VCRUNTIME140.dll` or `MSVCP140.dll` is missing, install the
  Microsoft Visual C++ Redistributable (x64).
- **Web:** download `metrics-visualizer-web.zip`, unzip it onto an internal
  HTTPS web server (IIS, nginx, Apache) and give people the site address.
  See [Hosting the web build](#hosting-the-web-build) for the CORS setting
  and a Content Security Policy.
- **macOS and Linux:** build from source (below).

If no release has been published yet, an administrator can build the web
version once (below) and host it for everyone.

## Quick start

Prerequisites: the Flutter SDK, stable channel (the project is built and
tested with Flutter 3.47 / Dart 3.13). Run `flutter doctor` to check the
desktop toolchain for your platform:

- **Windows:** Visual Studio 2022 with the "Desktop development with C++"
  workload.
- **macOS:** Xcode and CocoaPods.
- **Linux:** the build tools, GTK and libsecret development packages (the
  token store needs libsecret):

  ```bash
  # Debian / Ubuntu
  sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
  # Fedora / RHEL
  sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel libsecret-devel
  ```

  **Remember token** also needs a Secret Service provider (GNOME Keyring or
  KWallet) running in the desktop session. Without one the app still works,
  but the token cannot be remembered.

```bash
cd visualizer_app/metrics_visualizer
flutter pub get

# Run
flutter run -d windows      # or: -d macos, -d linux
flutter run -d chrome       # web, in a local browser

# Build
flutter build windows       # build/windows/x64/runner/Release/
flutter build macos
flutter build linux
flutter build web --release --no-web-resources-cdn   # build/web/ (static files)
```

Platform status: the Windows and web builds are built and tested. The Linux
build follows the same code. The macOS build has the sandbox entitlements it
needs (outbound network for the API, read access to files you choose for CSV
import) and keeps a remembered token in the login keychain, but it has not
yet been verified on a Mac; please report any problem as an issue.

## Hosting the web build

The web build is static files. You can host it on any HTTPS web server, for
example an internal IIS or nginx site. Nothing in the build contains
credentials.

- **Build it with `--no-web-resources-cdn`** (as shown above, and as CI and
  the release builds do). The app then makes no requests to any site other
  than the one that hosts it and the Analytics API you connect to: CanvasKit
  (the rendering engine) is served from the site's `canvaskit/` folder and
  the Roboto font is bundled, instead of both being downloaded from Google's
  `gstatic.com` servers. It also works on isolated networks.
- **Fallback fonts.** Characters that Roboto does not contain (for example
  Chinese, Japanese or Korean text, or emoji, in room or device names) would
  normally be drawn with fonts downloaded from `fonts.gstatic.com`. This build
  looks for them in the site's `fonts/fallback/` folder instead (set in
  `web/flutter_bootstrap.js`). That folder is empty, so such characters show
  as boxes. Every character the app itself uses is in Roboto. If your data
  needs other scripts, either copy the Noto fonts into `fonts/fallback/` with
  the same folder layout as `https://fonts.gstatic.com/s/`, or change
  `fontFallbackBaseUrl` in `web/flutter_bootstrap.js` to
  `https://fonts.gstatic.com/s/` before building. The second option sends
  the visitor's IP address to Google whenever such a character appears, and
  the Content Security Policy below must then allow that origin.
- **CORS.** If the web app calls the Analytics API, add the site's exact
  origin (for example `https://avmetrics.example.edu`) to
  `ANALYTICS_CORS_ORIGINS` on the server. See the
  [Analytics API guide](../../Self_Hosted/analytics_api/README.md).
- **Serve it from its own origin** (its own host name), not a path on a site
  that runs other web apps, so other scripts cannot read a token remembered
  for the tab.
- **Content Security Policy.** This policy was tested with a release build
  in Chrome: the app loads and renders with no violations reported, and every
  request goes to the hosting site. Replace `https://avsm.example.edu` with
  your Analytics API origin:

  ```text
  Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self' https://avsm.example.edu; worker-src 'self' blob:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'none'
  ```

  `'wasm-unsafe-eval'` lets the browser compile CanvasKit's WebAssembly; it
  does not allow JavaScript `eval`. `'unsafe-inline'` for styles is needed
  because Flutter adds style elements at run time. Also serve `.wasm` files
  as `application/wasm` (on IIS, add a MIME map for `.wasm`).

On first launch the app opens the **Data source** page. Choose one of the
three data sources. After a dataset loads, the app opens the **Overview**.

## Getting data in

All three sources produce the same dataset, so every screen works the same
way whichever one you use. The app never connects to PostgreSQL directly.

### 1. CSV export (no server changes)

On the AV System Metrics server, in the stack directory (where
`docker-compose.yml` is), export the last 90 days:

```bash
docker compose exec -T postgres psql -U metrics_user -d metrics -c "\copy (SELECT clientname, event_timestamp, metric, action, event_id, received_at FROM metric_events WHERE event_timestamp >= now() - interval '90 days' ORDER BY event_timestamp) TO STDOUT WITH (FORMAT csv, HEADER)" > avsm_export.csv
```

Copy `avsm_export.csv` to your computer (for example with `scp` or WinSCP),
then choose **Import a CSV export** (or press Ctrl+O). The Data source page
shows this command with a copy button.

Notes:

- **Change the period** by editing `interval '90 days'`. For a whole term,
  use `interval '120 days'`. For everything, remove the `WHERE` clause.
- **Heartbeats.** The export includes the heartbeat rows (`Ok` /
  `Heartbeat`). They are most of the table and the app needs them for the
  online percentages and offline periods on the Connectivity page. The
  server deletes heartbeats older than `HEARTBEAT_RETENTION_DAYS` (30 days by
  default), so in a 90-day export only the most recent 30 days have uptime
  data. The Connectivity page explains this next to the figures. To keep the
  file small you can leave heartbeats out
  (`AND action <> 'Heartbeat'`), but then uptime figures are not available.
- The export leaves out `source_ip` and `sort_key`, which the app does not
  need.
- The importer also accepts `;`, tab or `|` delimiters, psql's aligned text
  output (pasted from a terminal), UTF-8 or UTF-16 files (for example from
  Windows PowerShell redirection) and any line endings. Rows it cannot read
  are skipped and counted.
- Large files are parsed in a background isolate so the window stays
  responsive. The test suite imports 200,000 rows and analyses 1,000,000
  events.

### 2. Analytics API (live, read-only)

The optional Analytics API is a small, separately deployed Go service that
gives authenticated, read-only access to the data over HTTPS. It is turned
off by default. A server administrator enables it in the server's `.env`.
See the [Analytics API guide](../../Self_Hosted/analytics_api/README.md) for
setup, the security model and the endpoint reference. The same API can be
used to build your own reports and apps.

In the app, open **Data source > Connect to the Analytics API**, enter the
address your administrator gave you (normally the HTTPS reverse proxy in
front of the API, for example `https://avsm.example.edu` or
`https://avsm.example.edu/analytics`) and your token, choose **Test connection**, then choose the
period and rooms to download. The app pages through `/api/v1/events` and
downloads hourly heartbeat counts in chunks of 92 days or less. You can
cancel the download at any time.

### 3. Demo data

**Explore demo data** loads a synthetic campus of 24 rooms in 6 buildings
over 10 weeks. It has realistic class schedules, input habits, a slowly
growing usage trend, an offline room and planted issues (rapid power
cycling, button mashing, navigation confusion, input hunting, connection
flapping and a device left on overnight). Use it for training, evaluation
and accessibility testing without real data.

## Screens and features

Every analysis page shares the **filter bar** at the top: a date range
(presets such as last 7, 30 or 90 days, a 16-week semester, all data, or a
custom range), buildings and rooms. In short windows (such as 400% browser
zoom) or with large text in a narrow window, the filters collapse into one
**Filters** button at the top of the page that opens them in a dialog. Every chart card has **View as table**
and **Copy as CSV** buttons and a one-sentence summary of the main finding.

| Screen | Features |
| --- | --- |
| **Overview** | Headline figures (rooms, buildings, events, system hours, average daily hours per room, most-used input, issue counts, busiest time), weekly system hours, written insights and the top issues. Warnings about the data (for example how spreadsheet dates were read, or a settings pattern that could not be used) are shown near the top, and an **About this data** card lists skipped rows, excluded clients, unrecognised events and sessions that had to be closed by a rule. |
| **Rooms** | Searchable room list with usage, utilization, uptime and issue counts. Each room has its own input share, device hours, weekday-by-hour use, recent issues and an event timeline. Other screens link here with "Open room". |
| **Video inputs** | Input share by number of selections and by time on screen, campus-wide, per building and per room. Removal candidates (inputs that are rarely or never used) and a room-by-input matrix. The default source the room program selects by itself at power-on is not counted as a selection, but its time on screen is; a **How inputs are counted** card explains this and says how many startup selections were left out. |
| **Devices** | On-hours per device, per room and per device type. Daily and weekly trends, devices left on, and per-device detail. When the data has `Projector_N` devices, a note explains that the ControlScript template logs every display, flat panels included, as `Projector_N`, with a link to the device type overrides in Settings. |
| **System usage** | Power-on and power-off time of day, a weekday-by-hour heatmap of rooms in use, session lengths, off reasons (user, inactivity, schedule, remote) and utilization per room in teaching hours. |
| **Connectivity** | Connected and Disconnected events per day (stacked bars), a sortable table by room and device, and the raw event log. Processor online percentage per room, sortable, with the heartbeat coverage period and the server's retention period shown. Each room is measured from its first heartbeat or event; a room that sent no heartbeats shows "No heartbeats" (never 0%) in the chart, table and CSV. A last-seen time that comes from a heartbeat reads "During the hour starting ...", because heartbeats are counted per hour. Offline periods with links to each room, and a callout for devices with unstable (flapping) connections. If there are no connection events or no heartbeats, the page explains why and what to enable. |
| **Issues** | Counts by type or by likely cause (equipment, training or usability, network, configuration). A filterable list by severity, type, cause, building, room, time and free text. Each issue opens to show a plain-language explanation, a suggested action, the details, the evidence events and a link to the room. Severity is shown with an icon and a word, never by colour alone. The filtered issues can be copied as CSV for a ticket system or spreadsheet. |
| **Forecast** | A replacement-planning table for each device: observed hours, weekly run-rate, trend, share of rated life used, projected date to reach rated life, likely range and a confidence rating. A chart of cumulative hours with the projection and likely range for 1, 3 or 5 years. Weekly selections of the most-used inputs, and written growing or declining statements for every input. An assumptions panel, with a link to the rated-life values in Settings. The same `Projector_N` note as on Devices, because a flat panel logged as a projector would otherwise be forecast with a projector's rated life. If there is not enough data, the page says what is needed. |
| **Data source** | CSV import with the export command, the API connection form, demo data and a summary of what is loaded. |
| **Settings** | Theme (system, light or dark), high contrast, colour-blind-safe chart palettes, chart patterns, text size (100% to 200%), reduce motion, local time or UTC, excluded clients, input names and patterns, issue thresholds, business hours, rated life per device type, **device types for particular devices** and the keyboard shortcuts. Device type overrides set the real type of one device (for example `BSS_112/Projector_1` is a `DISPLAY`; room and device names are not case-sensitive), so a flat panel logged as `Projector_1` is grouped and forecast as a display. The navigation button pattern deliberately leaves out `Btn_Start_Page` (the power-on button) and the camera backlight buttons. If "Device left on after" is at or above "Longest believable session", a note explains that devices whose off event was lost will not be flagged. Changes apply immediately and are saved on this computer. |
| **About** | Version, accessibility statement and data and privacy notes. |

Keyboard shortcuts (Cmd instead of Ctrl on macOS): Ctrl+O opens a CSV file,
Ctrl+1 to Ctrl+8 open the analysis pages, Ctrl+D opens Data source, Ctrl+,
opens Settings and F6 skips to the main content.

## How the numbers are calculated

The analytics engine (`lib/analytics/`) is plain Dart. It runs in a
background isolate, so the window stays responsive with millions of rows.
In short:

- **Sessions** are rebuilt from start and stop events. A room's system
  session runs from power-on to the first off event (user, inactivity
  auto-off, schedule, remote or processor restart). A session with no off
  event is capped at 16 hours (the **Longest believable session** setting),
  so one lost event cannot inflate the totals. A device whose real off event
  arrives later, up to 7 days after it turned on, still ends its session
  there. An input stays on screen until another input is selected or the
  system powers off. The default source selected automatically at power-on
  is not counted as a selection, but its time on screen is.
- **Utilization** is system-on time inside business hours (weekdays
  07:00-22:00 by default) divided by the business hours in the range.
- **Online %** counts the hours in which a room sent a heartbeat or any
  event, but only inside heartbeat coverage, because the server deletes old
  heartbeats. Each room is measured from its first heartbeat or event, and a
  room that sent no heartbeats has no percentage ("No heartbeats").
- **Issues** are bursts of events within a time window (for example 3
  power-ons in 10 minutes). The thresholds can be changed in Settings. Each
  issue is a lead to check, not a verdict.
- **Forecasts** count only hours observed by the metrics system. A device's
  type, and so its rated life, comes from its name unless a device type
  override in Settings says otherwise. They fit a
  least-squares line to complete weeks and need at least 3 of them. A full
  term or more gives far better results. The likely range uses the trend
  slope plus or minus one standard error. Confidence is high with at least
  12 complete weeks and a one-year likely range within ±15%. It is medium
  with at least 6 weeks and a range within ±35%, and low otherwise.

The complete methodology, with every rule and threshold, is in
[lib/analytics/README.md](lib/analytics/README.md). Use it when you need to
explain a figure in a budget request.

## Accessibility

The app is designed to meet WCAG 2.2 Level AA, Section 508 and EN 301 549,
and to support a VPAT / Accessibility Conformance Report and a higher-ed
IT procurement review (ITPR). In summary:

- Every chart has a written summary for screen readers, a **View as table**
  alternative with the same numbers and **Copy as CSV**.
- Information is never shown by colour alone. Chart series have patterns and
  dash styles that are named in the legend, values are written next to bars,
  and severities have icons and words.
- There are colour-blind-safe palettes (Okabe-Ito, deuteranopia, protanopia,
  tritanopia and monochrome) and light, dark and high-contrast themes. All
  text meets 4.5:1 contrast, and chart marks and focus indicators meet 3:1.
- Headings have levels (page, section, card), so screen reader users can
  move through each page's outline.
- The app can be used entirely by keyboard. Focus is always visible: controls
  without their own focus outline get an app-wide two-tone focus ring. There
  is a skip link, focus follows you when a link opens another page, and
  shortcuts use Ctrl or Cmd. Every target is at least 48 x 48 px.
- Text can be enlarged to 200% in the app (and further with the operating
  system setting) without losing content. Layouts reflow on narrow windows,
  down to 320 px wide and 256 px high.
- Reduce motion turns off every app animation. The app also follows the
  operating system's setting.
- Loading, results counts, errors (including settings field errors), table
  re-sorts and copy confirmations are announced to screen readers.
- On the web each page has its own browser tab title ("Forecast · AV Metrics
  Visualizer"). Desktop windows are titled "AV Metrics Visualizer".

The full conformance notes, known limitations and the manual test procedure
are in [ACCESSIBILITY.md](ACCESSIBILITY.md).

## Security and privacy

- **No direct database access.** The app reads either a file you choose or
  the read-only Analytics API. The API uses its own token and its own
  read-only database role, which cannot see client IP addresses.
- **API tokens** are kept in memory only, unless you choose to remember
  them:
  - **Desktop:** **Remember token on this computer** stores the token in the
    operating system's credential store (Windows Credential Manager, the
    macOS login keychain, or the Secret Service through libsecret on Linux).
  - **Web:** **Remember token in this browser tab** keeps the token in that
    tab's `sessionStorage` for the tab session only. It is gone when the tab
    is closed, and you paste it again next time. While the tab is open, any
    script running on the same site could read it, so serve the web build
    from its own origin with a restrictive Content Security Policy (see
    [Hosting the web build](#hosting-the-web-build)) and do not use this
    option on shared computers. Copies that older versions of the app left
    in the browser's `localStorage` are deleted.

  Connecting with the option turned off, unticking it, or choosing **Forget
  saved API token** in Settings deletes any stored token.
- **A remembered token stays with its server.** It is filled in only while
  the API address has the same scheme, host and port it was saved with. If
  you change the address to another server (a typo, a test server or a
  look-alike link), the token field is cleared and the app asks for that
  server's token, so the saved token is never sent there.
- **Large downloads ask first.** If a download would contain more than
  2,000,000 events, the app says so and suggests a shorter period or fewer
  rooms before downloading anything.
- **Incomplete data is never accepted.** If the server truncates an hourly
  heartbeat response, the app splits the request into smaller ones, or
  reports an error if it still cannot get complete data.
- **The token never appears in a URL.** It is sent only in the
  `Authorization` header. Redirects are not followed, so it cannot be
  forwarded to another host.
- **Use HTTPS.** The app warns when the API address uses plain `http` to any
  host other than this computer. With the bundled Docker Compose files, put
  the API behind a TLS reverse proxy (see the reverse proxy examples in the
  [Analytics API guide](../../Self_Hosted/analytics_api/README.md)). The
  API's built-in TLS option applies only to installs outside the bundled
  Compose files. Use `http://<server>:8081` only on a trusted, isolated
  management network.
- **CSV exports from the app are spreadsheet-safe.** Cells that would start
  with `=`, `+`, `-` or `@` are prefixed with an apostrophe, so room or
  device names cannot run as formulas in Excel.
- **Nothing is uploaded.** All analysis happens on your computer. Settings
  are saved locally. Loaded data stays in memory and is gone when you close
  the app or choose Clear data.
- **No third-party requests.** The app has no analytics or telemetry. The
  desktop apps connect only to the Analytics API you enter. A web build made
  with `--no-web-resources-cdn` (the documented build, CI and releases)
  loads everything from its own site; see
  [Hosting the web build](#hosting-the-web-build) for the one optional
  exception (fallback fonts).

## Development and testing

```bash
cd visualizer_app/metrics_visualizer
flutter analyze                       # must report "No issues found!"
flutter test                          # all unit and widget tests
flutter test test/analytics           # analytics engine (pure Dart)
flutter test test/data                # CSV import, API client, demo data
flutter test test/ui                  # screens, accessibility guidelines
flutter test test/ui/screens_b/issues_screen_test.dart   # one file
flutter test --plain-name "copies the filtered issues as CSV"   # one test
```

The widget tests run every main screen in light, dark and high-contrast
themes against Flutter's accessibility guidelines (`textContrastGuideline`,
`labeledTapTargetGuideline`, `androidTapTargetGuideline`). They also render
each screen at 100% and 200% text size in narrow (400 px) and wide windows.
These automated checks do not replace manual testing with assistive
technology. See [ACCESSIBILITY.md](ACCESSIBILITY.md#manual-test-procedure).

Continuous integration (`.github/workflows/visualizer-app.yml`) runs
`flutter analyze`, `flutter test` and a web release build on every change
under `visualizer_app/`. Pushing a tag named `visualizer-v<version>` runs
`.github/workflows/visualizer-app-release.yml`, which builds the Windows and
web releases and attaches them, with checksums, to a GitHub Release.

Project layout:

| Path | Contents |
| --- | --- |
| `lib/analytics/` | Pure-Dart analytics engine and its [README](lib/analytics/README.md). |
| `lib/data/` | Data model, CSV importer, Analytics API client, demo data, token storage. |
| `lib/state/` | Settings, loaded data and filters, navigation (`provider` ChangeNotifiers). |
| `lib/ui/theme/` | Themes, chart palettes and patterns, contrast helpers, motion timing. |
| `lib/ui/widgets/` | Shared accessible widgets: chart card with table view, KPI tile, headings, focus ring overlay, dropdown menu, legend, filter bar, status widgets. |
| `lib/ui/screens/` | One file per page. `parts/` holds helpers private to some screens. |
| `test/` | Unit and widget tests, plus fixtures from the production data format. |
