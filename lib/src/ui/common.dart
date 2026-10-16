import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../core/controller.dart';
import '../core/format.dart';
import '../fallback.dart';
import '../launcher.dart';
import 'sheet.dart';

/// The messenger's routes are named under this, so "close" can pop all of
/// them at once and land back on the app's own screen.
const messengerRoutePrefix = 'gl_support_chat';

/// What every messenger screen needs: the controller, the app's fallback
/// contacts, and how to reach the API for pictures.
class MessengerScope extends InheritedNotifier<Listenable> {
  /// [changes]: when the screens below are told the controller changed —
  /// every time it does, unless given (see the messenger page's tabs).
  const MessengerScope({super.key, required this.controller, required this.fallback, Listenable? changes, required super.child})
      : super(notifier: changes ?? controller);

  final MessengerController controller;
  final GLSupportChatFallback fallback;

  /// The scope; the widget asking is rebuilt whenever the controller
  /// changes — except below a [QuietScope], where it is only read.
  static MessengerScope of(BuildContext context) {
    final quiet = context.getInheritedWidgetOfExactType<QuietScope>() != null;
    final scope = quiet ? context.getInheritedWidgetOfExactType<MessengerScope>() : context.dependOnInheritedWidgetOfExactType<MessengerScope>();
    assert(scope != null, 'A messenger screen outside MessengerScope');
    return scope!;
  }

  /// The controller, read without being rebuilt when it changes: for a
  /// widget that listens for what it shows itself ([MessengerSelector]), or
  /// that only acts on it.
  static MessengerController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<MessengerScope>();
    assert(scope != null, 'A messenger screen outside MessengerScope');
    return scope!.controller;
  }

}

extension MessengerContext on BuildContext {
  MessengerController get messenger => MessengerScope.of(this).controller;
  BrandColors get brand => MessengerScope.of(this).controller.brand;
}

/// Below this, [MessengerContext] reads the controller without subscribing
/// to it: the thread's rows. The controller tells its listeners of every
/// change — an AI answer typing out, 13 times a second; a teammate typing;
/// someone coming online — and every row that had asked it for the brand
/// colour was rebuilt each time. A row is now rebuilt by the thread, when
/// its own message changes; what a row shows that changes on its own (a
/// face chosen, a button busy) listens for that alone ([MessengerSelector]).
class QuietScope extends InheritedWidget {
  const QuietScope({super.key, required super.child});

  @override
  bool updateShouldNotify(QuietScope oldWidget) => false;
}

/// A part of a screen rebuilt when what [select] takes from the controller
/// changes, and only then: not for everything else the controller does, and
/// without rebuilding the rest of the screen. [select] returns a value that
/// compares equal while nothing it shows has changed (a record of them).
///
/// What [builder] builds is in a [QuietScope]: it reads the controller and
/// is rebuilt with this, so [select] names everything it shows.
class MessengerSelector<T> extends StatefulWidget {
  const MessengerSelector({super.key, required this.select, required this.builder});

  final T Function(MessengerController c) select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<MessengerSelector<T>> createState() => _MessengerSelectorState<T>();
}

class _MessengerSelectorState<T> extends State<MessengerSelector<T>> {
  MessengerController? _c;
  late T _value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = MessengerScope.read(context);
    if (identical(c, _c)) return;
    _c?.removeListener(_changed);
    _c = c..addListener(_changed);
    _value = widget.select(c);
  }

  @override
  void didUpdateWidget(MessengerSelector<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The same screen given another customer's controller: listen to that one.
    final c = MessengerScope.read(context);
    if (!identical(c, _c)) {
      _c?.removeListener(_changed);
      _c = c..addListener(_changed);
    }
    _value = widget.select(c);
  }

  @override
  void dispose() {
    _c?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final value = widget.select(_c!);
    if (value == _value) return;
    setState(() => _value = value);
  }

  @override
  Widget build(BuildContext context) => QuietScope(child: Builder(builder: (context) => widget.builder(context, _value)));
}

