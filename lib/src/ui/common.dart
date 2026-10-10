import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/controller.dart';
import '../core/format.dart';
import '../fallback.dart';
import '../launcher.dart';

/// The messenger's routes are named under this, so "close" can pop all of
/// them at once and land back on the app's own screen.
const messengerRoutePrefix = 'gl_support_chat';

/// What every messenger screen needs: the controller, the app's fallback
/// contacts, and how to reach the API for pictures.
class MessengerScope extends InheritedNotifier<MessengerController> {
  const MessengerScope({super.key, required MessengerController controller, required this.fallback, required super.child})
      : super(notifier: controller);

  final GLSupportChatFallback fallback;

  static MessengerScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<MessengerScope>();
    assert(scope != null, 'A messenger screen outside MessengerScope');
    return scope!;
  }

  MessengerController get controller => notifier!;
}

extension MessengerContext on BuildContext {
  MessengerController get messenger => MessengerScope.of(this).controller;
  BrandColors get brand => MessengerScope.of(this).controller.brand;
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

/// Pop every messenger screen: back to the app.
void closeMessenger(BuildContext context) {
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

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final initial = label.trim().isEmpty ? 'S' : label.trim().characters.first.toUpperCase();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: brand.primary, shape: BoxShape.circle),
      child: icon != null
          ? Icon(icon, size: size * 0.55, color: brand.onPrimary)
          : Text(initial, style: TextStyle(color: brand.onPrimary, fontSize: size * 0.42, fontWeight: FontWeight.w700)),
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
        frameBuilder: (_, child, frame, sync) => frame == null && !sync ? fallback : child,
      ),
    );
  }
}

/// The chatbot's logo in a circle — on white, whole whatever its shape — for
/// the bot's messages and the chat header, as Intercom shows the brand beside
/// the bot. No logo, or one that does not load: the initial.
class LogoAvatar extends StatelessWidget {
  const LogoAvatar({super.key, required this.label, this.size = 28});

  final String label;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = InitialAvatar(label: label, size: size);
    final logo = context.messenger.session?.logoUrl;
    if (logo == null) return fallback;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.12),
      decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
      child: ClipOval(
        child: Image.network(
          logo,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => fallback,
          frameBuilder: (_, child, frame, sync) => frame == null && !sync ? fallback : child,
        ),
      ),
    );
  }
}

/// Up to three team faces, overlapping, as on Home and in the chat header.
class TeamFaces extends StatelessWidget {
  const TeamFaces({super.key, this.size = 40, this.border = 2});

  final double size;
  final double border;

  @override
  Widget build(BuildContext context) {
    final team = context.messenger.session?.team ?? const [];
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
  Widget build(BuildContext context) {
    final link = context.messenger.link;
    if (link == LinkState.connected) {
      _wait?.cancel();
      _wait = null;
      _slow = false;
      return const SizedBox.shrink();
    }
    if (link == LinkState.connecting && !_slow) {
      _wait ??= Timer(ConnectionBar.patience, () {
        if (mounted) setState(() => _slow = true);
      });
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      decoration: const BoxDecoration(color: Color(0xFFFEF3C7), border: Border(bottom: BorderSide(color: Color(0xFFFDE68A)))),
      child: Text(
        link == LinkState.connecting ? 'Connecting…' : 'Reconnecting…',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF92400E)),
      ),
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
