import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/navigation_state.dart';
import 'screens/about_screen.dart';
import 'screens/connectivity_screen.dart';
import 'screens/data_source_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/forecast_screen.dart';
import 'screens/inputs_screen.dart';
import 'screens/issues_screen.dart';
import 'screens/overview_screen.dart';
import 'screens/rooms_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/system_usage_screen.dart';
import 'widgets/widgets.dart';

/// Builds the page for [destination].
Widget screenFor(AppDestination destination) => switch (destination) {
      AppDestination.overview => const OverviewScreen(),
      AppDestination.rooms => const RoomsScreen(),
      AppDestination.inputs => const InputsScreen(),
      AppDestination.devices => const DevicesScreen(),
      AppDestination.systemUsage => const SystemUsageScreen(),
      AppDestination.connectivity => const ConnectivityScreen(),
      AppDestination.issues => const IssuesScreen(),
      AppDestination.forecast => const ForecastScreen(),
      AppDestination.dataSource => const DataSourceScreen(),
      AppDestination.settings => const SettingsScreen(),
      AppDestination.about => const AboutScreen(),
    };

/// Breakpoints (Material 3 window size classes).
abstract final class Breakpoints {
  /// From here a NavigationRail replaces the bottom bar and drawer.
  static const double rail = 840;

  /// From here a permanent navigation drawer replaces the rail.
  static const double extendedRail = 1200;

  /// Below this window height (for example 400% browser zoom) the bottom
  /// bar is dropped (the drawer has every page) and the filters move into
  /// the scrolling content, so pages keep room for content (WCAG 1.4.10).
  static const double shortWindow = 480;

  /// Text scales above this use the drawer instead of the bottom bar,
  /// because Flutter caps bottom bar labels at 130% (WCAG 1.4.4).
  static const double largeText = 1.3;
}

/// How the shell arranges its chrome for a window size and text scale.
@immutable
class ShellLayout {
  const ShellLayout({
    required this.wide,
    required this.extended,
    required this.bottomBar,
    required this.inlineFilters,
    required this.compactAppBar,
  });

  factory ShellLayout.of(Size size, double textScale) {
    final wide = size.width >= Breakpoints.rail;
    final short = size.height < Breakpoints.shortWindow;
    final largeText = textScale > Breakpoints.largeText;
    return ShellLayout(
      wide: wide,
      extended: size.width >= Breakpoints.extendedRail,
      bottomBar: !wide && !short && !largeText,
      inlineFilters: short || (largeText && (!wide || size.height < 720)),
      compactAppBar: largeText && size.width < 600,
    );
  }

  /// Rail or permanent drawer beside the content (otherwise a modal drawer
  /// opened from the app bar).
  final bool wide;
  final bool extended;

  /// Bottom navigation bar (narrow windows with normal text size).
  final bool bottomBar;

  /// The filter bar becomes one "Filters" button at the top of the
  /// scrolling page content instead of a fixed bar above it.
  final bool inlineFilters;

  /// The app bar shows only the page name (on up to two lines); the dataset
  /// summary moves to the filter area.
  final bool compactAppBar;
}