/// Neutral colours, the website messenger's, darkened where they read
/// under their WCAG target on the phone (0.4.9; test/contrast_test.dart).
class Palette {
  static const text = Color(0xFF111827);
  static const prose = Color(0xFF1F2937);
  static const body = Color(0xFF374151);
  /// Names, times, ticks and other small print: 4.8:1 on white.
  static const muted = Color(0xFF6B7280);

  /// Placeholder text in a field: at least 5:1 on every fill the messenger
  /// uses (the help search's grey too), so it reads in sunlight.
  static const hint = Color(0xFF5F6673);

  /// Decoration only (the typing dots), never words: 2.5:1 on white.
  static const faint = Color(0xFF9CA3AF);
  /// Dividers and cards: decoration, not the edge of something to use.
  static const border = Color(0xFFE5E7EB);

  /// The edge of a field to type in: 3.3:1 on white, 3.2:1 on [input], so
  /// the box can be found (WCAG 1.4.11). [border] was 1.2:1.
  static const field = Color(0xFF878E99);
  static const fill = Color(0xFFF3F4F6);
  static const page = Color(0xFFF5F6F7);
  static const input = Color(0xFFF9FAFB);
  /// The team's bubbles: a shade darker than 0.4.8's (1.12:1 on the white
  /// thread, which washed out in daylight), with [bubbleEdge] round it.
  static const agentBubble = Color(0xFFE9EBEE);

  /// A hairline round the team's bubbles, so each reads as a shape.
  static const bubbleEdge = Color(0xFFD5D9DF);

  /// Unread dots, the tab's count, "New messages": white reads on it, and
  /// it reads on white, at 4.8:1 (0.4.8's red was 3.8:1).
  static const danger = Color(0xFFDC2626);
  static const error = Color(0xFFB91C1C);

  /// "We'll follow up at…": 5.5:1 on white (0.4.8's green was 3.8:1).
  static const success = Color(0xFF047857);
  static const online = Color(0xFF34D399);
  static const away = Color(0xFF9CA3AF);
  static const whatsapp = Color(0xFF25D366);
  /// WhatsApp's own dark green, for words: 7.7:1 on white (its teal was 4.1:1).
  static const whatsappText = Color(0xFF075E54);
}

/// The messenger's own theme, so the app's theme cannot restyle it.
///
/// Built fresh rather than copied from the app's: the screens are white, and
/// an app that follows the phone's dark mode would otherwise bring its light
/// text and dark fields with it (typed text vanished on white). Only the
/// app's typeface and sizes come across, in the messenger's own ink.
///
/// Ink is the platform's: on Android a ripple, InkRipple — not Material 3's
/// sparkle, whose shader is compiled the first time it is drawn, a dropped
/// frame on the first tap; on iOS no ripple (iOS controls do not ripple).
///
/// The theme's primary is the brand's [BrandColors.ink], which reads on
/// white at 4.5:1 (a text button's words, a spinner); a button that has the
/// keyboard's focus is ringed in it (Flutter's own focus tint was 1.3:1).
ThemeData messengerTheme(BuildContext context, BrandColors brand) {
  final host = Theme.of(context);
  final cached = _themeCache;
  // The controller notifies many times a second while an AI answer types
  // out; the same theme object then rebuilds nothing below it.
  if (cached != null && identical(cached.host, host) && cached.brand == brand.hex) return cached.theme;
  final ios = host.platform == TargetPlatform.iOS || host.platform == TargetPlatform.macOS;
  final theme = ThemeData(
    splashFactory: ios ? NoSplash.splashFactory : InkRipple.splashFactory,
    useMaterial3: host.useMaterial3,
    colorScheme: ColorScheme.fromSeed(
      seedColor: brand.primary,
      primary: brand.ink,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: Palette.text,
      brightness: Brightness.light,
    ),
    textTheme: host.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
    platform: host.platform,
    visualDensity: host.visualDensity,
    scaffoldBackgroundColor: Colors.white,
    canvasColor: Colors.white,
    textSelectionTheme: TextSelectionThemeData(cursorColor: brand.ink, selectionHandleColor: brand.ink),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: brand.primary),
    inputDecorationTheme: const InputDecorationTheme(hintStyle: TextStyle(color: Palette.hint)),
    filledButtonTheme: FilledButtonThemeData(style: ButtonStyle(side: focusRing(brand))),
    textButtonTheme: TextButtonThemeData(style: ButtonStyle(side: focusRing(brand))),
  );
  _themeCache = (host: host, brand: brand.hex, theme: theme);
  return theme;
}

