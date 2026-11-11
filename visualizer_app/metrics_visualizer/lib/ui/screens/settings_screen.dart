import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart' show IssueType, IssueTypeLabel, MetricClassifier, PowerSource, PowerSourceLabel;
import '../../analytics/config.dart';
import '../../analytics/sessions.dart' show SessionBuilder;
import '../../state/app_state.dart';
import '../../state/navigation_state.dart';
import '../../state/settings_state.dart';
import '../widgets/widgets.dart';
import 'data_source_screen.dart' show rememberedTokenStatus;

/// Appearance, accessibility and analysis settings. Every change applies
/// immediately and is saved on this computer.
///
/// Other pages open a particular section with
/// `NavigationState.openSettings(SettingsSection.eventRecognition)`: the
/// page scrolls to it, moves keyboard focus there and announces it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ScrollController _scroll = ScrollController();
  final Map<SettingsSection, GlobalKey> _keys = {
    for (final s in SettingsSection.values) s: GlobalKey(debugLabel: 'Settings ${s.title}'),
  };
  final Map<SettingsSection, FocusNode> _focus = {
    for (final s in SettingsSection.values) s: FocusNode(debugLabel: 'Settings ${s.title}', skipTraversal: true),
  };

  @override
  void dispose() {
    _scroll.dispose();
    for (final n in _focus.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// Scrolls step by step until the lazily built [section] exists, then
  /// brings it into view, focuses it and announces it.
  void _reveal(SettingsSection section, [int attempt = 0]) {
    if (!mounted) return;
    final ctx = _keys[section]!.currentContext;
    if (ctx == null) {
      if (_scroll.hasClients && attempt < 60) {
        final p = _scroll.position;
        if (p.pixels < p.maxScrollExtent) {
          _scroll.jumpTo((p.pixels + p.viewportDimension * 0.8).clamp(0, p.maxScrollExtent));
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(section, attempt + 1));
      }
      return;
    }
    Scrollable.ensureVisible(ctx, alignment: 0.02);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus[section]!.requestFocus();
    });
    announce(context, 'Showing ${section.title} settings.');
  }

  Widget _anchor(SettingsSection s, Widget child) =>
      Focus(key: _keys[s], focusNode: _focus[s], child: child);

  @override
  Widget build(BuildContext context) {
    final pending = context.select<NavigationState, SettingsSection?>((n) => n.pendingSettingsSection);
    if (pending != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final s = context.read<NavigationState>().takeSettingsSection();
        if (s != null) _reveal(s);
      });
    }
    return LayoutBuilder(builder: (context, constraints) {
      final horizontal = constraints.maxWidth < 600 ? 16.0 : 24.0;
      final sections = <Widget>[
        const SectionHeader(
          title: 'Settings',
          subtitle: 'Changes apply immediately and are saved on this computer.',
          level: HeadingLevel.page,
        ),
        const _AppearanceSection(),
        const _ChartsSection(),
        const _DataSection(),
        _anchor(
          SettingsSection.eventRecognition,
          _EventRecognitionSection(
            overrides: _anchor(SettingsSection.deviceTypeOverrides, const _DeviceTypeOverridesSection()),
          ),
        ),
        _anchor(SettingsSection.thresholds, const _ThresholdsSection()),
        const _LifeSection(),
        const _ShortcutsSection(),
        const _ResetSection(),
      ];
      return ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 32),
        itemCount: sections.length,
        itemBuilder: (context, i) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: sections[i],
            ),
          ),
        ),
      );
    });
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title: title, subtitle: subtitle),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {this.helper});

  final String text;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: theme.textTheme.titleSmall?.copyWith(color: cs.onSurface)),
          if (helper != null)
            Text(helper!, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ appearance

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final platformReduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final pct = '${(s.textScale * 100).round()}%';
    return _SettingsCard(
      title: 'Appearance and accessibility',
      children: [
        const _Label('Theme'),
        Semantics(
          label: 'Theme',
          container: true,
          explicitChildNodes: true,
          child: SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('System')),
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
            ],
            selected: {s.themeMode},
            onSelectionChanged: (v) => s.setThemeMode(v.first),
          ),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('High contrast'),
          subtitle: const Text('Black or white backgrounds, stronger outlines and 7:1 text contrast.'),
          value: s.highContrast,
          onChanged: s.setHighContrast,
        ),
        _Label('Text size: $pct',
            helper: 'Scales all text in the app on top of your system text size.'),
        Row(
          children: [
            IconButton(
              tooltip: 'Smaller text',
              onPressed: s.textScale <= SettingsState.minTextScale
                  ? null
                  : () => s.setTextScale(s.textScale - 0.1),
              icon: const Icon(Icons.text_decrease),
            ),
            Expanded(
              // One node named "Text size" with the value "150 percent".
              // The slider's own value-indicator label would otherwise
              // become its accessible name ("150%"); the visible label
              // above already shows the value while dragging.
              child: MergeSemantics(
                child: Semantics(
                  label: 'Text size',
                  child: Slider(
                    value: s.textScale,
                    min: SettingsState.minTextScale,
                    max: SettingsState.maxTextScale,
                    divisions: 10,
                    semanticFormatterCallback: (v) => '${(v * 100).round()} percent',
                    onChanged: s.setTextScale,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Larger text',
              onPressed: s.textScale >= SettingsState.maxTextScale
                  ? null
                  : () => s.setTextScale(s.textScale + 0.1),
              icon: const Icon(Icons.text_increase),
            ),
          ],
        ),
        Text('Preview: Projector 1 was on for 1,234.5 hours.',
            style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface)),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Reduce motion'),
          subtitle: Text(platformReduced
              ? 'Your system already asks apps to reduce motion, so animations are off.'
              : 'Turns off animations and transitions.'),
          value: s.reduceMotion || platformReduced,
          onChanged: platformReduced ? null : s.setReduceMotion,
        ),
        const _Label('Time display',
            helper: 'Also used for hour-of-day and weekday statistics.'),
        Semantics(
          label: 'Time display',
          container: true,
          explicitChildNodes: true,
          child: SegmentedButton<TimeDisplay>(
            segments: [
              for (final t in TimeDisplay.values) ButtonSegment(value: t, label: Text(t.label)),
            ],
            selected: {s.timeDisplay},
            onSelectionChanged: (v) => s.setTimeDisplay(v.first),
          ),
        ),
      ],
    );
  }
}

