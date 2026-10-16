import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/session_store.dart';
import 'common.dart';

/// The messenger's own text size, chosen with Aa in its header, for
/// customers who find its words small (0.4.9): a multiple of the phone's own
/// text size, never in place of it. Kept on the phone, beside the visitor
/// id, for whoever uses the phone: it is not about the customer, so it
/// survives a sign-out.
class MessengerTextSize {
  MessengerTextSize._();

  /// What Aa offers, and its name.
  static const choices = <(double, String)>[
    (0.9, 'Small'),
    (1.0, 'Default'),
    (1.15, 'Large'),
    (1.3, 'Extra large'),
  ];

  /// The most the choice takes the words to, times their size: the phone's
  /// own setting may be larger still, and is never made smaller by Aa.
  static const maxTotal = 2.0;

  /// The multiple chosen now.
  static final factor = ValueNotifier<double>(1.0);

  static SessionStore? _store;
  static bool _chosen = false;

  /// What was chosen on this phone before, from [store], where a choice is
  /// kept from now on. Called at configure.
  static Future<void> load(SessionStore store) async {
    _store = store;
    final saved = await store.textSize();
    // Chosen meanwhile (the messenger opened at once): that one stands.
    if (_chosen || saved == null) return;
    if (choices.any((c) => c.$1 == saved)) factor.value = saved;
  }

  /// [value] from now on, and on this phone's next launch.
  static void choose(double value) {
    _chosen = true;
    factor.value = value;
    final store = _store;
    if (store != null) unawaited(store.saveTextSize(value));
  }

  /// Back to Default, with nothing chosen or kept — for tests.
  @visibleForTesting
  static void debugReset() {
    _chosen = false;
    _store = null;
    factor.value = 1.0;
  }
}

/// The phone's own scaling of the words ([base]) times [factor], at most
/// [MessengerTextSize.maxTotal] times their size — or what the phone itself
/// asks for, if that is more. Android's non-linear scaling (large words grow
/// less) is kept.
TextScaler messengerScaler(TextScaler base, double factor) => factor == 1.0 ? base : _Times(base, factor);

class _Times extends TextScaler {
  const _Times(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) {
    final own = base.scale(fontSize);
    return math.min(own * factor, math.max(fontSize * MessengerTextSize.maxTotal, own));
  }

  // Flutter's older, linear reading of it, still asked for by some widgets.
  @override
  double get textScaleFactor => scale(14) / 14;

  @override
  bool operator ==(Object other) => other is _Times && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);

  @override
  String toString() => '$base × $factor';
}

/// Every word below is drawn at the size chosen with Aa: the messenger's
/// screens, and what opens over them.
class MessengerTextScale extends StatelessWidget {
  const MessengerTextScale({super.key, required this.child});
  final Widget child;

  /// The phone's own scaling, before Aa's.
  static TextScaler phoneOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PhoneScaler>()?.scaler ?? MediaQuery.textScalerOf(context);

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: MessengerTextSize.factor,
        child: child,
        builder: (context, factor, child) {
          final data = MediaQuery.of(context);
          // Already inside one (a screen of the messenger opened over
          // another): the phone's own is the one that one was given.
          final phone = context.dependOnInheritedWidgetOfExactType<_PhoneScaler>()?.scaler ?? data.textScaler;
          return _PhoneScaler(
            scaler: phone,
            child: MediaQuery(data: data.copyWith(textScaler: messengerScaler(phone, factor)), child: child!),
          );
        },
      );
}

class _PhoneScaler extends InheritedWidget {
  const _PhoneScaler({required this.scaler, required super.child});
  final TextScaler scaler;

  @override
  bool updateShouldNotify(_PhoneScaler old) => old.scaler != scaler;
}

/// Aa in a header: opens the choice of text size. [light] on the brand
/// colour, as Close beside it.
class TextSizeButton extends StatelessWidget {
  const TextSizeButton({super.key, this.light = false, this.size = 36});
  final bool light;
  final double size;

  static const label = 'Text size';

  @override
  Widget build(BuildContext context) =>
      RoundIconButton.glyph(glyph: 'Aa', tooltip: label, light: light, size: size, onTap: () => showTextSizeSheet(context));
}

/// The choice of text size, in a sheet over the messenger: Small, Default,
/// Large, Extra large, each in its own size, the one in use ticked, and a
/// message drawn at the size chosen — which the messenger behind it takes
/// at once, too.
Future<void> showTextSizeSheet(BuildContext context) {
  final scope = MessengerScope.of(context);
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    // Named as the messenger's: closed with it.
    routeSettings: const RouteSettings(name: '$messengerRoutePrefix/text-size'),
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    // Its time with less motion asked for too, as the rest (see [fullTime]).
    sheetAnimationStyle: AnimationStyle(duration: fullTime(const Duration(milliseconds: 250)), reverseDuration: fullTime(const Duration(milliseconds: 200))),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => MessengerScope(
      controller: scope.controller,
      fallback: scope.fallback,
      child: Theme(data: theme, child: const MessengerTextScale(child: TextSizeSheet())),
    ),
  );
}

class TextSizeSheet extends StatelessWidget {
  const TextSizeSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final phone = MessengerTextScale.phoneOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: MessengerTextSize.factor,
      builder: (context, current, _) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 8, 12, 16 + MediaQuery.paddingOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: const Text(TextSizeButton.label, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Palette.text)),
                  ),
                ),
                RoundIconButton(icon: Icons.close, tooltip: 'Done', size: 32, onTap: () => Navigator.of(context).maybePop()),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Text(
                "For this chat and the help articles in it, on top of your phone's own text size.",
                style: TextStyle(fontSize: 13, height: 1.4, color: Palette.muted),
              ),
            ),
            const SizedBox(height: 14),
            // A message as the thread draws it, at the size in use.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Palette.agentBubble,
                  border: Border.all(color: Palette.bubbleEdge, width: 0.5),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'Hi! Your licence card was posted today. Reply here if it has not arrived by Friday.',
                  style: TextStyle(fontSize: 15, height: 1.45, color: Palette.text),
                ),
              ),
            ),
            const SizedBox(height: 10),
            for (final (value, name) in MessengerTextSize.choices)
              _Choice(
                name: name,
                chosen: value == current,
                // Each in its own size: the choice shows itself.
                scaler: messengerScaler(phone, value),
                ink: brand.ink,
                onTap: () => MessengerTextSize.choose(value),
              ),
          ],
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({required this.name, required this.chosen, required this.scaler, required this.ink, required this.onTap});

  final String name;
  final bool chosen;
  final TextScaler scaler;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: chosen,
      inMutuallyExclusiveGroup: true,
      label: name,
      onTap: onTap,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    textScaler: scaler,
                    style: TextStyle(fontSize: 15, fontWeight: chosen ? FontWeight.w600 : FontWeight.w400, color: Palette.text),
                  ),
                ),
                // Ticked: the size in use. Room kept for it on every row.
                SizedBox(width: 24, child: chosen ? Icon(Icons.check, size: 22, color: ink) : null),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