/// The app frame: adaptive navigation, app bar with the data source summary,
/// filter bar for analysis pages, skip-to-content link, keyboard shortcut
/// handling, loading overlay and animated page transitions.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  /// Target of the skip link, F6 and focus restoration. Not a tab stop of
  /// its own: Tab moves on to the first control in the content.
  final FocusNode _contentFocus = FocusNode(debugLabel: 'Main content', skipTraversal: true);

  /// Receives keyboard shortcuts before anything else is focused. Never a
  /// visible focus target.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'App shell', skipTraversal: true);
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final AppState _app;
  late final NavigationState _nav;
  Dataset? _lastDataset;
  late AppDestination _lastDestination;
  bool _wasLoading = false;
  bool _focusCheckScheduled = false;
  bool _pageChangedSinceCheck = false;

  /// Destinations in the narrow-layout bottom bar (the rest are in the
  /// drawer, opened with the "More" item).
  static const List<AppDestination> _barDestinations = [
    AppDestination.overview,
    AppDestination.inputs,
    AppDestination.issues,
    AppDestination.rooms,
  ];

  @override
  void initState() {
    super.initState();
    _app = context.read<AppState>();
    _nav = context.read<NavigationState>();
    _lastDataset = _app.dataset;
    _wasLoading = _app.isLoading;
    _lastDestination = _nav.current;
    _app.addListener(_onAppChanged);
    _nav.addListener(_onNavigationChanged);
    FocusRingOverlay.ignore(_rootFocus);
  }

  @override
  void dispose() {
    _app.removeListener(_onAppChanged);
    _nav.removeListener(_onNavigationChanged);
    _contentFocus.dispose();
    _rootFocus.dispose();
    super.dispose();
  }

  /// After a new dataset loads from the Data source page, show the Overview.
  void _onAppChanged() {
    final loading = _app.isLoading;
    if (_wasLoading && !loading) _scheduleFocusCheck();
    _wasLoading = loading;
    final ds = _app.dataset;
    if (identical(ds, _lastDataset)) return;
    _lastDataset = ds;
    if (!mounted) return;
    if (ds != null && _nav.current == AppDestination.dataSource) {
      _nav.goTo(AppDestination.overview);
    } else if (ds == null && _nav.current.isAnalysis) {
      _nav.goTo(AppDestination.dataSource);
    }
  }

  void _onNavigationChanged() {
    if (_nav.current == _lastDestination) return;
    _lastDestination = _nav.current;
    _pageChangedSinceCheck = true;
    _scheduleFocusCheck();
  }

  /// After a page change or a finished load, the control that had focus may
  /// be gone (for example "View all issues" on the old page, or the loading
  /// overlay's Cancel button). Flutter would then drop focus to the shell
  /// root and the next Tab would restart at the skip link. Instead, focus
  /// moves to the start of the main content and screen reader users hear
  /// which page they are on (WCAG 2.4.3). Focus that is still on a live
  /// control (the rail or drawer item just used) stays where it is.
  void _scheduleFocusCheck() {
    if (_focusCheckScheduled) return;
    _focusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusCheckScheduled = false;
      final pageChanged = _pageChangedSinceCheck;
      _pageChangedSinceCheck = false;
      if (!mounted || _app.isLoading) return;
      // Never take focus out of a dialog or menu on top of the shell.
      if (ModalRoute.of(context)?.isCurrent == false) return;
      final f = FocusManager.instance.primaryFocus;
      final lost = f == null ||
          f == _rootFocus ||
          f is FocusScopeNode ||
          f.context == null ||
          !f.context!.mounted;
      if (!lost) return;
      _contentFocus.requestFocus();
      if (pageChanged) announce(context, '${_nav.current.label} page');
    });
  }

  void _go(AppDestination d) {
    _nav.goTo(d);
  }

  void _skipToContent() {
    _contentFocus.requestFocus();
    announce(context, 'Main content');
  }

  Future<void> _openCsv() async {
    _go(AppDestination.dataSource);
    await context.read<AppState>().pickAndLoadCsv();
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationState>();
    final app = context.watch<AppState>();
    final current = nav.current;
    final layout = ShellLayout.of(MediaQuery.sizeOf(context), MediaQuery.textScalerOf(context).scale(1));
    final cs = Theme.of(context).colorScheme;
    final motion = Motion.of(context);

    final page = KeyedSubtree(
      key: ValueKey(current),
      child: FilterBarPlacement(
        inline: layout.inlineFilters,
        showDatasetSummary: layout.compactAppBar,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (current.isAnalysis && app.hasData && !layout.inlineFilters) ...[
              FilterBar(showDatasetSummary: layout.compactAppBar),
              Divider(height: 1, color: cs.outlineVariant),
            ],
            Expanded(child: screenFor(current)),
          ],
        ),
      ),
    );

    final content = Focus(
      focusNode: _contentFocus,
      child: Semantics(
        container: true,
        label: 'Main content',
        explicitChildNodes: true,
        child: LoadingOverlay(
          isLoading: app.isLoading,
          message: app.loadMessage,
          progress: app.loadProgress,
          onCancel: app.canCancelLoad ? app.cancelLoad : null,
          child: AnimatedSwitcher(
            duration: motion.medium,
            switchInCurve: motion.curve,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1).animate(animation),
                child: child,
              ),
            ),
            child: page,
          ),
        ),
      ),
    );

    final scaffold = Scaffold(
      key: _scaffoldKey,
      appBar: _ShellAppBar(
        destination: current,
        compact: layout.compactAppBar,
        onOpenCsv: _openCsv,
        onSettings: () => _go(AppDestination.settings),
      ),
      drawer: layout.wide ? null : _ShellDrawer(current: current, onSelect: _go),
      body: layout.wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (layout.extended)
                  SizedBox(
                    width: 264,
                    child: _ShellDrawer(current: current, onSelect: _go, permanent: true),
                  )
                else
                  _ShellRail(current: current, onSelect: _go),
                VerticalDivider(width: 1, thickness: 1, color: cs.outlineVariant),
                Expanded(child: content),
              ],
            )
          : content,
      bottomNavigationBar: !layout.bottomBar
          ? null
          : NavigationBar(
              selectedIndex: _barDestinations.contains(current)
                  ? _barDestinations.indexOf(current)
                  : _barDestinations.length,
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              animationDuration: motion.medium,
              onDestinationSelected: (i) {
                if (i < _barDestinations.length) {
                  _go(_barDestinations[i]);
                } else {
                  _scaffoldKey.currentState?.openDrawer();
                }
              },
              destinations: [
                for (final d in _barDestinations)
                  NavigationDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: d.label,
                    tooltip: d.description,
                  ),
                const NavigationDestination(
                  icon: Icon(Icons.menu),
                  label: 'More',
                  tooltip: 'All pages, data source and settings',
                ),
              ],
            ),
    );

    return Title(
      title: '${current.label} · AV Metrics Visualizer',
      color: cs.primary,
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenCsvIntent: CallbackAction<OpenCsvIntent>(onInvoke: (_) {
            _openCsv();
            return null;
          }),
          GoToDestinationIntent: CallbackAction<GoToDestinationIntent>(
            onInvoke: (intent) {
              _go(intent.destination);
              return null;
            },
          ),
          SkipToContentIntent: CallbackAction<SkipToContentIntent>(onInvoke: (_) {
            _skipToContent();
            return null;
          }),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Focus(
            focusNode: _rootFocus,
            autofocus: true,
            child: Stack(
              children: [
                FocusTraversalOrder(
                  order: const NumericFocusOrder(1),
                  child: scaffold,
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  child: FocusTraversalOrder(
                    order: const NumericFocusOrder(0),
                    child: SkipToContentLink(onSkip: _skipToContent),
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

/// "Skip to main content" link (WCAG 2.4.1). It is the first stop in the
/// tab order, invisible until focused, then shown as a prominent button.
class SkipToContentLink extends StatefulWidget {
  const SkipToContentLink({super.key, required this.onSkip});

  final VoidCallback onSkip;

  @override
  State<SkipToContentLink> createState() => _SkipToContentLinkState();
}

class _SkipToContentLinkState extends State<SkipToContentLink> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Draws its own high-contrast outline, so no app-wide ring on top.
    return NoFocusRing(
      child: Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            widget.onSkip();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          button: true,
          label: 'Skip to main content',
          onTap: widget.onSkip,
          excludeSemantics: true,
          child: _focused
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Material(
                    color: cs.inverseSurface,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: widget.onSkip,
                      // The outer Focus is the tab stop; this would be a second one.
                      canRequestFocus: false,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cs.inversePrimary, width: 3),
                        ),
                        child: Text('Skip to main content (Enter)',
                            style: TextStyle(color: cs.onInverseSurface, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                )
              : const SizedBox(width: 1, height: 1),
        ),
      ),
    );
  }
}

class _ShellAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _ShellAppBar({
    required this.destination,
    required this.compact,
    required this.onOpenCsv,
    required this.onSettings,
  });

  final AppDestination destination;

  /// Narrow window with large text: the page name only, on up to two lines.
  final bool compact;
  final VoidCallback onOpenCsv;
  final VoidCallback onSettings;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final summary = datasetSummary(app, Fmt.of(context));
    // AppBar caps its title at 134% text size. Read the real text size here,
    // outside that cap, and give it back to the title (WCAG 1.4.4).
    final mq = MediaQuery.of(context);
    final titleStyle = theme.textTheme.titleLarge?.copyWith(color: cs.onSurface);
    final summaryStyle = theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    double lineHeight(TextStyle? style) =>
        mq.textScaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.4);
    final titleLines = compact ? 2 : 1;
    final contentHeight = lineHeight(titleStyle) * titleLines + (compact ? 0 : lineHeight(summaryStyle));
    return AppBar(
      toolbarHeight: (contentHeight + 20).clamp(64.0, double.infinity),
      titleSpacing: 16,
      // The page heading in the content is the level 1 heading; the app bar
      // title is not announced as a second one.
      excludeHeaderSemantics: true,
      title: MediaQuery(
        data: mq,
        child: Semantics(
          label: compact || app.dataset == null ? destination.label : '${destination.label}. $summary',
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(destination.label, maxLines: titleLines, overflow: TextOverflow.ellipsis, style: titleStyle),
              if (!compact) Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: summaryStyle),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Open a CSV export (Ctrl+O)',
          onPressed: app.isLoading ? null : onOpenCsv,
          icon: const Icon(Icons.folder_open_outlined),
        ),
        IconButton(
          tooltip: 'Settings (Ctrl+,)',
          onPressed: onSettings,
          icon: const Icon(Icons.settings_outlined),
        ),
        const SizedBox(width: 8),
      ],
    );
  }
}

