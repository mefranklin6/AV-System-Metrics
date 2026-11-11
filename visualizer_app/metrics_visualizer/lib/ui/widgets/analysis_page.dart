import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../analytics/analytics.dart';
import '../../state/app_state.dart';
import '../../state/navigation_state.dart';
import '../theme/motion.dart';
import 'filter_bar.dart';
import 'section_header.dart';
import 'status_widgets.dart';

/// Standard frame for analysis screens. It handles every non-happy state
/// consistently so screens only describe their content:
///
/// * no data loaded -> an [EmptyState] linking to the Data source page;
/// * first analysis still running -> an accessible progress message;
/// * analysis failed -> an [ErrorBanner] with Retry;
/// * otherwise -> a page heading followed by the widgets from [builder],
///   in a lazily built, scrollable, width-limited list.
///
/// ```dart
/// class InputsScreen extends StatelessWidget {
///   const InputsScreen({super.key});
///   @override
///   Widget build(BuildContext context) => AnalysisPage(
///         title: 'Sources',
///         subtitle: 'Which sources people select and for how long',
///         builder: (context, analysis) => [
///           ResponsiveGrid(children: [...]),
///           AccessibleChartCard(...),
///         ],
///       );
/// }
/// ```
class AnalysisPage extends StatelessWidget {
  const AnalysisPage({
    super.key,
    required this.title,
    required this.builder,
    this.subtitle,
    this.headerTrailing,
    this.maxContentWidth = 1600,
  });

  final String title;
  final String? subtitle;
  final Widget? headerTrailing;

  /// Builds the page body below the heading from the current analysis.
  final List<Widget> Function(BuildContext context, AnalysisResult analysis) builder;
  final double maxContentWidth;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final motion = Motion.of(context);

    Widget body;
    if (!app.hasData) {
      body = _Scrolls(
        key: const ValueKey('no-data'),
        child: EmptyState(
          icon: Icons.upload_file_outlined,
          title: 'No data loaded',
          headingLevel: HeadingLevel.page,
          message: 'Import a CSV export, connect to the Analytics API or explore the demo campus to see $title.',
          action: FilledButton.icon(
            onPressed: () => context.read<NavigationState>().goTo(AppDestination.dataSource),
            icon: const Icon(Icons.storage_outlined),
            label: const Text('Choose a data source'),
          ),
        ),
      );
    } else if (app.analysis == null) {
      final error = app.error;
      body = error != null && !app.isAnalyzing
          ? _Scrolls(
              key: const ValueKey('error'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ErrorBanner(
                      title: error.title,
                      message: error.message,
                      suggestion: error.suggestion,
                      onRetry: () {
                        app.dismissError();
                        app.reanalyze();
                      },
                    ),
                  ),
                ),
              ),
            )
          : const _AnalysingMessage(key: ValueKey('analysing'));
    } else {
      final analysis = app.analysis!;
      final placement = FilterBarPlacement.maybeOf(context);
      final inline = placement?.inline ?? false;
      final headerIndex = inline ? 1 : 0;
      final children = [
        // Small window or large text: the filters scroll with the page.
        if (inline) FilterBar(compact: true, showDatasetSummary: placement!.showDatasetSummary),
        SectionHeader(title: title, subtitle: subtitle, trailing: headerTrailing, level: HeadingLevel.page),
        ...builder(context, analysis),
      ];
      body = LayoutBuilder(
        key: const ValueKey('content'),
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(horizontal, 16, horizontal, 32),
            itemCount: children.length,
            itemBuilder: (context, i) => Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxContentWidth),
                child: i == headerIndex
                    ? children[i]
                    : Padding(padding: const EdgeInsets.only(bottom: 16), child: children[i]),
              ),
            ),
          );
        },
      );
    }

    return AnimatedSwitcher(
      duration: motion.medium,
      switchInCurve: motion.curve,
      transitionBuilder: (child, animation) => FadeTransition(opacity: animation, child: child),
      child: body,
    );
  }
}

/// Lets a centred state message scroll in very short windows (400% zoom)
/// instead of overflowing.
class _Scrolls extends StatelessWidget {
  const _Scrolls({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );
}

class _AnalysingMessage extends StatelessWidget {
  const _AnalysingMessage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduced = Motion.isReduced(context);
    return Center(
      child: Semantics(
        liveRegion: true,
        label: 'Analysing data, please wait.',
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator(value: reduced ? 0.6 : null)),
            const SizedBox(height: 16),
            Text('Analysing data…', style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface)),
          ],
        ),
      ),
    );
  }
}
