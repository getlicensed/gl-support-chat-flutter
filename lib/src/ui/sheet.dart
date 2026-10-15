import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'common.dart';

// The messenger's sheet, our own on every platform (not CupertinoSheetRoute,
// which would put the apps on Flutter 3.29): it rises over the app with its
// top corners rounded, leaves a strip of the app showing above it under a
// scrim, and goes when dragged down. The screens opened inside it (a
// conversation, an article) are routes of their own, framed the same way,
// so they slide in within the sheet and ride up and down with it.

/// How long the sheet takes to come up, and its curve: Material's
/// emphasised deceleration — most of the way in the first third, then it
/// settles.
const messengerOpenTime = Duration(milliseconds: 400);
const messengerOpenCurve = Cubic(0.05, 0.7, 0.1, 1);

/// How long it takes to go down, and its curve: Material's emphasised
/// acceleration, as a time curve — it leaves gently and is quickly gone.
const messengerCloseTime = Duration(milliseconds: 250);
const messengerCloseCurve = Cubic(0.3, 0, 0.8, 0.15);

/// Behind the sheet: the app, dimmed.
const messengerScrim = Color(0x66000000);

/// The strip of the app left showing above the sheet, under the status bar.
const sheetGap = 10.0;

/// A drag down past this share of the sheet's height closes it…
const sheetCloseShare = 0.25;

/// …and so does a flick down faster than this, in logical pixels a second.
const sheetCloseSpeed = 700.0;