class _ShellRail extends StatelessWidget {
  const _ShellRail({required this.current, required this.onSelect});

  final AppDestination current;
  final ValueChanged<AppDestination> onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      // Scrolls when the window is short or text is large (no clipping).
      return ColoredBox(
        color: cs.surfaceContainer,
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: NavigationRail(
                labelType: NavigationRailLabelType.all,
                selectedIndex: current.index,
                onDestinationSelected: (i) => onSelect(AppDestination.values[i]),
                destinations: [
                  for (final d in AppDestination.values)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: Text(d.label),
                      padding: d == AppDestination.dataSource
                          ? const EdgeInsets.only(top: 16)
                          : EdgeInsets.zero,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// All destinations in a navigation drawer: modal on narrow windows,
/// [permanent] beside the content on wide ones.
class _ShellDrawer extends StatelessWidget {
  const _ShellDrawer({required this.current, required this.onSelect, this.permanent = false});

  final AppDestination current;
  final ValueChanged<AppDestination> onSelect;
  final bool permanent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final analysis = AppDestination.values.where((d) => d.isAnalysis).toList();
    final other = AppDestination.values.where((d) => !d.isAnalysis).toList();
    return NavigationDrawer(
      selectedIndex: current.index,
      onDestinationSelected: (i) {
        if (!permanent) Navigator.of(context).pop();
        onSelect(AppDestination.values[i]);
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 12),
          child: Heading('AV Metrics Visualizer',
              level: HeadingLevel.section,
              style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onSurface)),
        ),
        for (final d in analysis)
          NavigationDrawerDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Flexible(child: Text(d.label)),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 8),
          child: Divider(),
        ),
        for (final d in other)
          NavigationDrawerDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Flexible(child: Text(d.label)),
          ),
      ],
    );
  }
}