class _ChartsSection extends StatelessWidget {
  const _ChartsSection();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final scheme = Theme.of(context).colorScheme;
    return _SettingsCard(
      title: 'Chart colours',
      subtitle: 'Every palette is colour-blind friendly; charts also use labels and patterns.',
      children: [
        RadioGroup<ChartPaletteKind>(
          groupValue: s.palette,
          onChanged: (v) {
            if (v != null) s.setPalette(v);
          },
          child: Column(
            children: [
              for (final kind in ChartPaletteKind.values)
                RadioListTile<ChartPaletteKind>(
                  value: kind,
                  contentPadding: EdgeInsets.zero,
                  title: Text(kind.label),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(kind.description),
                      const SizedBox(height: 6),
                      ExcludeSemantics(
                        child: _PaletteSwatches(
                          palette: ChartPalette.resolve(
                            kind: kind,
                            scheme: scheme,
                            highContrast: s.highContrast,
                            patterns: s.showChartPatterns,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Chart patterns'),
          subtitle: Text(s.palette == ChartPaletteKind.monochrome
              ? 'Always on with the monochrome palette.'
              : 'Adds stripes, dots and hatching so series differ by more than colour.'),
          value: s.showChartPatterns || s.palette == ChartPaletteKind.monochrome,
          onChanged: s.palette == ChartPaletteKind.monochrome ? null : s.setShowChartPatterns,
        ),
      ],
    );
  }
}

class _PaletteSwatches extends StatelessWidget {
  const _PaletteSwatches({required this.palette});

  final ChartPalette palette;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < palette.colors.length; i++)
            PatternBox(color: palette.colorAt(i), pattern: palette.patternAt(i), width: 24, height: 24),
        ],
      );
}

// ------------------------------------------------------------------ data

class _DataSection extends StatelessWidget {
  const _DataSection();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final app = context.watch<AppState>();
    final excluded = s.excludeClients.toList()..sort();
    final loadedClients = app.dataset?.clientNames ?? const <String>[];
    return _SettingsCard(
      title: 'Data',
      children: [
        StringListEditor(
          label: 'Clients left out of room analytics',
          helper: 'Exact client names. AVSM-System records server updates and maintenance, not a room.',
          values: excluded,
          addHint: 'Client name to exclude',
          emptyMessage: 'No clients are excluded.',
          onChanged: (v) => s.setExcludeClients(v.toSet()),
        ),
        if (loadedClients.isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () async {
                final result = await showMultiSelectDialog(
                  context: context,
                  title: 'Clients to exclude',
                  options: loadedClients,
                  selected: s.excludeClients,
                  emptyMeansAll: false,
                );
                if (result != null) await s.setExcludeClients(result);
              },
              icon: const Icon(Icons.checklist),
              label: const Text('Choose from loaded data…'),
            ),
          ),
        const Divider(height: 32),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(rememberedTokenStatus(remember: s.rememberApiToken)),
            OutlinedButton.icon(
              onPressed: () async {
                final app = context.read<AppState>();
                await s.setRememberApiToken(false);
                // The same path as unticking "Remember token" on Data source.
                await app.forgetRememberedToken();
                if (context.mounted) announce(context, 'Saved API token removed.');
              },
              icon: const Icon(Icons.key_off_outlined),
              label: const Text('Forget saved API token'),
            ),
          ],
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- analysis

/// Every [ClassifierConfig] field: which metric and action names the app
/// recognizes, following the Implementation Guide's "Matching an existing
/// program". Lists use [StringListEditor] and patterns [PatternSettingField],
/// so every field has a visible label, shows its default, can be reset, and
/// announces validation errors.
class _EventRecognitionSection extends StatelessWidget {
  const _EventRecognitionSection({required this.overrides});

  /// The device type overrides editor, shown under Devices.
  final Widget overrides;

  static String _groupLabel(String group) {
    for (final p in PowerSource.values) {
      if (p.name == group) return p.label;
    }
    return group;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final config = s.analysisConfig;
    final c = config.classifier;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    void update(ClassifierConfig next) => s.setAnalysisConfig(config.copyWith(classifier: next));
    String? check(ClassifierConfig next) => validateAnalysisConfig(config.copyWith(classifier: next));

    Widget subsection(String title, String? description) => Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Heading(title, level: HeadingLevel.subsection),
              if (description != null) ...[
                const SizedBox(height: 4),
                Text(description, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ],
          ),
        );

    Widget list({
      required String label,
      required String helper,
      required String addHint,
      required List<String> values,
      required List<String> defaults,
      required ClassifierConfig Function(List<String>) apply,
    }) =>
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: StringListEditor(
            label: label,
            helper: helper,
            values: values,
            defaultValues: defaults,
            addHint: addHint,
            emptyMessage: 'None. No event is matched by this list.',
            validate: (v) => check(apply(v)),
            onChanged: (v) => update(apply(v)),
          ),
        );

    Widget pattern({
      required String label,
      required String helper,
      required String value,
      required String defaultValue,
      required ClassifierConfig Function(String) apply,
      int minGroups = 0,
    }) =>
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: PatternSettingField(
            label: label,
            value: value,
            defaultValue: defaultValue,
            helper: helper,
            validator: (v) => validateRegexPattern(v, minGroups: minGroups) ?? check(apply(v)),
            onChanged: (v) => update(apply(v)),
          ),
        );

    return _SettingsCard(
      title: SettingsSection.eventRecognition.title,
      subtitle: 'Which metric and action names the app recognizes. The defaults accept the names the '
          'Implementation Guide recommends and the other forms it lists. Change them to match a program '
          'that logs other names. Names ignore capitalization and surrounding spaces; patterns are '
          'case-insensitive regular expressions. Events that match nothing are still loaded: they appear '
          'on the room timeline as "Other" and are listed under Data quality on the Overview page.',
      children: [
        const GuideLink(),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: jsonEncode(c.toJson()) == jsonEncode(const ClassifierConfig().toJson())
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Reset event recognition?'),
                        content: const Text(
                            'Every name list and pattern in Event recognition returns to its default. '
                            'Device type overrides are kept.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await s.setAnalysisConfig(s.analysisConfig.copyWith(classifier: const ClassifierConfig()));
                      if (context.mounted) announce(context, 'Event recognition reset to defaults.');
                    }
                  },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset event recognition to defaults'),
          ),
        ),

