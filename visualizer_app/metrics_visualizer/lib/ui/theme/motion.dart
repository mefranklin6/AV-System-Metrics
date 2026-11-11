import 'package:flutter/widgets.dart';

/// Central place for animation timing. EVERY animation in the app must take
/// its duration from here so "reduce motion" turns it off.
///
/// Motion is reduced when either the in-app setting is on (provided by
/// [MotionPreferences], inserted by the app root) or the platform asks for it
/// (`MediaQuery.disableAnimations`, e.g. Windows "Animation effects" off,
/// macOS "Reduce motion", Android "Remove animations").
///
/// ```dart
/// AnimatedOpacity(
///   duration: Motion.of(context).medium,
///   curve: Motion.of(context).curve,
///   ...
/// )
/// ```
class Motion {
  const Motion._(this.reduced);

  /// True when animations must not run.
  final bool reduced;

  static const Duration _short = Duration(milliseconds: 150);
  static const Duration _medium = Duration(milliseconds: 300);
  static const Duration _long = Duration(milliseconds: 500);
  static const Duration _chart = Duration(milliseconds: 700);

  /// Small state changes (hover, toggles, chips).
  Duration get short => reduced ? Duration.zero : _short;

  /// Page and panel transitions, AnimatedSwitcher between states.
  Duration get medium => reduced ? Duration.zero : _medium;

  /// Larger layout changes.
  Duration get long => reduced ? Duration.zero : _long;

  /// Chart entrance / data change animations.
  Duration get chart => reduced ? Duration.zero : _chart;

  /// Scales any custom [normal] duration to zero when reduced.
  Duration duration(Duration normal) => reduced ? Duration.zero : normal;

  /// Standard easing (Material 3 emphasized decelerate).
  Curve get curve => Curves.easeOutCubic;

  /// Whether motion is reduced for [context].
  static bool isReduced(BuildContext context) {
    final setting = MotionPreferences.maybeOf(context)?.reduceMotion ?? false;
    final platform = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return setting || platform;
  }

  /// Motion timing for [context]. Registers a dependency, so widgets rebuild
  /// when the setting changes.
  static Motion of(BuildContext context) => Motion._(isReduced(context));

  /// Fixed instances for tests and non-widget code.
  static const Motion normal = Motion._(false);
  static const Motion none = Motion._(true);
}

/// Carries the user's "Reduce motion" setting down the tree. Inserted by the
/// app root; read through [Motion.of].
class MotionPreferences extends InheritedWidget {
  const MotionPreferences({
    super.key,
    required this.reduceMotion,
    required super.child,
  });

  final bool reduceMotion;

  static MotionPreferences? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MotionPreferences>();

  @override
  bool updateShouldNotify(MotionPreferences oldWidget) =>
      oldWidget.reduceMotion != reduceMotion;
}
