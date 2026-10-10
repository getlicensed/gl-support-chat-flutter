import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';

import 'fakes.dart';

/// A phone for a widget test: its screen and its safe areas, in logical
/// pixels. No simulator here, so the messenger is pumped at these sizes with
/// the keyboard, the notch and the text size the phone would report.
class Phone {
  const Phone(this.name, this.size, {this.top = 47, this.bottom = 34, this.left = 0, this.right = 0});

  final String name;
  final Size size;
  final double top;
  final double bottom;
  final double left;
  final double right;

  static const iphone13 = Phone('iPhone 13', Size(390, 844));
  static const iphoneSE = Phone('iPhone SE', Size(375, 667), top: 20, bottom: 0);
  static const android360 = Phone('Android 360', Size(360, 740), top: 24, bottom: 0);
  static const landscape = Phone('iPhone 13 landscape', Size(844, 390), top: 0, bottom: 21, left: 47, right: 47);

  static const all = <Phone>[iphone13, iphoneSE, android360, landscape];

  /// The keyboard's height on this phone, roughly.
  double get keyboard => size.height > size.width ? (size.height > 700 ? 336 : 260) : 200;
}

/// Puts the test's view on [phone], with the keyboard [keyboard] points tall
/// (0: down) and the text size at [textScale]. Undone after the test.
void usePhone(WidgetTester tester, Phone phone, {double keyboard = 0, double textScale = 1}) {
  const dpr = 3.0;
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = phone.size * dpr;
  tester.view.viewPadding = FakeViewPadding(left: phone.left * dpr, top: phone.top * dpr, right: phone.right * dpr, bottom: phone.bottom * dpr);
  setKeyboard(tester, phone, keyboard);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

/// The keyboard up ([height] > 0) or down. As the engine reports it, the
/// keyboard covers the home indicator's inset.
void setKeyboard(WidgetTester tester, Phone phone, double height) {
  const dpr = 3.0;
  tester.view.viewInsets = FakeViewPadding(bottom: height * dpr);
  tester.view.padding = FakeViewPadding(
    left: phone.left * dpr,
    top: phone.top * dpr,
    right: phone.right * dpr,
    bottom: math.max(0, phone.bottom - height) * dpr,
  );
}

/// The app with a button that opens the messenger as `GLSupportChat.present`
/// does — on the root navigator, as the route "close" pops — so back and
/// close can be seen to land back on the app.
Future<MessengerController> openMessenger(
  WidgetTester tester,
  FakeServer server,
  FakeChannel channel, {
  GLSupportChatScreen screen = GLSupportChatScreen.home,
  ThemeData? theme,
}) async {
  final c = controllerFor(server, channel);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
              settings: const RouteSettings(name: messengerRoutePrefix),
              pageBuilder: (_, __, ___) => GLSupportChatPage(controller: c, screen: screen),
            )),
            child: const Text('Open support'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open support'));
  await settle(tester);
  return c;
}

/// Frames enough for the pretend server's answers and an animation or two.
/// (Not pumpAndSettle: a spinner or the typing dots never settle.)
Future<void> settle(WidgetTester tester, {int frames = 10}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// WCAG contrast of [fg] over [bg]; a see-through [fg] is laid on [bg] first.
double contrast(Color fg, Color bg) {
  final a = Color.alphaBlend(fg, bg).computeLuminance();
  final b = bg.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}