        // ---------------------------------------------------- system power
        subsection('System power', 'When a room\'s system is on. Sessions, on-hours and utilization come from these events.'),
        list(
          label: 'System power names',
          helper: 'Metrics treated as system power when logged with Started or Stopped. Each name also '
              'matches followed by a dash and a reason, such as "System Power - User".',
          addHint: 'System power name',
          values: c.systemPowerNames,
          defaults: ClassifierConfig.defaultSystemPowerNames,
          apply: (v) => c.copyWith(systemPowerNames: v),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Text(
            'Power reasons: the text after a system power name\'s dash is grouped as one of the reasons '
            'below. A reason in no group is kept and shown exactly as logged.',
            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
          ),
        ),
        for (final g in ClassifierConfig.powerReasonGroups)
          list(
            label: 'Reasons grouped as ${_groupLabel(g)}',
            helper: 'Logged reasons counted as "${_groupLabel(g)}".',
            addHint: '${_groupLabel(g)} reason',
            values: c.powerReasonSynonyms[g] ?? const [],
            defaults: ClassifierConfig.defaultPowerReasonSynonyms[g] ?? const [],
            apply: (v) => c.copyWith(powerReasonSynonyms: {...c.powerReasonSynonyms, g: v}),
          ),
        list(
          label: 'Startup complete names',
          helper: 'Optional Trace metrics a program sends when the room has finished powering on.',
          addHint: 'Startup complete name',
          values: c.startupCompleteNames,
          defaults: ClassifierConfig.defaultStartupCompleteNames,
          apply: (v) => c.copyWith(startupCompleteNames: v),
        ),
        list(
          label: 'Shutdown complete names',
          helper: 'Optional Trace metrics a program sends when the room has finished powering off.',
          addHint: 'Shutdown complete name',
          values: c.shutdownCompleteNames,
          defaults: ClassifierConfig.defaultShutdownCompleteNames,
          apply: (v) => c.copyWith(shutdownCompleteNames: v),
        ),

