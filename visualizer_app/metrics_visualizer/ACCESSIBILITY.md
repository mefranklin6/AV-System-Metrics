# Accessibility: AV Metrics Visualizer

> **Status: draft basis for a VPAT® / Accessibility Conformance Report
> (ACR).** This document records how the app is designed and tested to meet
> WCAG 2.2 Level A and AA, Revised Section 508 and EN 301 549. The
> conformance levels below come from code review and automated widget
> tests. **They are not a formal ACR.** Before you publish an ACR or submit
> this app for a higher-education IT procurement review (ITPR), validate
> every criterion with the [manual test procedure](#manual-test-procedure)
> on the exact build and platforms you will deploy, and record the results.

- [Accessibility statement](#accessibility-statement)
- [Scope and evaluation basis](#scope-and-evaluation-basis)
- [Accessibility features](#accessibility-features)
- [WCAG 2.2 conformance (Level A and AA)](#wcag-22-conformance-level-a-and-aa)
- [Section 508 and EN 301 549 notes](#section-508-and-en-301-549-notes)
- [Known limitations](#known-limitations)
- [Manual test procedure](#manual-test-procedure)
- [Reporting accessibility problems](#reporting-accessibility-problems)

## Accessibility statement

AV System Metrics is built for the people who plan and support teaching
spaces, including colleagues who use screen readers, keyboard-only
navigation, magnification, high-contrast or colour-blind-friendly settings,
or reduced motion. Our goal is for the Metrics Visualizer to conform to
**WCAG 2.2 Level AA** on every supported platform (Windows, macOS and Linux
desktop, and current web browsers). Accessibility problems are treated as
bugs with the same priority as functional defects.

Every piece of information in the app is available as text. Each chart has a
written summary of its main finding, a **View as table** alternative with the
same numbers and a **Copy as CSV** export.

## Scope and evaluation basis

| Item | Value |
| --- | --- |
| Product | AV Metrics Visualizer (`visualizer_app/metrics_visualizer`), version 1.0.0 |
| Platforms | The Windows desktop build is the platform that is built, tested and released. The macOS and Linux desktop builds and the web build (Chromium, Firefox, Safari) compile from the same code but are not built or verified by CI. The macOS build has not yet been run on a Mac: its sandbox entitlements (network client, user-selected file read) and keychain settings are in place and checked by `test/platform_config_test.dart`, but no part of this report has been verified on macOS. |
| Standards | WCAG 2.2 Level A and AA; Revised Section 508 (36 CFR 1194, chapters 3, 5 and 6); EN 301 549 V3.2.1 (chapters 9, 11 and 12) |
| Evaluation methods used so far | Code review of every screen and shared widget. The Settings > Event recognition section has its own guideline run in light and dark themes, at 200% text and in a 320 px wide window (`test/ui/event_recognition_settings_test.dart`). Automated Flutter widget tests on every main screen: `textContrastGuideline`, `labeledTapTargetGuideline` and `androidTapTargetGuideline` in light, dark and high-contrast themes; rendering without overflow at 100% and 200% text size in 400 px and 1,280 px wide windows, and at 320 x 256 px (400% zoom) and 320 x 640 px with 200% text; theme contrast tests for every palette and for the focus indicators; heading levels and names checked by walking the semantics tree; keyboard focus order and focus restoration; screen reader announcements captured in tests. `test/ui/a11y_regressions_test.dart` holds the regression tests for the items in this report. |
| Platforms the automated tests emulate | Flutter widget tests run headless. Most run with Flutter's default test platform (Android semantics). The guideline checks for Rooms, Sources, Devices and Settings, and the dropdown-name check, also run with Windows, macOS and Linux semantics (`TargetPlatformVariant.desktop()`). The field-error announcement test runs with `supportsAnnounce` on, as on desktop and the web. No automated test drives a real browser or a platform accessibility API; the manual procedure covers that. |
| Not yet done | Manual testing with assistive technology on each platform. See the [manual test procedure](#manual-test-procedure). |

The **Evidence** column in the tables below tells you what each entry rests
on:

- **Auto**: checked by automated tests in `test/`.
- **Code**: established by code review. The behaviour is implemented, but no
  test asserts it directly.
- **Manual**: must be confirmed by manual testing before the ACR is published.

## Accessibility features

- **Screen readers.** Headings are marked as headings, with levels: the
  page title is level 1, page sections level 2, cards level 3 and
  sub-headings inside a card level 4. Each heading is read as exactly its
  visible text. Every control has a name, role and state. Charts are announced as images with a summary
  sentence. Data tables use Flutter's table semantics. Decorative icons are
  hidden from assistive technology. On the web the accessibility tree is
  always turned on, so screen reader users do not have to find Flutter's
  hidden "Enable accessibility" button.
- **Status messages.** Loading progress, load results, analysis updates,
  errors, the number of issues after filtering and copy confirmations are
  announced politely without moving focus. Errors are announced assertively.
- **Keyboard.** Everything works by keyboard. Tab order follows the reading
  order. A **Skip to main content** link is the first tab stop, and F6 jumps
  to the content. When a link inside a page opens another page, or a data
  load finishes, focus moves to the start of the new page's content and the
  page name is announced, so keyboard users do not start again from the top. Shortcuts use Ctrl or Cmd (Ctrl+O, Ctrl+1 to Ctrl+8, Ctrl+D
  and Ctrl+,). There are no single-key shortcuts.
- **Focus.** Buttons, chips, menu items, inputs, switches, checkboxes and
  segmented buttons show a 3 px focus outline with at least 3:1 contrast.
  Every other focusable control (list rows, switch and checkbox rows, KPI
  tiles, sortable table headers, navigation destinations, dropdown buttons)
  gets an app-wide two-tone focus ring: a 3 px ring with a 1 px halo in the
  contrasting surface colour on each side, so it reaches 3:1 against any
  neighbouring colour. Issue cards draw a 3 px ring while focus is inside
  them.
- **Colour and contrast.** There are light, dark and high-contrast themes and
  the system theme is followed. Text meets at least 4.5:1, or 7:1 in high
  contrast. Chart colours have at least 3:1 contrast with the chart
  background (4.5:1 in high contrast). There are five chart palettes:
  Okabe-Ito, deuteranopia, protanopia, tritanopia and monochrome.
- **Not by colour alone.** Chart series have fill patterns, which are on by
  default and always on in monochrome. Line series have dash styles that are
  named in the legend, and bar values are written next to the bars.
  Severities are shown with different icon shapes plus words (Critical,
  Warning, Info), and markers are explained in text.
- **Text size.** The in-app text size runs from 100% to 200% and is
  multiplied by the operating system's text scale, up to 300% in total.
  Layouts wrap and reflow instead of clipping. Wide data tables scroll
  horizontally inside their card. Above 130% the narrow layout uses the
  navigation drawer instead of the bottom bar (whose labels Flutter caps at
  130%). In small windows, or with large text, the filters collapse into
  one **Filters** button at the top of the page that opens a dialog.
- **Motion.** Reduce motion (in Settings, or the operating system's setting)
  sets every app animation to zero: chart entrance, page transitions, panel
  switches, ink splashes and the theme change cross-fade. Nothing flashes.
- **Target size.** Every interactive target is at least 48 x 48 px.
- **No time limits.** Nothing times out. Long API downloads can be
  cancelled.

## WCAG 2.2 conformance (Level A and AA)

Conformance levels follow the ITI VPAT® terms: **Supports**, **Partially
Supports**, **Does Not Support** and **Not Applicable**. WCAG 2.2 removed
4.1.1 Parsing, so it is not listed.

### Level A

| Criterion | Level | Remarks | Evidence |
| --- | --- | --- | --- |
| 1.1.1 Non-text Content | Supports | Each chart is one accessible image node named "title. summary", with a hint pointing to **View as table**. The table view and the CSV copy hold the same numbers. A value that is unknown is written in words, never drawn as an empty or zero bar: a room that sent no heartbeats shows "No heartbeats" in the online chart, its summary, the table and the CSV. Icon-only buttons are named by their tooltips. Decorative icons are hidden with `ExcludeSemantics`. Legend swatches are named, including the pattern ("Disconnected, 12, Diagonal lines pattern"). | Code, Auto (labeled tap targets) |
| 1.2.1 Audio-only and Video-only (Prerecorded) | Not Applicable | The app has no audio or video. | Code |
| 1.2.2 Captions (Prerecorded) | Not Applicable | No media. | Code |
| 1.2.3 Audio Description or Media Alternative (Prerecorded) | Not Applicable | No media. | Code |
| 1.3.1 Info and Relationships | Supports | Every heading uses one shared `Heading` widget. Each is its own semantics node, named exactly by its visible text, with a heading level: page 1, section 2, card 3, inside a card 4 (`aria-level` on the web). The app bar title is not exposed as a second heading. Data tables use Flutter `DataTable`, which exposes table, row, cell and column-header roles. Sortable column headers add their sort state ("Room, sorted ascending"). Form fields have programmatic labels, and chip groups are labelled ("Severity filter"). | Auto (semantics tree walk), Code, Manual |
| 1.3.2 Meaningful Sequence | Supports | The semantics order follows the visual order (single-column reading order inside each card). The skip link is placed first on purpose. | Code, Manual |
| 1.3.3 Sensory Characteristics | Supports | Instructions never rely on shape, position or colour alone. Chart descriptions that mention a dashed line also give the meaning in words, and the table has the values. | Code |
| 1.4.1 Use of Color | Supports | Patterns (on by default), named dash styles, direct value labels, icon and word severities, and tables. If a user turns patterns off in Settings, stacked series are still separated by lines and labelled in the legend and the table. | Code, Auto (palette tests) |
| 1.4.2 Audio Control | Not Applicable | No audio. | Code |
| 2.1.1 Keyboard | Supports | Every control is a focusable Material widget or uses keyboard-aware semantics (for example the skip link handles Enter and Space). Charts have no pointer-only features. The table view provides keyboard access to the values. Issue cards expand with Space or Enter (tested). | Code, Auto (issue card), Manual |
| 2.1.2 No Keyboard Trap | Supports | No custom focus capture. Dialogs and menus (date range picker, room selection, dropdowns) close with Escape and return focus. | Code, Manual |
| 2.1.4 Character Key Shortcuts | Supports | Every shortcut uses Ctrl or Cmd, or F6. There are no single-character shortcuts. | Code |
| 2.2.1 Timing Adjustable | Supports | No time limits. Snackbar confirmations disappear after a few seconds, but each one only repeats a status that is also announced to screen readers, and no action depends on it. | Code |
| 2.2.2 Pause, Stop, Hide | Supports | Nothing moves for more than 5 seconds except loading indicators, which belong to the loading itself. Under reduce motion the indicators become static. | Code, Auto (reduce motion) |
| 2.3.1 Three Flashes or Below Threshold | Supports | Nothing flashes. | Code |
| 2.4.1 Bypass Blocks | Supports | The **Skip to main content** link is the first tab stop. F6 moves to the content. Headings allow heading navigation. | Code, Auto (shell tests), Manual |
| 2.4.2 Page Titled | Supports | Web: the browser tab title is "*Page* · AV Metrics Visualizer" and changes with each page (Flutter's `Title` widget sets `document.title`); before the app starts, `index.html` has the title "AV Metrics Visualizer" and `lang="en"`. Desktop: the window title is "AV Metrics Visualizer", set by the Windows, macOS and Linux runners. Flutter does not change a desktop window's title per page, so the window names the application (the software's title, as WCAG2ICT applies 2.4.2 to software) and each page is identified by its level 1 heading, the app bar title and the selected navigation item. | Auto (per-page title test), Code, Manual (desktop window title) |
| 2.4.3 Focus Order | Supports | Focus moves in reading order: skip link, app bar, navigation, filter bar, page content. The skip link is a single tab stop, and Tab after skipping goes to the first control in the page. When a control on one page opens another page, or a data load finishes, focus moves to the start of the new page's content and "*Page* page" is announced. Issue links on other pages open the Issues page filtered to that room, with the issue expanded and focused. The loading overlay's **Cancel** button takes focus while it is shown. Choosing a download period chip on Data source with Space or Enter leaves focus on that chip (each chip has its own stable focus node), and when the **Large download** dialog is cancelled focus returns to the selected period chip. Removing a chip moves focus to the next chip, and removing a device type override moves focus to the next row's remove button (or the entry field when the list is empty). Links that open a Settings section ("Open Event recognition settings" under Data quality, "Set device types in Settings" on Devices and Forecast, "Detection thresholds" on Issues) scroll the section into view, move focus to it and announce "Showing *section* settings". | Auto (focus tests, including period chips and the Large download dialog), Code, Manual |
| 2.4.4 Link Purpose (In Context) | Supports | Navigation buttons say where they go ("Open room BSS_245", "Edit rated life in Settings", "Open Event recognition settings", "Review in Issues"). The Implementation Guide's address is shown in full as selectable text with a copy button, because the app opens no browser. An issue named in a list opens that issue on the Issues page. | Code, Auto |
| 2.5.1 Pointer Gestures | Supports | No multi-point or path-based gestures. Charts cannot be panned or zoomed. | Code |
| 2.5.2 Pointer Cancellation | Supports | Material controls activate on release, and moving the pointer away cancels. | Code |
| 2.5.3 Label in Name | Supports | Accessible names start with or contain the visible label. KPI tiles read "label: value. caption". | Code, Manual |
| 2.5.4 Motion Actuation | Not Applicable | No device-motion input. | Code |
| 3.1.1 Language of Page | Supports | The web page declares `lang="en"`. Desktop builds use the operating system locale. | Code |
| 3.2.1 On Focus | Supports | Focus never triggers navigation or changes of context. | Code |
| 3.2.2 On Input | Supports | Changing a filter re-analyses and updates the page content (announced). It does not change the page or move focus. Choosing a period chip or ticking **Remember token** leaves focus on that control. After you explicitly load a dataset, the app opens the Overview, which is the expected result of that action. | Code |
| 3.2.6 Consistent Help | Supports | Help and contact information (About, Data source instructions) is in the same place in the navigation on every page. | Code |
| 3.3.1 Error Identification | Supports | Errors are described in text in an error banner, which is a live region, or under the field that has the problem (for example an invalid regular expression or token, or an Event recognition list change that would leave no source prefix and no source name; the list is then left unchanged). Field errors are tied to their field programmatically and are announced when they appear (see 4.1.3). | Code, Auto (settings and data source tests) |
| 3.3.2 Labels or Instructions | Supports | Every field has a visible label. Many have helper text (search scope, date period, the export command, the room/device format for device type overrides). Every Event recognition list and pattern has a short description of what it matches and shows its default value under the field. Every text field (settings, the API address and the API token) lets helper and error text wrap over up to 24 lines instead of being cut off, so long instructions such as how to fix an address or token stay readable in narrow fields at 200% text (a widget test checks the API address and token errors in a 400 px window at 200%). Settings that interact explain it in a visible, non-blocking note (for example when "Long device session after" reaches "Longest believable session"). | Code, Auto |
| 3.3.7 Redundant Entry | Supports | The API address is remembered. On desktop the token can be remembered for that address in the operating system's credential store. On the web it can be remembered only for the browser tab session (`sessionStorage`), so after the tab is closed it is pasted again; pasting is always allowed. Filters stay the same across pages. | Code |
| 4.1.2 Name, Role, Value | Supports | Material widgets expose name, role and state, such as selected chips, the expanded or collapsed state of issue cards and selected segments. Custom widgets add semantics explicitly: skip-link button, chart image, and KPI tile as a button when it can be activated, including its focusable and focused state. Every dropdown's arrow button is named ("Show the list"), including on desktop and the web where it is a separate button. The text size slider is named "Text size" with a value such as "150 percent". Sortable table headers expose their sort state. | Code, Auto (labeled tap targets, also with desktop semantics; KPI focus; slider name), Manual |

### Level AA

| Criterion | Level | Remarks | Evidence |
| --- | --- | --- | --- |
| 1.2.4 Captions (Live) | Not Applicable | No media. | Code |
| 1.2.5 Audio Description (Prerecorded) | Not Applicable | No media. | Code |
| 1.3.4 Orientation | Supports | No orientation lock. Layouts adapt to any window shape. | Code |
| 1.3.5 Identify Input Purpose | Not Applicable | The app does not collect personal information about the user. The API token is a shared service credential, not the user's own password. | Code |
| 1.4.3 Contrast (Minimum) | Supports | Theme colour pairs reach 4.5:1 (7:1 in high contrast), checked by `theme_contrast_test.dart`. `textContrastGuideline` passes on every main screen in light, dark and high-contrast themes. Chart axis labels drawn on a canvas use the same theme colours, but the automated guideline cannot check canvas text. | Auto, Code |
| 1.4.4 Resize Text | Supports | Text size from 100% to 200% in Settings, multiplied by the operating system scale (up to 300%). Each main screen is tested at 200% in narrow and wide windows with no overflow or clipping. The app bar title gets the full text size (Flutter caps it at 134% by default). Above 130%, narrow windows use the navigation drawer instead of the bottom bar, whose labels Flutter caps at 130%, and the dataset summary moves from the app bar to the filter area. | Auto |
| 1.4.5 Images of Text | Supports | No images of text. All text is live text. | Code |
| 1.4.10 Reflow | Supports | Cards reflow to a single column, and the navigation becomes a bottom bar and a drawer. In short windows (below 480 px, such as 400% browser zoom), and with large text in narrow windows, the bottom bar gives way to the drawer. The filters then collapse into one **Filters** button that scrolls with the page and opens a scrollable dialog, so the page keeps its height for content. The building and room chooser scrolls as a whole, so its options stay reachable at 320 x 256 px. Data tables and the dense charts scroll horizontally inside their cards, which WCAG allows for data tables. Every analysis page is tested at 320 x 256 px and at 320 x 640 px with 200% text. | Auto (320 x 256, 320 x 640 at 200%, 400 px), Manual (browser zoom) |
| 1.4.11 Non-text Contrast | Supports | Chart colours are adjusted to at least 3:1 against the chart background (4.5:1 in high contrast). The theme focus outline on buttons, inputs, menu items, switches and checkboxes is 3 px with at least 3:1 against the surfaces. The app-wide two-tone ring on every other control has 9:1 between its two tones, so one of them reaches 3:1 against any neighbouring colour. The selected navigation pill has an outline with at least 3:1 against the navigation background. Field borders, chip borders and legend swatch outlines use the theme outline colour. Grid lines are decorative. | Auto (palette and focus indicator contrast tests), Code |
| 1.4.12 Text Spacing | Partially Supports | No text container has a fixed height, so text wraps and grows. Flutter draws its own text, so browser tools and user style sheets that override letter, word or line spacing do not apply to the web build. | Code, Manual |
| 1.4.13 Content on Hover or Focus | Supports | The only hover content is Material tooltips, which repeat a visible label or name. Escape dismisses them (handled by Flutter's app widget), they stay while hovered, and they never hide needed information. Chart hover tooltips are turned off. | Code, Manual |
| 2.4.5 Multiple Ways | Supports | Navigation rail, drawer or bottom bar; keyboard shortcuts; and cross-links (for example from issues, heartbeat gaps and the overview to a room, and from Data quality, Devices, Forecast and Issues to the matching Settings section). | Code |
| 2.4.6 Headings and Labels | Supports | Headings name each page, section and card. In Settings > Event recognition the groups (System power, Program start, Sources, Devices, Device type overrides, Controls, Rooms and buildings) are level 3 headings. Labels describe purpose, and each "Reset ... to default" button names its list ("Reset source prefixes to default"). | Code |
| 2.4.7 Focus Visible | Supports | The theme gives buttons, chips, menu items, segmented buttons, inputs, switches and checkboxes a 3 px focus outline. Every other focusable control gets the app-wide two-tone focus ring while the keyboard is in use. That includes list rows; switch, checkbox and radio rows (Flutter keeps their own control out of the focus order); KPI tiles; sortable data-table headers; navigation destinations; and the main content area after **Skip to main content**. Issue cards draw a ring while focus is inside them. | Auto (focus ring tests), Code, Manual |
| 2.4.11 Focus Not Obscured (Minimum) | Supports | Focus traversal scrolls the focused control into view. The app bar, the fixed filter bar and the navigation sit outside the scrolling content, so they never cover it. The focus ring is clipped to the scrolling area, so it never draws over them. Snackbars appear only briefly after an action. | Code, Manual |
| 2.5.7 Dragging Movements | Supports | Nothing requires dragging. Scrolling also works with the keyboard, mouse wheel and scrollbars. The date range picker opens on the calendar (single taps) and has a switch to typed dates. | Code |
| 2.5.8 Target Size (Minimum) | Supports | The theme makes targets at least 48 x 48 px. `androidTapTargetGuideline` (48 px) passes on every main screen. | Auto |
| 3.1.2 Language of Parts | Supports | All interface text is English. Room and device names are identifiers taken from the data. | Code |
| 3.2.3 Consistent Navigation | Supports | The same navigation, in the same order, on every page. | Code |
| 3.2.4 Consistent Identification | Supports | Shared components keep the same names everywhere (View as table, Copy as CSV, Clear filters, Open room ...). | Code |
| 3.3.3 Error Suggestion | Supports | Load and API errors include a "Suggestion:" line, for example how to export a CSV or check the token. Field validation explains how to fix the value. | Code, Auto |
| 3.3.4 Error Prevention (Legal, Financial, Data) | Not Applicable | The app never changes data on the server. Locally, "Reset to defaults" and "Reset event recognition to defaults" ask for confirmation first, and each list or pattern can be reset to its default on its own. | Code |
| 3.3.8 Accessible Authentication (Minimum) | Supports | Signing in to the API means entering a token, which can always be pasted (the field allows paste and has a Show token button). Desktop builds can remember it in the operating system's credential store; the web build can remember it only for the browser tab session, and after the tab is closed it is pasted again. There is no cognitive function test. | Code |
| 4.1.3 Status Messages | Supports | `SemanticsService` announcements report load start and finish, analysis results, errors, issue result counts (after typing pauses, not on every keystroke), copy confirmations, table re-sorts ("Sorted by Room, ascending."), added and removed list entries (including device type overrides), list and section resets, and the page reached after in-page navigation. The settings hint that appears when two limits interact is a live region. Settings field errors are announced when they appear on desktop and the web, where Flutter does not make them live regions. The error banner is a live region. Announcements are checked in widget tests. | Auto, Manual |

## Section 508 and EN 301 549 notes

| Provision | Notes |
| --- | --- |
| 508 E205.4 / EN 301 549 chapter 9 (web) | The web build is evaluated against WCAG 2.2 AA above. |
| 508 E207.2 / EN 301 549 chapter 11 (software) | Desktop builds are evaluated against the same WCAG criteria applied to software, as WCAG2ICT describes. |
| 502.2.1 / 11.5.2.x Interoperability with assistive technology | Flutter maps its semantics tree to the platform accessibility API: UI Automation on Windows, NSAccessibility on macOS and ARIA in the browser. Flutter's Linux desktop support for AT-SPI (Orca) is less mature. Test it before claiming support on Linux. |
| 502.3.x / 11.5.2.5 to 11.5.2.17 Object information, row and column headers, values, states | Covered by Flutter semantics (see 1.3.1 and 4.1.2). Confirm with the inspection tools in the manual procedure (Accessibility Insights for Windows, Accessibility Inspector on macOS). |
| 503.2 / 11.7 User preferences | The app follows the system light or dark mode, text scale and reduced motion (`disableAnimations`) settings. The operating system high-contrast flag switches the chart palette to high-contrast colours. The app has its own high-contrast themes, but it does **not** adopt Windows "contrast themes" system colours (see limitations). |
| 503.4 / 11.6 User controls for captions and audio description | Not applicable. There is no media. |
| 504 / 11.8 Authoring tools | Not applicable. Exported CSV is plain data. |
| 602 / chapter 12 Documentation and support | The README, the analytics methodology and this document are plain Markdown, readable with assistive technology. Accessibility support requests can be raised as described below. |

## Known limitations

1. **Flutter web draws on a canvas.** Screen readers use Flutter's
   accessibility tree, which is a separate DOM layer. As a result:
   - browser find-in-page (Ctrl+F) and text selection only partly work;
   - user style sheets, text-spacing bookmarklets and browser reader modes
     have no effect;
   - Windows contrast themes and `forced-colors` are not applied to the
     page. Use the app's high-contrast theme instead.
2. **Charts are not explorable point by point.** You cannot move through
   individual bars or points with arrow keys. Each chart's summary sentence
   and its **View as table** view (sortable, keyboard and screen reader
   friendly) give the same information, and **Copy as CSV** exports it.
3. **Sort state on the web.** Flutter has no `aria-sort` equivalent, so
   sortable column headers carry their sort state in their accessible name
   ("Room, sorted ascending") rather than as a property.
4. **Focus ring placement.** The app-wide focus ring is drawn on an overlay
   above the page. While a page or panel is animating (with motion allowed)
   it can trail the control by a frame.
5. **Some animations inside Flutter ignore reduce motion.** For example,
   text-field helper and error text fades in over about 167 ms. Every
   animation in the app's own code turns off.
6. **Snackbar confirmations** disappear after about 4 seconds. Their message
   is also announced to screen readers, and the copied data stays on the
   clipboard.
7. **Reflow** is tested automatically at 320 x 256 px and 320 x 640 px
   (200% text) in widget tests. Confirm it at 400% zoom in each browser with
   the manual procedure.
8. **Linux desktop screen reader support** depends on Flutter's AT-SPI
   bridge. It is not yet verified with Orca.

## Manual test procedure

Run this procedure for every release you include in an ACR. Use the demo
data (**Data source > Explore demo data**) so results can be repeated. Test
every analysis page (Overview, Rooms, Sources, Devices, System usage,
Connectivity, Issues, Forecast) plus Data source, Settings and About.
Record each result as Pass, Fail (with notes) or N/A, together with the
build, platform and assistive technology versions.

### Test matrix

| Platform | Assistive technology | Browser (web build) |
| --- | --- | --- |
| Windows 11 | NVDA (latest) | Chrome, Firefox, and the desktop build |
| Windows 11 | JAWS (latest) | Chrome, Edge, and the desktop build |
| Windows 11 | Narrator | Edge, and the desktop build |
| macOS (current) | VoiceOver | Safari, Chrome, and the desktop build |
| Windows / macOS | Keyboard only, no assistive technology | Every browser above and the desktop build |
| Windows / macOS | System magnifier at 200% to 400% | Chrome, and the desktop build |

### Procedures

1. **Keyboard only.** Unplug or ignore the mouse.
   - Press Tab from the start of the page. The first stop is **Skip to main
     content**, and Enter moves focus into the page.
   - Reach and operate every control on every page with Tab, Shift+Tab,
     Enter, Space, the arrow keys (segmented buttons, menus) and Escape
     (dialogs, menus, tooltips). Nothing should trap focus.
   - Focus is always visible. Note any control whose focus indicator is hard
     to see. Check sortable table headers, KPI tiles, list rows, settings
     switches and the navigation in particular.
   - Activate a link inside a page (for example **View all issues** on the
     Overview, or an issue in a room's detail). Focus must land at the start
     of the new page, or on the issue, not back at the skip link.
   - Try Ctrl/Cmd+1 to 8, Ctrl/Cmd+O, Ctrl/Cmd+D, Ctrl/Cmd+, and F6.
   - On Issues: filter with the chips, dropdowns and search, open an issue
     with Space, activate **Open room**, and copy the issues as CSV.
   - In Settings > Event recognition: add a name to a list with Enter,
     remove one with its chip's delete button (focus moves to the next
     chip), type an invalid pattern (the error is shown and announced), and
     use a **Reset ... to default** button. From the Overview's Data quality
     card, activate **Open Event recognition settings**: Settings opens at
     that section with focus on it.
2. **Screen readers (NVDA + Chrome/Firefox, JAWS + Chrome/Edge, Narrator +
   Edge, VoiceOver + Safari/Chrome, and each desktop build).**
   - Headings: list the headings (NVDA/JAWS: Insert+F7 or H; VoiceOver: the
     rotor). Each page has a page heading, section headings and a heading
     for each card.
   - Charts: each chart is read as an image named "title. summary sentence"
     with the hint "Use View as table for the exact values". **View as table**
     shows a table you can read with table navigation (Ctrl+Alt+arrows),
     with column headers announced.
   - Forms: every field reads its label and helper text. Errors are read
     when they appear.
   - Status: loading a dataset, changing a filter (Issues: "Showing N of M
     issues."), copying CSV and errors are announced without moving focus.
   - States: filter chips read "selected", issue cards read
     "expanded/collapsed", and segmented buttons read their selection.
   - Legends read the label, value and pattern name, and line legends read
     the line style ("dashed line").
3. **200% text.** In Settings set **Text size** to 200% (and separately set
   the operating system text size to 200% with the app at 100%). On a
   1280 x 800 window and on a narrow window (about 400 px), check every page:
   no clipped or overlapping text and no lost content. Content may scroll
   vertically, and data tables may scroll horizontally.
4. **400% browser zoom / 320 px reflow (web).** Set the browser to 1280 px
   wide and zoom to 400% (equivalent to 320 CSS px). Every page must work
   with vertical scrolling only, except inside data tables and charts. Check
   the drawer, the **Filters** button and its dialog, the building and room
   choosers and the other dialogs.
5. **High contrast.**
   - In Settings, turn on **High contrast** in both light and dark themes.
     Check text, borders, focus rings and chart colours.
   - Turn on Windows contrast themes (Settings > Accessibility > Contrast
     themes). Record what happens. The app's own high-contrast mode is the
     supported option (see limitation 1).
   - Try every chart palette, including **Monochrome**, and check that
     series can be told apart by pattern, dash style and label.
6. **Reduced motion.**
   - Turn on **Reduce motion** in Settings. Page changes, chart entrance and
     the table/chart switch must happen instantly.
   - Turn the setting off, then turn on the operating system setting
     (Windows: Settings > Accessibility > Visual effects > Animation
     effects off; macOS: Reduce motion). The app must also stop animating.
   - Nothing may flash more than 3 times per second.
7. **Colour vision.** Use a colour-blindness simulator (for example the
   Chrome DevTools "Emulate vision deficiencies" option on the web build) to
   check each palette for deuteranopia, protanopia, tritanopia and
   achromatopsia.
8. **Inspection tools.** On Windows, inspect names, roles and states with
   Accessibility Insights for Windows (desktop) or Accessibility Insights for
   Web (browser). On macOS, use Accessibility Inspector.

### Checklist

- [ ] Skip link is the first tab stop and works
- [ ] Every control can be reached and operated by keyboard; no traps
- [ ] Focus is visible everywhere (note weak indicators)
- [ ] Web: each page has a unique tab title; desktop: the window title is "AV Metrics Visualizer" and the page heading names the page
- [ ] Headings can be navigated on every page
- [ ] Every chart has a summary and a table with the same numbers
- [ ] Tables announce row and column headers
- [ ] Nothing is shown by colour alone (check each palette, patterns on and off)
- [ ] Text, controls and chart marks meet contrast in light, dark and high-contrast themes
- [ ] 200% text: no loss of content (in-app setting and system setting)
- [ ] 400% zoom / 320 px: reflows without two-dimensional scrolling (except tables)
- [ ] Reduce motion removes all animation (app setting and system setting)
- [ ] Status messages are announced (load, filter counts, copy, errors)
- [ ] Errors are described in text with a suggestion
- [ ] Tooltips can be dismissed with Escape and do not hide content
- [ ] Every target is at least 24 x 24 px (app goal: 48 x 48)
- [ ] NVDA, JAWS, Narrator and VoiceOver results recorded for web and desktop

## Reporting accessibility problems

Please open an issue in the project repository
(<https://github.com/mefranklin6/AV-System-Metrics/issues>) with the label
`accessibility`. Include:

- the page and control involved;
- the platform, browser or desktop build, and app version (shown on the About
  page);
- the assistive technology and its version, if any;
- what you expected and what happened.

If you cannot use GitHub, contact your campus AV or IT accessibility
coordinator and ask them to pass the report on. We treat accessibility
barriers as defects and fix them with the same priority as functional bugs.
