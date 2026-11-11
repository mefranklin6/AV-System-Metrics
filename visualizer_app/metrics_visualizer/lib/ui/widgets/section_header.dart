import 'package:flutter/material.dart';

/// Heading levels, mapped to Material type styles and to the heading level
/// exposed to assistive technology (`aria-level` on the web).
///
/// The app's outline is: page title (level 1), sections of a page such as
/// "At a glance" or a Settings group (level 2), cards (level 3) and
/// sub-headings inside a card (level 4).
enum HeadingLevel {
  page(1),
  section(2),
  subsection(3),
  detail(4);

  const HeadingLevel(this.level);

  /// Heading level 1-6 for `Semantics.headingLevel`.
  final int level;

  /// The Material text style for this level.
  TextStyle? styleOf(ThemeData theme) => switch (this) {
        HeadingLevel.page => theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
        HeadingLevel.section => theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        HeadingLevel.subsection => theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        HeadingLevel.detail => theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      };
}

/// The one way to declare a heading (WCAG 1.3.1 / 2.4.6).
///
/// It is its own semantics node (`container: true`), so the heading's
/// accessible name is exactly its visible [text]: neighbouring paragraphs,
/// lists and field labels are never merged into it. It carries a heading
/// [level] so screen reader users can navigate the page outline.
///
/// [style] overrides the level's default text style (colour defaults to
/// `onSurface`). Use [child] for a heading with decorations (an icon); the
/// child's text must then match [text], which becomes the accessible name.
class Heading extends StatelessWidget {
  const Heading(
    this.text, {
    super.key,
    required this.level,
    this.style,
    this.textAlign,
    this.child,
  });

  final String text;
  final HeadingLevel level;
  final TextStyle? style;
  final TextAlign? textAlign;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effective = style ?? level.styleOf(theme)?.copyWith(color: theme.colorScheme.onSurface);
    return Semantics(
      header: true,
      headingLevel: level.level,
      container: true,
      label: child == null ? null : text,
      excludeSemantics: child != null,
      child: child ?? Text(text, style: effective, textAlign: textAlign),
    );
  }
}

/// A heading with optional supporting text and an action.
///
/// Use one [HeadingLevel.page] per screen, then [HeadingLevel.section] for
/// groups of cards. [subtitle] is optional supporting text (a separate
/// semantics node, never part of the heading's name), [trailing] an
/// optional action such as a button.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.level = HeadingLevel.section,
    this.padding = const EdgeInsets.only(top: 8, bottom: 12),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final HeadingLevel level;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Heading(title, level: level),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ],
    );
    return Padding(
      padding: padding,
      child: trailing == null
          ? text
          : Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [text, trailing!],
            ),
    );
  }
}