        // --------------------------------------------------- program start
        subsection('Program start', null),
        list(
          label: 'Program start names',
          helper: 'Metrics logged with Started or Trace when a processor boots or a program loads. Every '
              'open session in the room ends at that moment.',
          addHint: 'Program start name',
          values: c.programStartNames,
          defaults: ClassifierConfig.defaultProgramStartNames,
          apply: (v) => c.copyWith(programStartNames: v),
        ),

        // --------------------------------------------------------- sources
        subsection('Sources', 'A source routed to the room\'s main display. Source share and time on screen come from these events.'),
        list(
          label: 'Source prefixes',
          helper: 'Metrics that start with one of these, logged with Started or Trace, are source '
              'selections. The text after the prefix is the source name. Spaces around the punctuation are optional.',
          addHint: 'Source prefix',
          values: c.sourcePrefixes,
          defaults: ClassifierConfig.defaultSourcePrefixes,
          apply: (v) => c.copyWith(sourcePrefixes: v),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: StringListEditor(
            label: 'Source names',
            helper: 'Bare metric names that also mean "this source was selected", for programs that log '
                'the source name on its own (case-insensitive).',
            values: c.inputNames,
            defaultValues: ClassifierConfig.defaultInputNames,
            addHint: 'Source name, e.g. hdmi_2',
            emptyMessage: 'None. Only the source prefixes are used.',
            normalize: (v) => v.toLowerCase(),
            validate: (v) => check(c.copyWith(inputNames: v)),
            onChanged: (v) => update(c.copyWith(inputNames: v)),
          ),
        ),

        // --------------------------------------------------------- devices
        subsection('Devices', 'Device power events give device on-hours and forecasts.'),
        pattern(
          label: 'Device pattern',
          helper: 'Matches device metrics logged with Started or Stopped, such as "Projector 1". The first '
              'capture group that matches is the device type.',
          value: c.devicePattern,
          defaultValue: ClassifierConfig.defaultDevicePattern,
          minGroups: 1,
          apply: (v) => c.copyWith(devicePattern: v),
        ),
        overrides,