({ThemeData host, String brand, ThemeData theme})? _themeCache;

/// A button's line while the keyboard's focus is on it: 2 points of the
/// brand's ink, 4.5:1 on white or more; none otherwise.
WidgetStateProperty<BorderSide?> focusRing(BrandColors brand) =>
    WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.focused) ? BorderSide(color: brand.ink, width: 2) : null);

/// A field's line: [Palette.field] at rest, the brand's ink with the
/// keyboard in it, rounded [radius].
({InputBorder rest, InputBorder focused}) fieldBorders(BrandColors brand, double radius) => (
      rest: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: const BorderSide(color: Palette.field)),
      focused: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: brand.ink, width: 1.5)),
    );

/// What every text field in the messenger types in: the messenger's ink,
/// whatever the app's theme says.
const fieldText = TextStyle(color: Palette.text);

/// A tap outside the field that has the keyboard: the keyboard goes. On a
/// phone Flutter leaves it up by default, with no other way to close it.
void dismissKeyboard(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

/// The status bar over a messenger screen: dark icons over a light header,
/// light icons over a dark one, and no colour of its own so the header shows
/// through.
SystemUiOverlayStyle statusBarStyle({required bool darkIcons}) => SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      // Android reads the icons' brightness; iOS the brightness behind them.
      statusBarIconBrightness: darkIcons ? Brightness.dark : Brightness.light,
      statusBarBrightness: darkIcons ? Brightness.light : Brightness.dark,
    );

/// The status bar over the brand colour: the icons follow the text on it.
SystemUiOverlayStyle statusBarOnBrand(BrandColors brand) => statusBarStyle(darkIcons: brand.onPrimary != Colors.white);

/// Pop every messenger screen: back to the app. In the sheet they all go
/// down with it, rather than each leaving its own way at once.
void closeMessenger(BuildContext context) {
  MessengerSheet.maybeOf(context)?.closingAll = true;
  Navigator.of(context).popUntil((route) => !(route.settings.name ?? '').startsWith(messengerRoutePrefix));
}

/// Open a link outside the messenger; a short note if nothing on the phone can.
Future<void> openExternal(BuildContext context, Uri uri) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (await launchExternal(uri.toString())) return;
  messenger?.showSnackBar(const SnackBar(content: Text("Couldn't open that link on this phone.")));
}

