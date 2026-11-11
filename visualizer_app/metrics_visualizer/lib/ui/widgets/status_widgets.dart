import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../theme/motion.dart';
import 'section_header.dart';

/// A friendly "nothing here yet" message with an optional action.
///
/// ```dart
/// EmptyState(
///   icon: Icons.inbox_outlined,
///   title: 'No issues found',
///   message: 'Nothing in the selected range crossed the thresholds.',
///   action: FilledButton(onPressed: ..., child: const Text('Adjust thresholds')),
/// )
/// ```
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.headingLevel = HeadingLevel.section,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  /// Level of the [title] heading: [HeadingLevel.page] when the empty state
  /// replaces a whole page (there is no other page heading).
  final HeadingLevel headingLevel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 40, color: cs.onSecondaryContainer),
                ),
              ),
              const SizedBox(height: 16),
              Heading(title,
                  level: headingLevel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(color: cs.onSurface)),
              if (message != null) ...[
                const SizedBox(height: 8),
                Text(message!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
              ],
              if (action != null) ...[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An error message identified in text (WCAG 3.3.1) with an optional fix
/// suggestion (3.3.3), retry and dismiss actions. It is a live region, so
/// screen readers announce it when it appears.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.title,
    required this.message,
    this.suggestion,
    this.onRetry,
    this.retryLabel = 'Try again',
    this.onDismiss,
  });

  final String title;
  final String message;
  final String? suggestion;
  final VoidCallback? onRetry;
  final String retryLabel;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Card(
        color: cs.errorContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.error, width: 2),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 12),
                    child: Icon(Icons.error_outline, color: cs.onErrorContainer, semanticLabel: 'Error'),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: cs.onErrorContainer, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 4),
                        Text(message,
                            style: theme.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                        if (suggestion != null) ...[
                          const SizedBox(height: 6),
                          Text('Suggestion: $suggestion',
                              style: theme.textTheme.bodyMedium?.copyWith(color: cs.onErrorContainer)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (onRetry != null || onDismiss != null)
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      if (onDismiss != null)
                        TextButton(
                          onPressed: onDismiss,
                          style: TextButton.styleFrom(foregroundColor: cs.onErrorContainer),
                          child: const Text('Dismiss'),
                        ),
                      if (onRetry != null)
                        FilledButton(
                          onPressed: onRetry,
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          ),
                          child: Text(retryLabel),
                        ),
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

/// Covers [child] with a progress indicator while [isLoading]. Progress is
/// exposed to assistive technology (value "45%" or "In progress") and the
/// message is a live region. An optional [onCancel] adds a Cancel button.
class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({
    super.key,
    required this.isLoading,
    required this.child,
    this.message,
    this.progress,
    this.onCancel,
  });

  final bool isLoading;
  final Widget child;
  final String? message;

  /// 0..1, or null for indeterminate.
  final double? progress;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final motion = Motion.of(context);
    return Stack(
      children: [
        // Content underneath is hidden from assistive tech and focus while
        // loading so users do not interact with stale content.
        ExcludeFocus(
          excluding: isLoading,
          child: ExcludeSemantics(excluding: isLoading, child: child),
        ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !isLoading,
            child: AnimatedOpacity(
              key: const ValueKey('loading-overlay-fade'),
              opacity: isLoading ? 1 : 0,
              duration: motion.short,
              child: isLoading
                  ? _LoadingPanel(message: message, progress: progress, onCancel: onCancel)
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingPanel extends StatefulWidget {
  const _LoadingPanel({this.message, this.progress, this.onCancel});

  final String? message;
  final double? progress;
  final VoidCallback? onCancel;

  @override
  State<_LoadingPanel> createState() => _LoadingPanelState();
}

class _LoadingPanelState extends State<_LoadingPanel> {
  final FocusNode _cancelFocus = FocusNode(debugLabel: 'Cancel loading');

  @override
  void initState() {
    super.initState();
    _focusCancelSoon();
  }

  @override
  void didUpdateWidget(_LoadingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.onCancel == null && widget.onCancel != null) _focusCancelSoon();
  }

  /// The content under the overlay is excluded from focus while loading, so
  /// whatever was focused (e.g. "Load data") is gone. Put focus on Cancel,
  /// the only thing the user can do now (WCAG 2.4.3). The shell restores
  /// focus to the content when loading ends.
  void _focusCancelSoon() {
    if (widget.onCancel == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.onCancel != null && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _cancelFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _cancelFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final progress = widget.progress;
    final onCancel = widget.onCancel;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final reduced = Motion.isReduced(context);
    final pct = progress == null ? null : '${(progress.clamp(0, 1) * 100).round()}%';
    return ColoredBox(
      color: cs.surface.withValues(alpha: 0.92),
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    label: message ?? 'Loading',
                    value: pct ?? 'In progress',
                    liveRegion: true,
                    child: ExcludeSemantics(
                      child: SizedBox(
                        width: 240,
                        // A static bar under reduce motion when indeterminate.
                        child: LinearProgressIndicator(
                          value: progress ?? (reduced ? 0.5 : null),
                          minHeight: 6,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
                  if (message != null || pct != null) ...[
                    const SizedBox(height: 16),
                    ExcludeSemantics(
                      child: Text(
                        [?message, ?pct].join(' · '),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(color: cs.onSurface),
                      ),
                    ),
                  ],
                  if (onCancel != null) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      focusNode: _cancelFocus,
                      onPressed: onCancel,
                      icon: const Icon(Icons.close),
                      label: const Text('Cancel'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sends a polite screen reader announcement from widget code.
void announce(BuildContext context, String message, {bool assertive = false}) {
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.of(context),
    assertiveness: assertive ? Assertiveness.assertive : Assertiveness.polite,
  );
}
