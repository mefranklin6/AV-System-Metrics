import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/widgets.dart';

/// App version shown in About (keep in sync with pubspec.yaml).
const String appVersion = '1.0.0';

/// The About page's sentence on where a remembered API token is kept
/// (matches rememberTokenWording on Data source).
String aboutTokenStorage({bool isWeb = kIsWeb}) => isWeb
    ? 'The API token is kept in memory unless you choose to remember it; then it is kept in this browser '
        "tab's session storage and forgotten when the tab is closed."
    : 'The API token is kept in memory unless you choose to remember it; then it is stored in the '
        'operating system credential store.';

/// Where the accessibility conformance notes live.
const String accessibilityStatementUrl =
    'https://github.com/mefranklin6/AV-System-Metrics/blob/main/visualizer_app/metrics_visualizer/ACCESSIBILITY.md';

/// Version, accessibility statement and data/privacy notes.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final body = theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface);
    Widget card(String title, List<Widget> children) => Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [SectionHeader(title: title), ...children],
            ),
          ),
        );

    final sections = <Widget>[
      const SectionHeader(
        title: 'About AV System Metrics Visualizer',
        subtitle: 'Usage data from AV control systems, for planning, budgeting and system design.',
        level: HeadingLevel.page,
      ),
      card('Version', [
        Text('Version $appVersion', style: body),
        const SizedBox(height: 8),
        Text(
          'Part of the open-source AV System Metrics project. The visualizer and the optional '
          'Analytics API are separate from the services that collect the data and can be turned off.',
          style: body,
        ),
      ]),
      card('Implementation Guide', [
        Text(
          'Control programs on any platform (Extron, Crestron, AMX, Q-SYS or others) can send events to '
          'AV System Metrics. The Implementation Guide describes which events to log and how to name them '
          'so this app can analyze them without knowing the program. Names it does not recognize can be '
          'matched under Settings > Event recognition.',
          style: body,
        ),
        const SizedBox(height: 8),
        const GuideLink(intro: 'The guide is published at:'),
      ]),
      card('Accessibility', [
        Text(
          'This app aims to conform to WCAG 2.2 Level AA and Section 508. It supports screen readers '
          '(NVDA, JAWS, Narrator, VoiceOver, TalkBack), full keyboard operation, text up to 200%, '
          'light, dark and high-contrast themes, colour-blind palettes with patterns, reduced motion, '
          'and a data table for every chart.',
          style: body,
        ),
        const SizedBox(height: 8),
        Text('The accessibility conformance notes (a basis for a VPAT / ACR) are published at:', style: body),
        const SizedBox(height: 4),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SelectableText(accessibilityStatementUrl, style: body?.copyWith(color: cs.primary)),
            IconButton(
              tooltip: 'Copy the accessibility statement address',
              icon: const Icon(Icons.copy_outlined),
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: accessibilityStatementUrl));
                if (context.mounted) announce(context, 'Address copied to the clipboard.');
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('To report an accessibility barrier, open an issue in the project repository.', style: body),
      ]),
      card('Data and privacy', [
        for (final line in [
          'Files you import are read on this computer only; nothing is uploaded.',
          'Data from the Analytics API is held in memory and discarded when you close the app or clear the data.',
          aboutTokenStorage(),
          'The Analytics API never exposes source IP addresses, and it only has read-only database access.',
          'Settings such as theme and thresholds are stored locally on this computer.',
          'The app sends no analytics or telemetry and loads nothing from third-party sites.',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(child: Text('•  ', style: body)),
                Expanded(child: Text(line, style: body)),
              ],
            ),
          ),
      ]),
      card('Keyboard shortcuts', const [ShortcutList()]),
    ];

    return LayoutBuilder(builder: (context, constraints) {
      final horizontal = constraints.maxWidth < 600 ? 16.0 : 24.0;
      return ListView.builder(
        padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 32),
        itemCount: sections.length,
        itemBuilder: (context, i) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(padding: const EdgeInsets.only(bottom: 16), child: sections[i]),
          ),
        ),
      );
    });
  }
}