/// Something to tap, with the platform's feedback under the finger.
///
/// iOS: no ripple (iOS controls do not ripple) but a highlight over the
/// shape — black 8% on white, white 15% on the brand colour — in over
/// 100 ms from the touch and out over 200 ms after; InkWell's own takes
/// 200 ms to come, half a quick tap. Drawn over what it covers, it shows on
/// any box. Android: Material's ripple (InkRipple, see [messengerTheme]),
/// tinted with the brand colour, or white on it; it is drawn on the
/// Material below, so no opaque box may sit between the two.
///
/// One gesture recogniser for the whole of it: feedback never waits for a
/// second one on the same spot to give up.
///
/// With the keyboard's focus on it (a keyboard, Switch Access) it is ringed
/// in the brand's ink, 2 points (white on the brand colour): 3:1 or more
/// against what is round it, where Flutter's own focus tint was 1.3:1.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.onTap, required this.child, this.shape = const RoundedRectangleBorder(), this.onBrand = false, this.inner});

  final VoidCallback? onTap;
  final Widget child;

  /// The highlight's and the ripple's shape: the shape of what is tapped.
  final ShapeBorder shape;

  /// On the brand colour: white feedback.
  final bool onBrand;

  /// The ink's size, centred in a larger touch target (a 32-point circle
  /// in a 44-point square); null: the whole of it.
  final Size? inner;

  static const highlightIn = Duration(milliseconds: 100);
  static const highlightOut = Duration(milliseconds: 200);

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  // Its whole time even with less motion asked for: see [fullTime].
  late final AnimationController _down = AnimationController(
    vsync: this,
    duration: Pressable.highlightIn,
    reverseDuration: Pressable.highlightOut,
    animationBehavior: AnimationBehavior.preserve,
  );

  /// The keyboard's focus is on it.
  bool _focused = false;

  @override
  void dispose() {
    _down.dispose();
    super.dispose();
  }

  void _focus(bool focused) {
    if (focused != _focused && mounted) setState(() => _focused = focused);
  }

  /// Down: from where it is, or a frame in — the finger came down before
  /// the frame that first draws it, and that frame shows it already.
  void _pressed(bool down) => down ? _down.forward(from: _down.value > _frame ? _down.value : _frame) : _down.reverse();

  /// One 60 Hz frame of the 100 ms it takes to come.
  static const _frame = 16 / 100;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final ios = platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
    // Read, not watched: whoever builds this is built again with the brand.
    final brand = context.getInheritedWidgetOfExactType<MessengerScope>()?.controller.brand;
    final splash = !ios ? (widget.onBrand ? Colors.white.withAlpha(61) : brand?.ring) : Colors.transparent;
    // The ring only for a keyboard's focus, not after a touch.
    final keyboard = _focused && FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final ring = !keyboard ? null : (widget.onBrand ? brand?.onPrimary : brand?.ink) ?? Palette.text;
    // On Android the highlight never comes (the ripple is the press); the
    // painter is there for the ring, the same tree on both.
    final child = CustomPaint(
      foregroundPainter: PressHighlight(_down, shape: widget.shape, inner: widget.inner, onBrand: widget.onBrand, ring: ring),
      child: widget.child,
    );
    final inner = widget.inner;
    if (inner != null) {
      return _InnerInk(
        inner: inner,
        onTap: widget.onTap,
        onHighlightChanged: ios ? _pressed : null,
        onFocusChange: _focus,
        customBorder: widget.shape,
        splashFactory: ios ? NoSplash.splashFactory : InkRipple.splashFactory,
        splashColor: splash,
        highlightColor: Colors.transparent,
        focusColor: Colors.transparent,
        child: child,
      );
    }
    return InkWell(
      onTap: widget.onTap,
      onHighlightChanged: ios ? _pressed : null,
      onFocusChange: _focus,
      customBorder: widget.shape,
      splashFactory: ios ? NoSplash.splashFactory : InkRipple.splashFactory,
      splashColor: splash,
      highlightColor: Colors.transparent,
      focusColor: Colors.transparent,
      child: child,
    );
  }
}

/// An InkWell whose ink is drawn in a box of [inner] at its centre.
class _InnerInk extends InkWell {
  const _InnerInk({
    required this.inner,
    super.onTap,
    super.onHighlightChanged,
    super.onFocusChange,
    super.customBorder,
    super.splashFactory,
    super.splashColor,
    super.highlightColor,
    super.focusColor,
    super.child,
  });

  final Size inner;

  @override
  RectCallback? getRectCallback(RenderBox referenceBox) => () => Alignment.center.inscribe(inner, Offset.zero & referenceBox.size);
}

/// iOS's press highlight: [amount] of black 8% (white 15% on the brand
/// colour) over [shape], in [inner] when given; and, with the keyboard's
/// focus on it, a 2-point [ring] just inside the shape.
class PressHighlight extends CustomPainter {
  PressHighlight(this.amount, {required this.shape, this.inner, this.onBrand = false, this.ring}) : super(repaint: amount);

  final Animation<double> amount;
  final ShapeBorder shape;
  final Size? inner;
  final bool onBrand;
  final Color? ring;

