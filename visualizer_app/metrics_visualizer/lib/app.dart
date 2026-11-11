import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'state/navigation_state.dart';
import 'state/settings_state.dart';
import 'ui/shell.dart';
import 'ui/theme/app_theme.dart';
import 'ui/theme/chart_palette.dart';
import 'ui/theme/motion.dart';
import 'ui/widgets/focus_ring.dart';
import 'ui/widgets/keyboard_shortcuts.dart';

/// Root widget: provides state, themes, accessibility preferences and
/// keyboard shortcuts.
///
/// [appState] and [navigation] can be injected (tests); otherwise they are
/// created from [settings].
class MetricsVisualizerApp extends StatefulWidget {
  const MetricsVisualizerApp({
    super.key,
    required this.settings,
    this.appState,
    this.navigation,
  });

  final SettingsState settings;
  final AppState? appState;
  final NavigationState? navigation;

  @override
  State<MetricsVisualizerApp> createState() => _MetricsVisualizerAppState();
}

class _MetricsVisualizerAppState extends State<MetricsVisualizerApp> with WidgetsBindingObserver {
  late final AppState _app = widget.appState ?? AppState(settings: widget.settings);
  late final NavigationState _nav = widget.navigation ?? NavigationState();
  late final Map<ShortcutActivator, Intent> _shortcuts = {
    ...WidgetsApp.defaultShortcuts,
    ...buildAppShortcuts(),
  };

  /// The operating system's "reduce motion" / "animation effects off"
  /// preference. Read above MaterialApp so it also turns off things that
  /// ignore `MediaQuery.disableAnimations` (ink sparkle, theme cross-fade).
  bool _platformReducesMotion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _platformReducesMotion = _readPlatformReduceMotion();
  }

  static bool _readPlatformReduceMotion() =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  @override
  void didChangeAccessibilityFeatures() {
    final reduce = _readPlatformReduceMotion();
    if (reduce != _platformReducesMotion) setState(() => _platformReducesMotion = reduce);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.appState == null) _app.dispose();
    if (widget.navigation == null) _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<SettingsState>.value(value: widget.settings),
        ChangeNotifierProvider<AppState>.value(value: _app),
        ChangeNotifierProvider<NavigationState>.value(value: _nav),
      ],
      child: Consumer<SettingsState>(
        builder: (context, s, _) {
          final reduceMotion = s.reduceMotion || _platformReducesMotion;
          return MaterialApp(
            title: 'AV Metrics Visualizer',
            debugShowCheckedModeBanner: false,
            themeMode: s.themeMode,
            theme: AppTheme.light(highContrast: s.highContrast, reduceMotion: reduceMotion),
            darkTheme: AppTheme.dark(highContrast: s.highContrast, reduceMotion: reduceMotion),
            // Used when the OS requests high contrast (e.g. iOS "Increase
            // contrast"), independent of the in-app setting.
            highContrastTheme: AppTheme.light(highContrast: true, reduceMotion: reduceMotion),
            highContrastDarkTheme: AppTheme.dark(highContrast: true, reduceMotion: reduceMotion),
            themeAnimationDuration: reduceMotion ? Duration.zero : const Duration(milliseconds: 250),
            shortcuts: _shortcuts,
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              // Combine the system text size with the in-app multiplier and
              // keep the result in a range the layouts are tested for.
              final systemScale = mq.textScaler.scale(14) / 14;
              final scaler = TextScaler.linear(systemScale * s.textScale)
                  .clamp(minScaleFactor: 1.0, maxScaleFactor: 3.0);
              final reduce = reduceMotion || mq.disableAnimations;
              return MediaQuery(
                data: mq.copyWith(textScaler: scaler, disableAnimations: reduce),
                child: MotionPreferences(
                  reduceMotion: reduceMotion,
                  child: ChartStyleScope(
                    kind: s.palette,
                    patterns: s.showChartPatterns,
                    highContrast: s.highContrast || mq.highContrast,
                    child: FocusRingOverlay(child: child ?? const SizedBox.shrink()),
                  ),
                ),
              );
            },
            home: const AppShell(),
          );
        },
      ),
    );
  }
}