        // -------------------------------------------------------- controls
        subsection('Controls', 'Trace events such as "<Control> Pressed". Control names are shown as logged and not interpreted.'),
        pattern(
          label: 'Navigation pattern',
          helper: 'Controls whose name matches are counted as navigation (page flips, menus, tabs, back, '
              'home), for rapid navigation presses.',
          value: c.navigationButtonPattern,
          defaultValue: ClassifierConfig.defaultNavigationButtonPattern,
          apply: (v) => c.copyWith(navigationButtonPattern: v),
        ),
        pattern(
          label: 'Repeatable control pattern',
          helper: 'Controls whose name suggests they are meant to be pressed repeatedly (volume, camera '
              'moves, sliders). Repeated presses of these need '
              '${MetricClassifier.repeatableMashMultiplier} times as many presses before they are reported.',
          value: c.repeatableControlPattern,
          defaultValue: ClassifierConfig.defaultRepeatableControlPattern,
          apply: (v) => c.copyWith(repeatableControlPattern: v),
        ),
        pattern(
          label: 'Help pattern',
          helper: 'Any event whose metric matches is counted as a help-labelled event, whatever its action. '
              'The app reports when and how often these occur; it does not assume what the control does.',
          value: c.helpPattern,
          defaultValue: ClassifierConfig.defaultHelpPattern,
          apply: (v) => c.copyWith(helpPattern: v),
        ),

        // ---------------------------------------------------------- rooms
        subsection('Rooms and buildings', null),
        pattern(
          label: 'Building pattern',
          helper: 'Applied to client names. Capture group 1 is the building, for example SCI from SCI-101.',
          value: c.buildingPattern,
          defaultValue: ClassifierConfig.defaultBuildingPattern,
          minGroups: 1,
          apply: (v) => c.copyWith(buildingPattern: v),
        ),
      ],
    );
  }
}

class _ThresholdsSection extends StatelessWidget {
  const _ThresholdsSection();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final config = s.analysisConfig;
    final t = config.thresholds;
    void update(IssueThresholds next) => s.setAnalysisConfig(config.copyWith(thresholds: next));

    Widget detector(String title, String explanation, int count, Duration window,
        void Function(int) setCount, void Function(Duration) setWindow,
        {bool minutes = false}) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(title, helper: explanation),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              IntSettingField(
                label: '$title: events',
                value: count,
                min: 2,
                max: 1000,
                suffix: 'or more',
                onChanged: setCount,
              ),
              IntSettingField(
                label: '$title: within',
                value: minutes ? window.inMinutes : window.inSeconds,
                min: 1,
                max: minutes ? 1440 : 86400,
                suffix: minutes ? 'minutes' : 'seconds',
                onChanged: (v) => setWindow(minutes ? Duration(minutes: v) : Duration(seconds: v)),
              ),
            ],
          ),
        ],
      );
    }

    return _SettingsCard(
      title: SettingsSection.thresholds.title,
      subtitle: 'A pattern is reported when a room has at least this many events within the time window.',
      children: [
        detector(IssueType.rapidPowerCycling.label, 'System power turned on this many times (a Started that opens a session).',
            t.powerCycleCount, t.powerCycleWindow,
            (v) => update(t.copyWith(powerCycleCount: v)),
            (v) => update(t.copyWith(powerCycleWindow: v)),
            minutes: true),
        detector(IssueType.repeatedPresses.label,
            'Presses of the same control. Controls that match the repeatable control pattern need '
            '${MetricClassifier.repeatableMashMultiplier} times as many.',
            t.buttonMashCount, t.buttonMashWindow,
            (v) => update(t.copyWith(buttonMashCount: v)),
            (v) => update(t.copyWith(buttonMashWindow: v))),
        detector(IssueType.rapidNavigation.label, 'Presses of controls that match the navigation pattern.',
            t.navigationThrashCount, t.navigationThrashWindow,
            (v) => update(t.copyWith(navigationThrashCount: v)),
            (v) => update(t.copyWith(navigationThrashWindow: v))),
        detector(IssueType.rapidSourceChanges.label, 'Source selections covering at least two different sources.',
            t.inputHuntCount, t.inputHuntWindow,
            (v) => update(t.copyWith(inputHuntCount: v)),
            (v) => update(t.copyWith(inputHuntWindow: v))),
        detector(IssueType.connectionFlapping.label, 'Changes between Connected and Disconnected for one device.',
            t.connectionFlapCount, t.connectionFlapWindow,
            (v) => update(t.copyWith(connectionFlapCount: v)),
            (v) => update(t.copyWith(connectionFlapWindow: v)),
            minutes: true),
        const _Label('Other limits'),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            IntSettingField(
              label: 'Long device session after',
              value: t.deviceLeftOnHours,
              min: 1,
              max: 168,
              suffix: 'hours',
              onChanged: (v) => update(t.copyWith(deviceLeftOnHours: v)),
            ),
            IntSettingField(
              label: 'Heartbeat gap after',
              helper: 'No heartbeat or event from a room for this long. 5–43200.',
              width: 260,
              value: t.offlineGap.inMinutes,
              min: 5,
              max: 43200,
              suffix: 'minutes',
              onChanged: (v) => update(t.copyWith(offlineGap: Duration(minutes: v))),
            ),
            IntSettingField(
              label: 'Longest believable session',
              value: config.maxSessionLength.inHours,
              min: 1,
              max: 336,
              suffix: 'hours',
              width: 300,
              helper: 'Sessions without an off event are cut here. A device\'s real off event up to '
                  '${SessionBuilder.deviceHardLimit.inDays} days after it turned on still ends its session.',
              onChanged: (v) => s.setAnalysisConfig(config.copyWith(maxSessionLength: Duration(hours: v))),
            ),
          ],
        ),
        _LeftOnHint(leftOnHours: t.deviceLeftOnHours, maxSessionHours: config.maxSessionLength.inHours),
      ],
    );
  }
}