  static const ringWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final t = amount.value;
    final box = Offset.zero & size;
    final rect = inner == null ? box : Alignment.center.inscribe(inner!, box);
    if (t > 0) {
      // The channels as integers: Color's accessors changed between Flutter 3.24 and 3.27.
      final paint = Paint()..color = onBrand ? Color.fromARGB((38 * t).round(), 255, 255, 255) : Color.fromARGB((20 * t).round(), 0, 0, 0);
      canvas.drawPath(shape.getOuterPath(rect), paint);
    }
    final r = ring;
    if (r != null) {
      final stroke = Paint()
        ..color = r
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth;
      canvas.drawPath(shape.getOuterPath(rect.deflate(ringWidth / 2)), stroke);
    }
  }

  @override
  bool shouldRepaint(PressHighlight old) =>
      old.amount != amount || old.shape != shape || old.inner != inner || old.onBrand != onBrand || old.ring != ring;
}

/// A round icon button (close, back) on the brand header or a white page.
///
/// The circle is drawn at [size]; the area that takes the tap is at least
/// 44 × 44 (Apple's minimum), so a thumb that lands beside a small circle
/// still counts — one recogniser for all of it, so the feedback in the
/// circle starts with the touch.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, required this.tooltip, this.light = false, this.size = 36});

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  /// On the brand colour, in its [BrandColors.onPrimary] — white, or
  /// near-black on a pale brand (true); or dark on grey (false).
  final bool light;
  final double size;

  /// The smallest touch target, in logical pixels.
  static const minTarget = 44.0;

  @override
  Widget build(BuildContext context) {
    final target = size < minTarget ? minTarget : size;
    // Read, not watched: whoever builds this is built again with the brand.
    final on = context.getInheritedWidgetOfExactType<MessengerScope>()?.controller.brand.onPrimary ?? Colors.white;
    return Semantics(
      button: true,
      label: tooltip,
      // Named for a screen reader and found by its name; no long press to
      // show it, which held a tap's feedback back until the long press gave up.
      child: Tooltip(
        message: tooltip,
        triggerMode: TooltipTriggerMode.manual,
        excludeFromSemantics: true,
        // A Material of its own, the circle painted on it as Ink: Android's
        // ripple is drawn on the Material, so over the circle, not under it
        // and under the header's colour.
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: target,
            height: target,
            child: Pressable(
              onTap: onTap,
              shape: const CircleBorder(),
              inner: Size(size, size),
              onBrand: light,
              child: Center(
                child: Ink(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(color: light ? on.withAlpha(on == Colors.white ? 56 : 31) : Palette.fill, shape: BoxShape.circle),
                  child: Icon(icon, size: size * 0.5, color: light ? on : Palette.body),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An emoji to choose — the article's faces, the CSAT faces: the one
/// chosen grows a little, with a slight overshoot; the others turn grey
/// and fade back. 200 ms, with less motion asked for too (see [fullTime]).
class ChoiceFace extends StatelessWidget {
  const ChoiceFace({super.key, required this.emoji, required this.chosen, required this.faded, required this.size});

  final String emoji;
  final bool chosen;
  final bool faded;
  final double size;

  static const time = Duration(milliseconds: 200);
  static const grown = 1.3;

  /// Colour at [s] of full (1) to none (0), by the eye's weights.
  static ColorFilter _saturation(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    return ColorFilter.matrix(<double>[
      r + (1 - r) * s, g - g * s, b - b * s, 0, 0, //
      r - r * s, g + (1 - g) * s, b - b * s, 0, 0, //
      r - r * s, g - g * s, b + (1 - b) * s, 0, 0, //
      0, 0, 0, 1, 0,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final time = fullTime(ChoiceFace.time);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: faded ? 0 : 1),
      duration: time,
      builder: (_, colour, child) => ColorFiltered(
        colorFilter: _saturation(colour),
        child: Opacity(opacity: 0.4 + 0.6 * colour, child: child),
      ),
      child: AnimatedScale(
        scale: chosen ? grown : 1,
        duration: time,
        curve: Curves.easeOutBack,
        child: Text(emoji, style: TextStyle(fontSize: size)),
      ),
    );
  }
}

/// A circle with an initial on the brand colour.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({super.key, required this.label, this.size = 28, this.icon});

  final String label;
  final double size;
  final IconData? icon;

  /// The letter alone, for a circle that is already the brand colour.
  static Widget letter(BrandColors brand, String label, double size) {
    final initial = label.trim().isEmpty ? 'S' : label.trim().characters.first.toUpperCase();
    return Text(initial, style: TextStyle(color: brand.onPrimary, fontSize: size * 0.42, fontWeight: FontWeight.w700));
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: brand.surface, shape: BoxShape.circle),
      child: icon != null ? Icon(icon, size: size * 0.55, color: brand.onPrimary) : letter(brand, label, size),
    );
  }
}

/// A teammate's photo when they have one (from the API), else their initial.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({super.key, required this.name, this.photoPath, this.size = 28});

  final String name;

  /// Relative to the API (`/widget/avatar/<id>…`).
  final String? photoPath;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = InitialAvatar(label: name, size: size);
    final path = photoPath;
    if (path == null || path.isEmpty) return fallback;
    final url = '${context.messenger.api.apiUrl}$path';
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // A 404 (no photo) or no signal: the initial, never a broken image.
        errorBuilder: (_, __, ___) => fallback,
        frameBuilder: fadeOver(fallback),
      ),
    );
  }
}

