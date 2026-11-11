import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../theme/app_theme.dart';

/// Draws a high-contrast keyboard focus ring around whichever control has
/// keyboard focus (WCAG 2.4.7 Focus Visible, 1.4.11 Non-text Contrast).
///
/// Many Material components only show a translucent focus tint (list tiles,
/// switch/checkbox/radio list tiles, InkWell cards, data-table sort headers,
/// navigation destinations, dropdown buttons), and some put their control
/// behind `ExcludeFocus`, so a theme outline never draws. Instead of
/// patching each one, the app root inserts this overlay. While the user
/// navigates with the keyboard ([FocusHighlightMode.traditional]) it paints
/// a two-tone ring around the focused control: a 3 px ring in
/// [AppTheme.focusRing] with a 1 px halo in the contrasting surface colour
/// on both sides. Whatever colour is next to the ring, one of the two tones
/// reaches at least 3:1 against it.
///
/// Controls that already draw the theme's 3 px focus outline (buttons, icon
/// buttons, menu items, segmented buttons, chips, text fields, checkboxes,
/// switches) are skipped, as is anything under [NoFocusRing] and any node
/// passed to [FocusRingOverlay.ignore].
class FocusRingOverlay extends StatefulWidget {
  const FocusRingOverlay({super.key, required this.child});

  final Widget child;

  static final Expando<bool> _ignored = Expando<bool>('FocusRingOverlay.ignored');

  /// Never draw a ring for [node] (e.g. a root focus node that only exists
  /// to receive shortcuts).
  static void ignore(FocusNode node) => _ignored[node] = true;

  /// Width of the main ring.
  static const double ringWidth = 3;

  /// Width of the contrasting halo on each side of the ring.
  static const double haloWidth = 1;

  /// Gap between the control and the inner halo.
  static const double gap = 1;

  /// The ring's rectangle (relative to the overlay) in the most recently
  /// created overlay, or null when no ring is shown. For tests.
  @visibleForTesting
  static Rect? get debugRingRect => _FocusRingOverlayState._last?._rect;

  @override
  State<FocusRingOverlay> createState() => _FocusRingOverlayState();
}

/// Marks a subtree whose controls draw their own focus indicator, so the
/// [FocusRingOverlay] does not add a second ring.
class NoFocusRing extends InheritedWidget {
  const NoFocusRing({super.key, required super.child});

  @override
  bool updateShouldNotify(NoFocusRing oldWidget) => false;
}

class _FocusRingOverlayState extends State<FocusRingOverlay> {
  static _FocusRingOverlayState? _last;

  final GlobalKey _stackKey = GlobalKey();
  Rect? _rect;
  bool _disposed = false;
  bool _checkScheduled = false;

  @override
  void initState() {
    super.initState();
    _last = this;
    FocusManager.instance.addListener(_scheduleCheck);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
    // Re-measure after every frame so the ring follows scrolling, layout
    // changes and page transitions. It only rebuilds when the rectangle
    // actually changes, so the app still settles.
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      if (!_disposed) _scheduleCheck();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_last, this)) _last = null;
    FocusManager.instance.removeListener(_scheduleCheck);
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    super.dispose();
  }

  void _onHighlightMode(FocusHighlightMode _) => _scheduleCheck();

  void _scheduleCheck() {
    if (_disposed || _checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (_disposed || !mounted) return;
      final rect = _measure();
      if (rect != _rect) setState(() => _rect = rect);
    });
    // Make sure a frame runs even when the trigger was not a frame.
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  static bool _drawsOwnRing(Widget w) =>
      w is ButtonStyleButton || w is EditableText || w is RawChip || w is Checkbox || w is Switch;

  Rect? _measure() {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) return null;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode || _ignoredNode(node)) return null;
    final ctx = node.context;
    if (ctx == null || !ctx.mounted) return null;
    if (ctx.getInheritedWidgetOfExactType<NoFocusRing>() != null) return null;
    // Walk up to the control that owns this focus node. Stop at the next
    // focus boundary: anything above it is a different control.
    var ownRing = false;
    var depth = 0;
    ctx.visitAncestorElements((e) {
      final w = e.widget;
      if (_drawsOwnRing(w)) {
        ownRing = true;
        return false;
      }
      if (w is Focus) return false;
      return ++depth < 100;
    });
    if (ownRing) return null;

    final target = ctx.findRenderObject();
    final stack = _stackKey.currentContext?.findRenderObject();
    if (target is! RenderBox || stack is! RenderBox) return null;
    if (!target.attached || !target.hasSize || !stack.attached || !stack.hasSize) return null;
    Rect toStack(RenderBox box) => MatrixUtils.transformRect(box.getTransformTo(stack), Offset.zero & box.size);
    var rect = toStack(target);
    // Mid-transition transforms (e.g. a zero scale) can be degenerate.
    if (!rect.isFinite) return null;

    // Clip to every enclosing scroll viewport so the ring never draws over
    // the app bar or the filter bar when the control is partly scrolled out.
    var clip = Offset.zero & stack.size;
    ScrollableState? scrollable = ctx.findAncestorStateOfType<ScrollableState>();
    while (scrollable != null) {
      final box = scrollable.context.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) {
        final r = toStack(box);
        if (!r.isFinite) return null;
        clip = clip.intersect(r);
      }
      scrollable = scrollable.context.findAncestorStateOfType<ScrollableState>();
    }
    if (rect.isEmpty || clip.isEmpty) return null;
    final visible = rect.intersect(clip);
    if (visible.width <= 0 || visible.height <= 0) return null;
    // A focus node that fills the whole window (e.g. a root shortcut scope)
    // is not a control: no ring.
    if (rect.width >= stack.size.width - 1 && rect.height >= stack.size.height - 1) return null;
    const inset = FocusRingOverlay.gap + FocusRingOverlay.haloWidth * 2 + FocusRingOverlay.ringWidth;
    // Keep the ring inside the clip area so it is never cut off on one side
    // only when it would fit.
    rect = rect.inflate(inset);
    final c = clip;
    rect = Rect.fromLTRB(
      rect.left < c.left ? c.left : rect.left,
      rect.top < c.top ? c.top : rect.top,
      rect.right > c.right ? c.right : rect.right,
      rect.bottom > c.bottom ? c.bottom : rect.bottom,
    );
    return rect;
  }

  static bool _ignoredNode(FocusNode node) => FocusRingOverlay._ignored[node] ?? false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Stack(
      key: _stackKey,
      children: [
        widget.child,
        if (_rect != null)
          Positioned.fill(
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: CustomPaint(
                  key: const ValueKey('focus-ring'),
                  painter: _RingPainter(rect: _rect!, ring: AppTheme.focusRing(cs), halo: AppTheme.focusHalo(cs)),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.rect, required this.ring, required this.halo});

  final Rect rect;
  final Color ring;
  final Color halo;

  @override
  void paint(Canvas canvas, Size size) {
    const h = FocusRingOverlay.haloWidth, w = FocusRingOverlay.ringWidth;
    // Outer halo, ring, inner halo, from the outside in.
    final outer = RRect.fromRectAndRadius(rect.deflate(h / 2), const Radius.circular(10));
    final middle = RRect.fromRectAndRadius(rect.deflate(h + w / 2), const Radius.circular(9));
    final inner = RRect.fromRectAndRadius(rect.deflate(h + w + h / 2), const Radius.circular(8));
    final haloPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = h
      ..color = halo;
    canvas.drawRRect(outer, haloPaint);
    canvas.drawRRect(inner, haloPaint);
    canvas.drawRRect(
      middle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = ring,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.rect != rect || old.ring != ring || old.halo != halo;
}