/// Non-blocking note shown when "Long device session after" is at or above
/// the longest believable session: a device whose off event was lost is cut
/// at that length and so can never count as a long session.
class _LeftOnHint extends StatelessWidget {
  const _LeftOnHint({required this.leftOnHours, required this.maxSessionHours});

  final int leftOnHours;
  final int maxSessionHours;

  static String message(int leftOnHours, int maxSessionHours) =>
      'Note: "Long device session after" ($leftOnHours hours) is at or above "Longest believable session" '
      '($maxSessionHours hours). A device whose off event was lost is cut at $maxSessionHours hours, so it '
      'will not be reported as a long session; only devices whose real off event came later are. Lower '
      '"Long device session after" or raise "Longest believable session" to report those too. '
      'This is only a hint; the settings are saved as entered.';

  @override
  Widget build(BuildContext context) {
    if (leftOnHours < maxSessionHours) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: cs.onSecondaryContainer.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Icon(Icons.info_outline, color: cs.onSecondaryContainer)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message(leftOnHours, maxSessionHours),
                    style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Add/remove list for [AnalysisConfig.deviceTypeOverrides]: the real type
/// of particular devices whose metric name does not say what they are (for
/// example a flat panel a program logs as "Projector 1"). Shown inside
/// Event recognition, under Devices.
class _DeviceTypeOverridesSection extends StatefulWidget {
  const _DeviceTypeOverridesSection();

  @override
  State<_DeviceTypeOverridesSection> createState() => _DeviceTypeOverridesSectionState();
}

class _DeviceTypeOverridesSectionState extends State<_DeviceTypeOverridesSection> {
  final _device = TextEditingController();
  final _deviceFocus = FocusNode(debugLabel: 'Override device');

  /// One focus node per row's remove button, so focus can move to a
  /// neighbour when a row is removed instead of dropping to the top.
  final Map<String, FocusNode> _removeFocus = {};
  String? _type;
  String? _error;

  static const String _deviceLabel = 'Room and device';

  @override
  void dispose() {
    _device.dispose();
    _deviceFocus.dispose();
    for (final n in _removeFocus.values) {
      n.dispose();
    }
    super.dispose();
  }

  FocusNode _focusFor(String key) =>
      _removeFocus.putIfAbsent(key, () => FocusNode(debugLabel: 'Remove override $key'));

  void _fail(String error) {
    if (error != _error) announceFieldError(context, _deviceLabel, error);
    setState(() => _error = error);
  }

  void _add(SettingsState s, List<String> types) {
    final config = s.analysisConfig;
    final key = _device.text.trim();
    final type = (_type ?? _defaultType(types))?.trim().toUpperCase();
    final slash = key.indexOf('/');
    if (key.isEmpty) {
      _fail('Type a room and device, such as SCI-101/Projector 1.');
      return;
    }
    if (slash <= 0 || slash == key.length - 1 || key.indexOf('/', slash + 1) != -1) {
      _fail('Use the form room/device, such as SCI-101/Projector 1, with one slash.');
      return;
    }
    if (key.length > 257) {
      _fail('Keep it under 257 characters (room and device names are at most 128 each).');
      return;
    }
    if (type == null || type.isEmpty) {
      _fail('Choose a device type.');
      return;
    }
    // Keys compare case-insensitively: replace an existing entry.
    final replaced = [
      for (final k in config.deviceTypeOverrides.keys)
        if (k.trim().toLowerCase() == key.toLowerCase()) k,
    ];
    final next = {
      for (final e in config.deviceTypeOverrides.entries)
        if (!replaced.contains(e.key)) e.key: e.value,
      key: type,
    };
    final problem = validateAnalysisConfig(config.copyWith(deviceTypeOverrides: next));
    if (problem != null) {
      _fail(problem);
      return;
    }
    setState(() => _error = null);
    _device.clear();
    s.setAnalysisConfig(config.copyWith(deviceTypeOverrides: next));
    announce(context, replaced.isEmpty ? '$key set to ${_typeName(type)}.' : '$key changed to ${_typeName(type)}.');
  }

  void _remove(SettingsState s, String key, List<String> keys) {
    final config = s.analysisConfig;
    final index = keys.indexOf(key);
    final rest = [...keys]..remove(key);
    final hadFocus = _removeFocus[key]?.hasFocus ?? false;
    s.setAnalysisConfig(config.copyWith(deviceTypeOverrides: {...config.deviceTypeOverrides}..remove(key)));
    announce(context, 'Override for $key removed.');
    if (!hadFocus) return;
    final next = rest.isEmpty ? null : rest[index.clamp(0, rest.length - 1)];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (next == null ? _deviceFocus : _focusFor(next)).requestFocus();
    });
  }