/// The chatbot's circle, as Intercom shows the brand beside the bot: beside
/// the bot's messages and its typing, and in the chat header when nobody's
/// face is shown there. The chat avatar fills it. Without one, the logo,
/// whole whatever its shape, on the brand colour: on the white of 0.4.2,
/// GL's white logo vanished. No logo either, or nothing that loads: the
/// initial. The website messenger draws it the same way.
class LogoAvatar extends StatelessWidget {
  const LogoAvatar({super.key, required this.label, this.size = 28});

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final session = context.messenger.session;
    final logo = session?.logoUrl;
    final onBrand = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: brand.surface, shape: BoxShape.circle),
      child: logo == null
          ? InitialAvatar.letter(brand, label, size)
          : Padding(
              padding: EdgeInsets.all(size * 0.12),
              child: Image.network(
                logo,
                fit: BoxFit.contain,
                // Already on the brand colour: the letter alone, never a broken image.
                errorBuilder: (_, __, ___) => Center(child: InitialAvatar.letter(brand, label, size)),
                frameBuilder: fadeOver(Center(child: InitialAvatar.letter(brand, label, size))),
              ),
            ),
    );
    final avatar = session?.avatarUrl;
    if (avatar == null) return onBrand;
    return ClipOval(
      child: Image.network(
        avatar,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => onBrand,
        frameBuilder: fadeOver(onBrand),
      ),
    );
  }
}

/// Up to three team faces, overlapping, as on Home and in the chat header:
/// the session's, or [team] (the look remembered from last time).
class TeamFaces extends StatelessWidget {
  const TeamFaces({super.key, this.size = 40, this.border = 2, this.team});

  final double size;
  final double border;
  final List<TeamFace>? team;

  @override
  Widget build(BuildContext context) {
    final team = this.team ?? context.messenger.session?.team ?? const <TeamFace>[];
    if (team.isEmpty) return const SizedBox.shrink();
    final step = size - size / 4;
    return SizedBox(
      width: step * (team.length - 1) + size,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < team.length; i++)
            Positioned(
              left: step * i,
              child: Tooltip(
                message: team[i].name,
                child: Container(
                  padding: EdgeInsets.all(border),
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                  child: PersonAvatar(name: team[i].initials, photoPath: team[i].avatarPath, size: size - border * 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A coloured dot before a status line.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.away, this.size = 8});
  final bool away;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: away ? Palette.away : Palette.online, shape: BoxShape.circle),
      );
}

/// The yellow "Reconnecting…" bar under a header.
///
/// A dropped connection shows at once. The first connection of an open does
/// not: it usually takes a moment, the customer can already type and send
/// (the message goes once connected), and a bar flashing on every open reads
/// as something wrong. It shows only if connecting takes longer than [patience].
class ConnectionBar extends StatefulWidget {
  const ConnectionBar({super.key});

  static const patience = Duration(seconds: 2);