/// The top corners: iOS's sheets are rounded 12, Material's 16.
double sheetRadius(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS ? 12 : 16;

/// One open messenger: where its sheet is, and the drag that moves it. Every
/// screen of the messenger follows [shown].
class MessengerSheet {
  MessengerSheet._(this._route);

  final MessengerSheetRoute _route;

  /// How far up the sheet is drawn: 0 off the bottom of the screen, 1 up.
  /// A notifier of its own, not the route's animation: a screen opened in
  /// the sheet can outlive the sheet's route by a frame or two as they all
  /// close together. Never disposed for the same reason; it holds nothing.
  final ValueNotifier<double> shown = ValueNotifier<double>(0);

  /// Every screen of the messenger is closing at once (Close, or a drag
  /// down): the screens opened in the sheet go down with it rather than
  /// sliding away on their own.
  bool closingAll = false;

  /// The sheet's height at the last layout.
  double height = 0;

  /// The phone asks for less motion: a released drag lands at once.
  bool still = false;

  /// A drag is in hand or its release is settling: the sheet follows the
  /// route's animation one to one, not through the curves, and the
  /// navigator knows a gesture is under way.
  bool _dragging = false;
  NavigatorState? _gestureOn;

  /// The drag a finger holds now (its number), or null once let go.
  int? _held;
  int _drags = 0;

  /// Waiting for a released drag to settle.
  AnimationStatusListener? _settling;

  /// The lists inside the sheet: pulled down from their top, they move the
  /// sheet instead (see [_SheetScrollPosition]).
  late final ScrollController scroll = _SheetScroll(this);

  static MessengerSheet? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<_SheetScope>()?.sheet;

  /// [page] as a screen of this sheet: it can find the sheet, and its lists
  /// pull the sheet down.
  Widget wrap(Widget page) => _SheetScope(sheet: this, child: PrimaryScrollController(controller: scroll, child: page));

  void _update(double linear, double curved) => shown.value = _dragging ? linear : curved;

  AnimationController? get _controller => _route.sheetController;

  /// A finger has started to move the sheet: the drag's number, for the
  /// calls that follow, or null when it cannot (closing, or gone). A
  /// finger can take the sheet again while a release settles.
  int? dragStart() {
    final c = _controller;
    if (c == null || !_route.isActive || closingAll) return null;
    if (!_dragging && c.status == AnimationStatus.reverse) return null;
    final settling = _settling;
    if (settling != null) {
      c.removeStatusListener(settling);
      _settling = null;
    }
    c.stop();
    if (!_dragging) {
      // From where it is drawn: mid-way up, the curve and the finger differ.
      _dragging = true;
      c.value = shown.value;
      final navigator = _route.navigator;
      navigator?.didStartUserGesture();
      _gestureOn = navigator;
    }
    return _held = ++_drags;
  }

  /// Drag [drag]'s finger moved [dy] (down positive). What it could not
  /// use — the sheet is all the way up and the finger goes on up — is
  /// returned, for the list under it to scroll.
  double dragBy(int drag, double dy) {
    final c = _controller;
    if (_held != drag || c == null) return dy;
    final h = height > 0 ? height : 1.0;
    final want = c.value - dy / h;
    c.value = want.clamp(0.0, 1.0);
    return want > 1 ? -(want - 1) * h : 0;
  }

  /// Drag [drag]'s finger let go at [velocity] (logical pixels a second,
  /// down positive): past a quarter of the way down, or flicked down, the
  /// whole messenger closes; otherwise the sheet springs back up.
  void dragEnd(int drag, double velocity) {
    if (_held != drag) return;
    _held = null;
    _release(velocity);
  }

  /// What held drag [drag] has gone mid-drag (its list or screen replaced,
  /// a sign-out under the finger), without a word of its end: the sheet
  /// springs back, after this frame — the tree is locked while it goes.
  void dragAbandoned(int drag) {
    if (_held != drag) return;
    _held = null;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        if (_held == null && _dragging && _settling == null) _release(0, mayClose: false);
      })
      ..ensureVisualUpdate();
  }

  void _release(double velocity, {bool mayClose = true}) {
    final c = _controller;
    if (c == null || !_dragging) return;
    final h = height > 0 ? height : 1.0;
    // Popped under the finger (Android's back): it can only go down.
    final popped = !_route.isActive;
    final close = popped || (mayClose && (velocity > sheetCloseSpeed || (velocity >= -sheetCloseSpeed && c.value < 1 - sheetCloseShare)));
    if (close) {
      if (!popped) {
        closingAll = true;
        _route.navigator?.popUntil((r) => !(r.settings.name ?? '').startsWith(messengerRoutePrefix));
      }
      // The pop started the close from where the finger left it; it goes
      // on at the finger's speed instead of starting slow again.
      if (still) {
        c.value = 0;
      } else {
        c.fling(velocity: -math.max(1.0, velocity / h));
      }
    } else if (still) {
      c.value = 1;
    } else {
      c.fling(velocity: math.max(1.0, -velocity / h));
    }
    if (!c.isAnimating) {
      _stopGesture();
      return;
    }
    void settled(AnimationStatus status) {
      if (status != AnimationStatus.completed && status != AnimationStatus.dismissed) return;
      c.removeStatusListener(settled);
      if (identical(_settling, settled)) _settling = null;
      _stopGesture();
    }

    _settling = settled;
    c.addStatusListener(settled);
  }

  void _stopGesture() {
    _dragging = false;
    final navigator = _gestureOn;
    _gestureOn = null;
    if (navigator != null && navigator.mounted) navigator.didStopUserGesture();
  }

  void _routeGone() {
    _held = null;
    _settling = null;
    if (_dragging) _stopGesture();
    (scroll as _SheetScroll)._routeGone();
  }
}

class _SheetScope extends InheritedWidget {
  const _SheetScope({required this.sheet, required super.child});
  final MessengerSheet sheet;

  @override
  bool updateShouldNotify(_SheetScope old) => !identical(old.sheet, sheet);
}

/// The messenger's own route: the sheet. It comes up in [messengerOpenTime]
/// on [messengerOpenCurve] and goes down in [messengerCloseTime] on
/// [messengerCloseCurve]; with [reduceMotion] it is simply there, and gone.
class MessengerSheetRoute extends PageRoute<void> {
  MessengerSheetRoute({required this.page, required this.reduceMotion}) : super(settings: const RouteSettings(name: messengerRoutePrefix));

  final Widget page;
  final bool reduceMotion;
  late final MessengerSheet sheet = MessengerSheet._(this);
  CurvedAnimation? _curve;

  AnimationController? get sheetController => controller;

  @override
  Duration get transitionDuration => reduceMotion ? Duration.zero : messengerOpenTime;