  static String? _defaultType(List<String> types) =>
      types.contains('DISPLAY') ? 'DISPLAY' : types.firstOrNull;

  /// "DISPLAY" -> "Display".
  static String _typeName(String type) =>
      type.isEmpty ? type : '${type[0]}${type.substring(1).toLowerCase()}';

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final config = s.analysisConfig;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final overrides = config.deviceTypeOverrides;
    final keys = overrides.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    // Release focus nodes of removed rows once their buttons are gone.
    final stale = [for (final k in _removeFocus.keys) if (!overrides.containsKey(k)) k];
    if (stale.isNotEmpty) {
      final nodes = [for (final k in stale) _removeFocus.remove(k)!];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final n in nodes) {
          n.dispose();
        }
      });
    }
    final types = {...config.ratedLifeHours.keys, for (final v in overrides.values) v.toUpperCase()}.toList()..sort();
    // Devices in the loaded data, to point out overrides that match nothing.
    final loaded = context.select<AppState, Set<String>?>((a) {
      final devices = a.analysis?.devices.devices;
      return devices == null ? null : {for (final d in devices) '${d.room}/${d.deviceId}'.toLowerCase()};
    });
    final selectedType = types.contains(_type) ? _type : _defaultType(types);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Heading(SettingsSection.deviceTypeOverrides.title, level: HeadingLevel.subsection),
        ),
        Text(
          'A device\'s type is read from its metric name: the text before the device number, so '
          '"Projector 1" is a projector. When a name does not say what the device is (for example a flat '
          'panel logged as a projector), set its real type here so it is grouped correctly and forecast '
          'with the right rated life. Room and device names are not case-sensitive.',
          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        if (keys.isEmpty)
          Text('No overrides. Every device uses the type in its name.',
              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface))
        else
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: 'Device type overrides, ${keys.length} ${keys.length == 1 ? 'entry' : 'entries'}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final k in keys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(text: k, style: const TextStyle(fontWeight: FontWeight.w700)),
                              TextSpan(text: ' is treated as ${_typeName(overrides[k]!.trim().toUpperCase())}'),
                              if (loaded != null && !loaded.contains(k.trim().toLowerCase()))
                                const TextSpan(text: ' (not in the loaded data)'),
                            ]),
                            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                          ),
                        ),
                        IconButton(
                          focusNode: _focusFor(k),
                          tooltip: 'Remove override for $k',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _remove(s, k, keys),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              SizedBox(
                width: math.min(300.0, constraints.maxWidth),
                child: TextField(
                  controller: _device,
                  focusNode: _deviceFocus,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: _deviceLabel,
                    hintText: 'SCI-101/Projector 1',
                    helperText: 'As shown on the Devices page: room, a slash, then the device.',
                    helperMaxLines: settingsTextMaxLines,
                    errorText: _error,
                    errorMaxLines: settingsTextMaxLines,
                  ),
                  onSubmitted: (_) => _add(s, types),
                ),
              ),
              AppDropdownMenu<String>(
                // Rebuilt only when the list of types changes, so choosing a
                // type never recreates the menu (and drops keyboard focus).
                key: ValueKey('override-type-${types.join(',')}'),
                width: math.min(220.0, constraints.maxWidth),
                label: 'Device type',
                helperText: 'Types with a rated life',
                initialSelection: selectedType,
                entries: [for (final t in types) DropdownMenuEntry(value: t, label: t)],
                onSelected: (v) => setState(() => _type = v),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: OutlinedButton.icon(
                  onPressed: () => _add(s, types),
                  icon: const Icon(Icons.add),
                  label: const Text('Add override'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LifeSection extends StatefulWidget {
  const _LifeSection();

  @override
  State<_LifeSection> createState() => _LifeSectionState();
}

class _LifeSectionState extends State<_LifeSection> {
  final _newType = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _newType.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsState>();
    final config = s.analysisConfig;
    final entries = config.ratedLifeHours.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    void setLife(Map<String, double> next) => s.setAnalysisConfig(config.copyWith(ratedLifeHours: next));

    void add() {
      final type = _newType.text.trim().toUpperCase();
      if (type.isEmpty || !RegExp(r'^[A-Z0-9_ -]{1,40}$').hasMatch(type)) {
        setState(() => _error = 'Use letters, numbers, spaces, - or _ (up to 40).');
        return;
      }
      if (config.ratedLifeHours.containsKey(type)) {
        setState(() => _error = '$type is already listed.');
        return;
      }
      setState(() => _error = null);
      _newType.clear();
      setLife({...config.ratedLifeHours, type: 20000});
    }

    return _SettingsCard(
      title: 'Rated service life',
      subtitle: 'Hours until replacement for each device type (the type read from the device name, upper case; '
          'see Event recognition). '
          'Check your equipment data sheets; lamp projectors are often 3,000–6,000 hours.',
      children: [
        for (final e in entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                IntSettingField(
                  key: ValueKey('life-${e.key}'),
                  label: '${e.key} rated life',
                  value: e.value.round(),
                  min: 1,
                  max: 1000000,
                  suffix: 'hours',
                  onChanged: (v) => setLife({...config.ratedLifeHours, e.key: v.toDouble()}),
                ),
                IconButton(
                  tooltip: 'Remove ${e.key}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: config.ratedLifeHours.length <= 1
                      ? null
                      : () => setLife({...config.ratedLifeHours}..remove(e.key)),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: TextField(
                controller: _newType,
                decoration: InputDecoration(labelText: 'New device type', errorText: _error),
                onSubmitted: (_) => add(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: OutlinedButton.icon(onPressed: add, icon: const Icon(Icons.add), label: const Text('Add type')),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShortcutsSection extends StatelessWidget {
  const _ShortcutsSection();

  @override
  Widget build(BuildContext context) => const _SettingsCard(
        title: 'Keyboard shortcuts',
        subtitle: 'On a Mac use Cmd instead of Ctrl.',
        children: [ShortcutList()],
      );
}

class _ResetSection extends StatelessWidget {
  const _ResetSection();

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      title: 'Reset',
      children: [
        Text(
          'Restore appearance, accessibility and analysis settings to their defaults. '
          'The API address is kept.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: () async {
              final settings = context.read<SettingsState>();
              final ok = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Reset all settings?'),
                  content: const Text(
                      'Theme, text size, colours, excluded clients and analysis thresholds return to their defaults.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Reset')),
                  ],
                ),
              );
              if (ok == true) {
                await settings.resetToDefaults();
                if (context.mounted) announce(context, 'Settings reset to defaults.');
              }
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset to defaults'),
          ),
        ),
      ],
    );
  }
}