  @override
  State<ConnectionBar> createState() => _ConnectionBarState();
}

class _ConnectionBarState extends State<ConnectionBar> {
  Timer? _wait;
  bool _slow = false;

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MessengerSelector<LinkState>(select: (c) => c.link, builder: _bar);

  Widget _bar(BuildContext context, LinkState link) {
    var shown = true;
    if (link == LinkState.connected) {
      _wait?.cancel();
      _wait = null;
      _slow = false;
      shown = false;
    } else if (link == LinkState.connecting && !_slow) {
      _wait ??= Timer(ConnectionBar.patience, () {
        if (mounted) setState(() => _slow = true);
      });
      shown = false;
    }
    // It opens and closes over 200 ms, rather than push the screen down
    // (and up again) in one frame.
    return Reveal(
      shown: shown,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        decoration: const BoxDecoration(color: Color(0xFFFEF3C7), border: Border(bottom: BorderSide(color: Color(0xFFFDE68A)))),
        child: Text(
          link == LinkState.reconnecting ? 'Reconnecting…' : 'Connecting…',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF92400E)),
        ),
      ),
    );
  }
}

/// How long one of Flutter's own animations (AnimatedSwitcher, AnimatedSize,
/// AnimatedOpacity, AnimatedScale) is given, so that it takes [time].
///
/// The messenger moves whatever the phone's animation setting, as
/// Intercom's does: measured, Intercom's messenger plays the same with
/// reduced motion asked for as without, and we chose to match it (15 Oct
/// 2026). So the package no longer reads MediaQuery.disableAnimations. Flutter
/// still does: with Android's Remove animations on, every AnimationController
/// that does not opt out runs at 5% of its time, and a 200 ms fade is over in
/// a frame. The messenger's own controllers opt out
/// (AnimationBehavior.preserve); the framework's widgets cannot, so they are
/// given 20 times the time, which Flutter brings back to [time]. (iOS's
/// Reduce Motion reaches neither: Flutter reports it as reduceMotion.)
Duration fullTime(Duration time) => SemanticsBinding.instance.disableAnimations ? time * 20 : time;

/// Something that comes and goes — a bar, a pill: over [time] it opens and
/// fades in, and fades as it closes, instead of appearing or vanishing in
/// one frame. While it goes it shows what it last showed; once gone it is
/// out of the tree. [size]: it takes its room as it opens (a bar in a
/// column); without, it only fades (a pill over the thread).
class Reveal extends StatefulWidget {
  const Reveal({super.key, required this.shown, required this.child, this.size = true});

  final bool shown;
  final Widget child;
  final bool size;

  static const time = Duration(milliseconds: 200);

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  // Its whole time even with less motion asked for: see [fullTime].
  late final AnimationController _open =
      AnimationController(vsync: this, duration: Reveal.time, value: widget.shown ? 1 : 0, animationBehavior: AnimationBehavior.preserve);
  // Closing is the opening's mirror: quick at first, gentle at the end. (The
  // same curve played backwards closed slowly, then all at once: a line
  // under a message dropped the bubble above it late, against the thread's
  // glide.)
  late final CurvedAnimation _t = CurvedAnimation(parent: _open, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  late Widget _last = widget.child;

  @override
  void didUpdateWidget(Reveal old) {
    super.didUpdateWidget(old);
    if (widget.shown) _last = widget.child;
    if (widget.shown == old.shown) return;
    if (widget.shown) {
      _open.forward();
    } else {
      _open.reverse();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _open,
      builder: (context, _) {
        if (_open.isDismissed) return const SizedBox.shrink();
        final faded = IgnorePointer(ignoring: !widget.shown, child: FadeTransition(opacity: _t, child: _last));
        if (!widget.size) return faded;
        // SizeTransition's own alignment is spelt differently before and
        // after Flutter 3.41: the clip and the factor by hand work on both.
        // As wide as what it shows, not the whole row: a line under a
        // message stays at the bubble's edge.
        return ClipRect(child: Align(alignment: Alignment.topCenter, widthFactor: 1, heightFactor: _t.value, child: faded));
      },
    );
  }
}

/// A white card with the messenger's soft shadow.
class MessengerCard extends StatelessWidget {
  const MessengerCard({super.key, required this.child, this.onTap, this.padding = EdgeInsets.zero});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x14000000), blurRadius: 20, offset: Offset(0, 6)),
          BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: onTap == null
            ? Padding(padding: padding, child: child)
            : Pressable(
                onTap: onTap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Padding(padding: padding, child: child),
              ),
      ),
    );
  }
}

