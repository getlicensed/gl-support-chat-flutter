import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';
import 'package:gl_support_chat/src/ui/sheet.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';

// Frame by frame: what moves, sampled every 16 ms (a 60 Hz phone) on an
// iPhone 13, through each transition of the messenger. Grown from the
// measurements behind 0.4.6 (15 Oct), which found the messenger opening all
// at once and some things moving in one frame; these keep it fluid.
const frame = Duration(milliseconds: 16);

/// The iPhone 13's status bar and the strip of the app above the sheet.
const sheetTop = 47.0 + sheetGap;
const sheetHeight = 844.0 - sheetTop;

void main() {
  late GatedServer server;
  String at(int minute) => DateTime.utc(2026, 10, 6, 11, minute).toIso8601String();

  setUp(() {
    server = GatedServer();
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Let me check.')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('m1', 'visitor', 'Where is my licence card?', at: at(0)),
      msg('m2', 'agent', 'Let me check.', at: at(1)),
    ]);
  });

  void lessMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  /// The app, with a button that opens the messenger in its sheet, as
  /// `GLSupportChat.present` does.
  Future<MessengerController> host(
    WidgetTester tester, {
    TargetPlatform platform = TargetPlatform.iOS,
    GLSupportChatScreen screen = GLSupportChatScreen.home,
    bool reduceMotion = false,
  }) async {
    usePhone(tester, Phone.iphone13);
    final c = controllerOn(server, FakeChannel());
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(platform: platform),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context, rootNavigator: true)
                  .push(messengerRoute(GLSupportChatPage(controller: c, screen: screen), reduceMotion: reduceMotion)),
              child: const Text('Open support'),
            ),
          ),
        ),
      ),
    ));
    return c;
  }

  /// Where the top of the sheet is drawn; null once it has gone.
  double? sheetY(WidgetTester tester) {
    final f = find.byType(GLSupportChatPage);
    return f.evaluate().isEmpty ? null : tester.getTopLeft(f).dy;
  }

  /// [frames] frames of [step], and [read] after each.
  Future<List<T>> sample<T>(WidgetTester tester, int frames, T Function() read, {Duration step = frame}) async {
    final out = <T>[];
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
      out.add(read());
    }
    return out;
  }

  Color scrim(WidgetTester tester) {
    final barriers = find.byType(ModalBarrier).evaluate().map((e) => (e.widget as ModalBarrier).color).whereType<Color>();
    return barriers.isEmpty ? const Color(0x00000000) : barriers.last;
  }

  group('the sheet', () {
    for (final (platform, radius) in <(TargetPlatform, double)>[(TargetPlatform.iOS, 12), (TargetPlatform.android, 16)]) {
      testWidgets('rises from below over a scrim, its top corners rounded ${radius.toInt()} (${platform.name})', (tester) async {
        await host(tester, platform: platform);
        await tester.tap(find.text('Open support'));
        await tester.pump();
        final ys = await sample(tester, 26, () => sheetY(tester)!);
        // On the open curve, from just below the screen to under the status bar.
        for (var i = 0; i < 25; i++) {
          final t = ((i + 1) * 16 / 400).clamp(0.0, 1.0);
          expect(ys[i], closeTo(sheetTop + sheetHeight * (1 - messengerOpenCurve.transform(t)), 1.5), reason: 'frame ${i + 1}');
        }
        expect(ys.first, greaterThan(sheetTop + sheetHeight * 0.5), reason: 'the first frame is still in the lower half: it rises, it does not appear');
        expect(ys[6], lessThan(sheetTop + sheetHeight * 0.3), reason: 'most of the way up within about 100 ms');
        for (var i = 1; i < ys.length; i++) {
          expect(ys[i], lessThanOrEqualTo(ys[i - 1]), reason: 'never back down on the way up');
        }
        expect(ys.last, sheetTop, reason: 'a strip of the app shows above it');
        expect(scrim(tester), messengerScrim, reason: 'the app behind dimmed 40%');
        final clip = tester.widget<ClipRRect>(find.ancestor(of: find.byType(GLSupportChatPage), matching: find.byType(ClipRRect)).first);
        expect(clip.borderRadius, BorderRadius.vertical(top: Radius.circular(radius)));
        expect(find.text('Open support'), findsOneWidget, reason: 'the app is still drawn behind');
      });
    }

    testWidgets('Close: down on the close curve in 250 ms — no slow start that then rushes', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.byTooltip('Close').first);
      await tester.pump();
      final ys = await sample(tester, 16, () => sheetY(tester));
      for (var i = 0; i < 15; i++) {
        final t = (i + 1) * 16 / 250;
        expect(ys[i], closeTo(sheetTop + sheetHeight * messengerCloseCurve.transform(t), 1.5), reason: 'frame ${i + 1}');
      }
      expect(ys[3]! - sheetTop, greaterThan(10), reason: 'moving within 64 ms, not barely');
      expect(ys.last, isNull, reason: 'gone after 250 ms');
    });

    testWidgets('dragged down past a quarter it closes; less than that, it springs back', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      // Slowly, a little: it follows the finger, then springs back up.
      final start = tester.getCenter(find.text('Search for help'));
      final g = await tester.startGesture(start);
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(0, 20));
        await tester.pump(frame);
      }
      final held = sheetY(tester)!;
      expect(held, greaterThan(sheetTop + 50), reason: 'it follows the finger');
      expect(held, lessThan(sheetTop + sheetHeight * sheetCloseShare));
      await g.up();
      final back = await sample(tester, 30, () => sheetY(tester)!);
      for (var i = 1; i < back.length; i++) {
        expect(back[i], lessThanOrEqualTo(back[i - 1] + 0.01), reason: 'straight back up, no bounce past');
      }
      expect(back.last, sheetTop);

      // Slowly, past a quarter: it closes.
      await tester.timedDragFrom(start, const Offset(0, 260), const Duration(milliseconds: 900));
      await tester.pump();
      final down = await sample(tester, 30, () => sheetY(tester));
      expect(down.last, isNull, reason: 'closed');
      expect(find.text('Open support'), findsOneWidget);
    });

    testWidgets('a flick down closes it, however short', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.flingFrom(tester.getCenter(find.text('Search for help')), const Offset(0, 90), 1200);
      await tester.pump();
      final down = await sample(tester, 30, () => sheetY(tester));
      expect(down.last, isNull);
    });

    testWidgets('a list at its top pulls the sheet down rather than stretch', (tester) async {
      // A long list of articles: it scrolls, so it takes the drag itself.
      server.articles = <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++) <String, dynamic>{'slug': 'a$i', 'title': 'Article number $i about the licence', 'description': null},
      ];
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Help').last);
      await settle(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('Article number 2 about the licence')));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(0, 25));
        await tester.pump(frame);
      }
      expect(sheetY(tester), greaterThan(sheetTop + 80), reason: 'the sheet came down with the finger');
      expect(tester.getTopLeft(find.text('Article number 2 about the licence')).dy - sheetY(tester)!, lessThan(400), reason: 'the list did not stretch');
      // Back up: the sheet first, then the list scrolls.
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(0, -25));
        await tester.pump(frame);
      }
      expect(sheetY(tester), sheetTop);
      await g.up();
      await settle(tester);
      expect(sheetY(tester), sheetTop);
    });

    testWidgets('less motion: up at once, down at once', (tester) async {
      lessMotion(tester);
      await host(tester, reduceMotion: true);
      await tester.tap(find.text('Open support'));
      await tester.pump();
      expect(await sample(tester, 3, () => sheetY(tester)), <double?>[sheetTop, sheetTop, sheetTop]);
      await settle(tester);
      await tester.tap(find.byTooltip('Close').first);
      await tester.pump();
      expect(sheetY(tester), isNull);
    });

    testWidgets('opened on a conversation (a push tapped): it rises with the sheet, never in from the side', (tester) async {
      final c = await host(tester, screen: GLSupportChatScreen.conversation('conv-1'));
      // What it shows already in (opened before): the conversation is
      // opened in the first frames, as the sheet rises.
      c.attach();
      await settle(tester);
      c.detach();
      await tester.tap(find.text('Open support'));
      await tester.pump();
      final seen = <({double? x, double? y, double? sheet})>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(frame);
        final conv = find.byType(ConversationPage);
        seen.add((
          x: conv.evaluate().isEmpty ? null : tester.getTopLeft(conv).dx,
          y: conv.evaluate().isEmpty ? null : tester.getTopLeft(conv).dy,
          sheet: sheetY(tester),
        ));
      }
      final shown = seen.where((s) => s.x != null).toList();
      expect(shown, isNotEmpty);
      for (final s in shown) {
        expect(s.x, 0, reason: 'no slide from the side');
        expect(s.y, closeTo(s.sheet!, 0.5), reason: 'it rides with the sheet');
      }
      expect(shown.last.y, sheetTop);
    });

    testWidgets('closed from a conversation: it goes down with the sheet, not off to the side', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      await tester.tap(find.byTooltip('Close').last);
      await tester.pump();
      double? lastY;
      for (var i = 0; i < 20; i++) {
        await tester.pump(frame);
        final conv = find.byType(ConversationPage);
        if (conv.evaluate().isEmpty || !tester.getRect(conv).overlaps(const Offset(0, 0) & const Size(390, 844))) break;
        expect(tester.getTopLeft(conv).dx, 0, reason: 'frame ${i + 1}: down, not sideways');
        final y = tester.getTopLeft(conv).dy;
        if (lastY != null) expect(y, greaterThanOrEqualTo(lastY));
        lastY = y;
      }
      await settle(tester);
      expect(find.byType(ConversationPage), findsNothing);
      expect(find.text('Open support'), findsOneWidget);
    });

    testWidgets('a screen opened in the sheet slides in within it and keeps the strip above', (tester) async {
      await host(tester, platform: TargetPlatform.android);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await tester.pump();
      for (var i = 0; i < 30; i++) {
        await tester.pump(frame);
        final conv = find.byType(ConversationPage);
        if (conv.evaluate().isEmpty) continue;
        expect(tester.getTopLeft(conv).dy, greaterThanOrEqualTo(sheetTop - 0.5), reason: 'frame ${i + 1}: never over the strip');
      }
      expect(scrim(tester), messengerScrim, reason: 'the strip stays as dim as it was');
    });
  });
}
