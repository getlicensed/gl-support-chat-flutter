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
    _value = widget.select(_c!);
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

/// Neutral colours, the website messenger's.
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
  static const border = Color(0xFFE5E7EB);
  static const fill = Color(0xFFF3F4F6);
  static const page = Color(0xFFF5F6F7);
  static const input = Color(0xFFF9FAFB);
  static const agentBubble = Color(0xFFF1F2F4);
  static const danger = Color(0xFFEF4444);
  static const error = Color(0xFFB91C1C);
  static const success = Color(0xFF059669);
  static const online = Color(0xFF34D399);
  static const away = Color(0xFF9CA3AF);
  static const whatsapp = Color(0xFF25D366);
  static const whatsappText = Color(0xFF128C7E);
}

/// The messenger's own theme, so the app's theme cannot restyle it.
///
/// Built fresh rather than copied from the app's: the screens are white, and
/// an app that follows the phone's dark mode would otherwise bring its light
/// text and dark fields with it (typed text vanished on white). Only the
/// app's typeface and sizes come across, in the messenger's own ink.
ThemeData messengerTheme(BuildContext context, BrandColors brand) {
  final host = Theme.of(context);
  final cached = _themeCache;
  // The controller notifies many times a second while an AI answer types
  // out; the same theme object then rebuilds nothing below it.
  if (cached != null && identical(cached.host, host) && cached.brand == brand.hex) return cached.theme;
  final theme = ThemeData(
    useMaterial3: host.useMaterial3,
    colorScheme: ColorScheme.fromSeed(
      seedColor: brand.primary,
      primary: brand.primary,
      onPrimary: brand.onPrimary,
      surface: Colors.white,
      onSurface: Palette.text,
      brightness: Brightness.light,
    ),
    textTheme: host.textTheme.apply(bodyColor: Palette.text, displayColor: Palette.text),
    platform: host.platform,
    visualDensity: host.visualDensity,
    scaffoldBackgroundColor: Colors.white,
    canvasColor: Colors.white,
    textSelectionTheme: TextSelectionThemeData(cursorColor: brand.primary, selectionHandleColor: brand.primary),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: brand.primary),
    inputDecorationTheme: const InputDecorationTheme(hintStyle: TextStyle(color: Palette.hint)),
  );
  _themeCache = (host: host, brand: brand.hex, theme: theme);
  return theme;
}

({ThemeData host, String brand, ThemeData theme})? _themeCache;

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

/// A round icon button (close, back) on the brand header or a white page.
///
/// The circle is drawn at [size]; the area that takes the tap is at least
/// 44 × 44 (Apple's minimum), so a thumb that lands beside a small circle
/// still counts.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({super.key, required this.icon, required this.onTap, required this.tooltip, this.light = false, this.size = 36});

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  /// White on the brand colour (true) or dark on grey (false).
  final bool light;
  final double size;

  /// The smallest touch target, in logical pixels.
  static const minTarget = 44.0;

  @override
  Widget build(BuildContext context) {
    final target = size < minTarget ? minTarget : size;
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        // The margin around the circle takes the tap; a tap on the circle is
        // the InkWell's (the innermost wins), so it fires once, with its ripple.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            width: target,
            height: target,
            child: Center(
              child: Material(
                color: light ? Colors.white.withAlpha(56) : Palette.fill,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: Icon(icon, size: size * 0.5, color: light ? Colors.white : Palette.body),
                  ),
                ),
              ),
            ),
          ),
        ),
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
      decoration: BoxDecoration(color: brand.primary, shape: BoxShape.circle),
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
      decoration: BoxDecoration(color: brand.primary, shape: BoxShape.circle),
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
  late final CurvedAnimation _t = CurvedAnimation(parent: _open, curve: Curves.easeOutCubic);
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
        return ClipRect(child: Align(alignment: Alignment.topCenter, heightFactor: _t.value, child: faded));
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
        child: onTap == null ? Padding(padding: padding, child: child) : InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
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
/// once it has loaded rather than pop in.
ImageFrameBuilder fadeIn() => (context, child, frame, sync) {
      if (sync) return child;
      return AnimatedOpacity(
        opacity: frame == null ? 0 : 1,
        // Even with less motion asked for: see [fullTime].
        duration: fullTime(const Duration(milliseconds: 200)),
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