/// A picture that comes in over what stood for it (an initial, a letter):
/// a 200 ms fade, never a one-frame swap. One already in the cache (fetched
/// at sign-in) is simply there.
ImageFrameBuilder fadeOver(Widget placeholder) => (context, child, frame, sync) {
      if (sync) return child;
      return Stack(
        alignment: Alignment.center,
        children: [
          placeholder,
          AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            // Even with less motion asked for: see [fullTime].
            duration: fullTime(const Duration(milliseconds: 200)),
            curve: Curves.easeOut,
            child: child,
          ),
        ],
      );
    };

/// A picture with nothing to stand for it (a logo, a photo): it fades in
/// once it has loaded rather than pop in, over [time].
ImageFrameBuilder fadeIn([Duration time = const Duration(milliseconds: 200)]) => (context, child, frame, sync) {
      if (sync) return child;
      return AnimatedOpacity(
        opacity: frame == null ? 0 : 1,
        // Even with less motion asked for: see [fullTime].
        duration: fullTime(time),
        curve: Curves.easeOut,
        child: child,
      );
    };

/// Skeleton bars below this shimmer together: a soft highlight that sweeps
/// across every 1200 ms.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  static const period = Duration(milliseconds: 1200);

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  // It sweeps with less motion asked for too, as everything else does (see
  // [fullTime]); a repeating controller keeps its time anyway.
  late final AnimationController _sweep = AnimationController(vsync: this, duration: Shimmer.period)..repeat();

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ShimmerScope(sweep: _sweep, child: widget.child);
}

class _ShimmerScope extends InheritedWidget {
  const _ShimmerScope({required this.sweep, required super.child});
  final Animation<double> sweep;

  @override
  bool updateShouldNotify(_ShimmerScope old) => !identical(old.sweep, sweep);
}

/// A rounded grey bar where words will be. On the brand colour ([onBrand])
/// it is white, see-through.
class SkeletonBar extends StatelessWidget {
  const SkeletonBar({super.key, this.width, this.height = 12, this.onBrand = false});

  final double? width;
  final double height;
  final bool onBrand;

  @override
  Widget build(BuildContext context) {
    final base = onBrand ? const Color(0x38FFFFFF) : const Color(0xFFE8EAED);
    final light = onBrand ? const Color(0x61FFFFFF) : const Color(0xFFF6F7F8);
    final radius = BorderRadius.circular(height / 2);
    final sweep = context.dependOnInheritedWidgetOfExactType<_ShimmerScope>()?.sweep;
    if (sweep == null) return Container(width: width, height: height, decoration: BoxDecoration(color: base, borderRadius: radius));
    return AnimatedBuilder(
      animation: sweep,
      builder: (_, __) {
        // The highlight enters from the left edge and leaves past the right.
        final at = -0.3 + 1.6 * sweep.value;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              colors: [base, light, base],
              stops: [(at - 0.3).clamp(0.0, 1.0), at.clamp(0.0, 1.0), (at + 0.3).clamp(0.0, 1.0)],
            ),
          ),
        );
      },
    );
  }
}

/// A skeleton bar exactly one line of [style] tall, so what replaces it
/// takes the same room at any text size.
class TextBar extends StatelessWidget {
  const TextBar({super.key, required this.style, required this.width, this.onBrand = false});

  final TextStyle style;
  final double width;
  final bool onBrand;

  @override
  Widget build(BuildContext context) {
    final size = style.fontSize ?? 14;
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        ExcludeSemantics(child: Opacity(opacity: 0, child: Text('Hg', maxLines: 1, style: style))),
        SkeletonBar(width: width, height: (MediaQuery.textScalerOf(context).scale(size) * 0.72).roundToDouble(), onBrand: onBrand),
      ],
    );
  }
}
