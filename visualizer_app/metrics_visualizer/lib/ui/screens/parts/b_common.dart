// Small helpers shared by the Connectivity, Issues and Forecast screens.
//
// Private to those screens (the "b_" prefix marks files owned by them); not
// part of the shared widget library.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../../analytics/analytics.dart';
import '../../widgets/widgets.dart';

/// RFC 3339 UTC timestamp for CSV export of an instant.
String instantIso(DateTime t) => t.toUtc().toIso8601String();

/// Icon for an issue severity. The shapes differ (circle, triangle, "i") so
/// severity never depends on colour alone.
IconData severityIcon(IssueSeverity s) => switch (s) {
      IssueSeverity.critical => Icons.error,
      IssueSeverity.warning => Icons.warning_amber_rounded,
      IssueSeverity.info => Icons.info_outline,
    };

/// Background and foreground colours for a severity badge, taken from the
/// theme's container/on-container pairs (designed for >= 4.5:1 text
/// contrast in every theme, including high contrast).
(Color, Color) severityColors(ColorScheme cs, IssueSeverity s) => switch (s) {
      IssueSeverity.critical => (cs.errorContainer, cs.onErrorContainer),
      IssueSeverity.warning => (cs.tertiaryContainer, cs.onTertiaryContainer),
      IssueSeverity.info => (cs.secondaryContainer, cs.onSecondaryContainer),
    };

/// A severity shown as icon + word ("Critical") on a tinted background.
class SeverityBadge extends StatelessWidget {
  const SeverityBadge(this.severity, {super.key});

  final IssueSeverity severity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (bg, fg) = severityColors(theme.colorScheme, severity);
    return Semantics(
      label: 'Severity: ${severity.label}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: fg.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(severityIcon(severity), size: 18, color: fg),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                severity.label,
                style: theme.textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tone of an [InfoCallout].
enum CalloutTone { info, warning }

/// A highlighted note (data caveat, minimum-data message, "how to enable").
/// The icon is decorative; the title and message carry the meaning.
class InfoCallout extends StatelessWidget {
  const InfoCallout({
    super.key,
    required this.title,
    required this.message,
    this.icon,
    this.tone = CalloutTone.info,
    this.actions = const [],
    this.children = const [],
  });

  final String title;
  final String message;
  final IconData? icon;
  final CalloutTone tone;
  final List<Widget> actions;

  /// Extra content under the message (bullets, details).
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (bg, fg) = switch (tone) {
      CalloutTone.info => (cs.secondaryContainer, cs.onSecondaryContainer),
      CalloutTone.warning => (cs.tertiaryContainer, cs.onTertiaryContainer),
    };
    return Semantics(
      container: true,
      child: Card(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: fg.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(
                    icon ?? (tone == CalloutTone.warning ? Icons.warning_amber_rounded : Icons.info_outline),
                    color: fg,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Heading(
                      title,
                      level: HeadingLevel.subsection,
                      style: theme.textTheme.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: fg)),
                    if (children.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DefaultTextStyle.merge(
                        style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
                      ),
                    ],
                    if (actions.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Theme(
                        // Buttons on the tinted background use its text colour.
                        data: theme.copyWith(
                          textButtonTheme: TextButtonThemeData(
                            style: TextButton.styleFrom(foregroundColor: fg),
                          ),
                          outlinedButtonTheme: OutlinedButtonThemeData(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: fg,
                              side: BorderSide(color: fg),
                            ),
                          ),
                        ),
                        child: Wrap(spacing: 8, runSpacing: 8, children: actions),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A bullet line for use inside [InfoCallout.children] or panels.
class BulletText extends StatelessWidget {
  const BulletText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ExcludeSemantics(child: Text('•  ')),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// Copies [text] to the clipboard, then confirms with a snackbar and a
/// screen reader announcement.
Future<void> copyWithConfirmation(BuildContext context, String text, String message) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
  announce(context, message);
}

/// A plain card with a section heading, used for non-chart content.
class TitledCard extends StatelessWidget {
  const TitledCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              title: title,
              subtitle: subtitle,
              trailing: trailing,
              level: HeadingLevel.subsection,
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// An instant with seconds ("Nov 3, 2026 9:15:42 AM"), in the zone chosen
/// in Settings. Used for evidence events, where seconds matter.
String instantWithSeconds(Fmt fmt, DateTime t) =>
    '${DateFormat.yMMMd().add_jms().format(fmt.display(t))}${fmt.zoneSuffix}';