  @override
  Duration get reverseTransitionDuration => reduceMotion ? Duration.zero : messengerCloseTime;

  @override
  bool get opaque => false;

  @override
  Color? get barrierColor => messengerScrim;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  AnimationController createAnimationController() {
    final c = super.createAnimationController();
    // The close curve is a time curve; played backwards it is flipped.
    _curve = CurvedAnimation(parent: c, curve: messengerOpenCurve, reverseCurve: messengerCloseCurve.flipped);
    c.addListener(() => sheet._update(c.value, _curve!.value));
    return c;
  }

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => sheet.wrap(page);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    sheet.still = reduceMotion || MediaQuery.disableAnimationsOf(context);
    return MessengerSheetFrame(sheet: sheet, child: child);
  }

  @override
  void dispose() {
    _curve?.dispose();
    sheet._routeGone();
    super.dispose();
  }
}

/// Where a messenger screen is drawn: below the status bar and a [sheetGap],
/// rounded at the top, as far up as the sheet is, and draggable down. The
/// screen inside has no status bar to keep clear of.
class MessengerSheetFrame extends StatefulWidget {
  const MessengerSheetFrame({super.key, required this.sheet, required this.child});

  final MessengerSheet sheet;
  final Widget child;

  @override
  State<MessengerSheetFrame> createState() => _MessengerSheetFrameState();
}

class _MessengerSheetFrameState extends State<MessengerSheetFrame> {
  /// The drag this frame's own detector holds.
  int? _drag;

  @override
  void dispose() {
    final drag = _drag;
    if (drag != null) widget.sheet.dragAbandoned(drag);
    super.dispose();
  }

  void _end(double velocity) {
    final drag = _drag;
    _drag = null;
    if (drag != null) widget.sheet.dragEnd(drag, velocity);
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final top = MediaQuery.paddingOf(context).top + sheetGap;
    final radius = sheetRadius(Theme.of(context).platform);
    final inside = ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: GestureDetector(
          // A drag the screen does not take itself (a list that can scroll
          // takes its own): the sheet follows the finger.
          onVerticalDragStart: (_) => _drag = sheet.dragStart(),
          onVerticalDragUpdate: (d) {
            final drag = _drag;
            if (drag != null) sheet.dragBy(drag, d.primaryDelta ?? 0);
          },
          onVerticalDragEnd: (d) => _end(d.primaryVelocity ?? 0),
          onVerticalDragCancel: () => _end(0),
          child: widget.child,
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: LayoutBuilder(builder: (context, box) {
        sheet.height = box.maxHeight;
        return ValueListenableBuilder<double>(
          valueListenable: sheet.shown,
          child: inside,
          builder: (context, shown, child) => Transform.translate(offset: Offset(0, (1 - shown) * box.maxHeight), child: child),
        );
      }),
    );
  }
}

/// A screen of the messenger opened on top of another — a conversation, an
/// article. In a sheet it is drawn in the sheet's frame, see-through around
/// it, so it slides in within the sheet and goes up and down with it; when
/// the whole messenger closes it goes down with the sheet instead of
/// sliding away. [instant]: it is simply there (the sheet is still rising
/// with it). An iPhone gets the Cupertino route whatever the app's theme
/// chose, so a swipe from the left edge steps back.
Route<void> messengerPageRoute({
  required RouteSettings settings,
  required WidgetBuilder builder,
  required bool cupertino,
  MessengerSheet? sheet,
  bool instant = false,
}) =>
    cupertino
        ? _CupertinoMessengerRoute(settings: settings, builder: builder, sheet: sheet, instant: instant)
        : _MaterialMessengerRoute(settings: settings, builder: builder, sheet: sheet, instant: instant);

mixin _InSheet on PageRoute<void> {
  MessengerSheet? get sheet;
  bool get instant;

  @override
  bool get opaque => sheet == null;

  /// The shade a Cupertino push lays over the page beneath would also darken
  /// the strip above the sheet.
  @override
  Color? get barrierColor => sheet == null ? super.barrierColor : null;

  @override
  Duration get transitionDuration => instant ? Duration.zero : super.transitionDuration;

  /// Back from a screen that came at once slides as usual.
  @override
  Duration get reverseTransitionDuration => instant ? super.transitionDuration : super.reverseTransitionDuration;

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final s = sheet;
    if (s == null) return super.buildTransitions(context, animation, secondaryAnimation, child);
    final moving = super.buildTransitions(context, s.closingAll ? kAlwaysCompleteAnimation : animation, secondaryAnimation, child);
    return MessengerSheetFrame(sheet: s, child: moving);
  }
}

// On the transition mixins rather than CupertinoPageRoute and
// MaterialPageRoute themselves, whose constructors insist on being opaque.
class _CupertinoMessengerRoute extends PageRoute<void> with CupertinoRouteTransitionMixin<void>, _InSheet {
  _CupertinoMessengerRoute({required super.settings, required this.builder, this.sheet, this.instant = false});

  final WidgetBuilder builder;
  @override
  final MessengerSheet? sheet;
  @override
  final bool instant;

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  String? get title => null;

  @override
  bool get maintainState => true;
}

class _MaterialMessengerRoute extends PageRoute<void> with MaterialRouteTransitionMixin<void>, _InSheet {
  _MaterialMessengerRoute({required super.settings, required this.builder, this.sheet, this.instant = false});

  final WidgetBuilder builder;
  @override
  final MessengerSheet? sheet;
  @override
  final bool instant;

  @override
  Widget buildContent(BuildContext context) => builder(context);

  @override
  bool get maintainState => true;
}

/// The primary scroll controller of the screens in a sheet.
class _SheetScroll extends ScrollController {
  _SheetScroll(this.sheet);
  final MessengerSheet sheet;
  bool _orphaned = false;

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) =>
      _SheetScrollPosition(sheet, physics: physics, context: context, oldPosition: oldPosition);

  /// The sheet's route has gone; a screen of it may still be on its way
  /// out, with its list still attached. The last one to go disposes this.
  void _routeGone() {
    if (hasClients) {
      _orphaned = true;
    } else {
      dispose();
    }
  }

  @override
  void detach(ScrollPosition position) {
    super.detach(position);
    if (_orphaned && !hasClients) {
      _orphaned = false;
      dispose();
    }
  }
}

/// A list in the sheet. Pulled down from its top, it moves the sheet rather
/// than stretch or glow; pushed back up, the sheet goes back up first and
/// then the list scrolls. Released, the sheet closes or springs back as a
/// drag on the sheet does. As the bottom sheets of Flutter's own
/// DraggableScrollableSheet do it.
class _SheetScrollPosition extends ScrollPositionWithSingleContext {
  _SheetScrollPosition(this.sheet, {required super.physics, required super.context, super.oldPosition});

  final MessengerSheet sheet;

  /// The sheet's drag this list holds while it is pulled.
  int? _pull;

  @override
  void applyUserOffset(double delta) {
    // A list from the top down only (the thread runs from the bottom up,
    // and keeps its own controller).
    if (_pull == null && delta > 0 && axisDirection == AxisDirection.down && pixels <= minScrollExtent) {
      _pull = sheet.dragStart();
    }
    final pull = _pull;
    if (pull == null) {
      super.applyUserOffset(delta);
      return;
    }
    final rest = sheet.dragBy(pull, delta);
    if (rest < 0) {
      // Back up at the top: the list takes the rest.
      _pull = null;
      sheet.dragEnd(pull, 0);
      super.applyUserOffset(rest);
    }
  }

  @override
  void goBallistic(double velocity) {
    final pull = _pull;
    if (pull != null) {
      _pull = null;
      // The scroll velocity runs against the finger's.
      sheet.dragEnd(pull, -velocity);
      super.goBallistic(0);
      return;
    }
    super.goBallistic(velocity);
  }

  @override
  void dispose() {
    // Gone under the finger (Home replaced by a sign-in, say): the sheet
    // must not be left held, half down.
    final pull = _pull;
    _pull = null;
    if (pull != null) sheet.dragAbandoned(pull);
    super.dispose();
  }
}
