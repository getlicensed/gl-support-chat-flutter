import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/api/client.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/article.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';
import 'package:gl_support_chat/src/ui/sheet.dart';
import 'package:gl_support_chat/src/ui/tabs.dart';

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
    Phone phone = Phone.iphone13,
  }) async {
    usePhone(tester, phone);
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

  /// The product of every fade above [f] (its own and the routes', the
  /// switcher's, the stagger's): how visible it is.
  double opacityOf(WidgetTester tester, Finder f) {
    if (f.evaluate().isEmpty) return 0;
    var o = 1.0;
    for (final e in find.ancestor(of: f.first, matching: find.byType(FadeTransition)).evaluate()) {
      o *= (e.widget as FadeTransition).opacity.value;
    }
    for (final e in find.ancestor(of: f.first, matching: find.byType(Opacity)).evaluate()) {
      o *= (e.widget as Opacity).opacity;
    }
    return o;
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

    testWidgets('less motion: Home, the skeleton, the tabs — everything is simply there, nothing left animating', (tester) async {
      lessMotion(tester);
      server.hold(<String>['/widget/auth']);
      await host(tester, reduceMotion: true);
      await tester.tap(find.text('Open support'));
      await tester.pump();
      await tester.pump(frame);
      expect(find.byType(HomeSkeleton), findsOneWidget);
      await tester.pump(const Duration(seconds: 1)); // the tap's own ripple, in the app
      expect(tester.binding.hasScheduledFrame, isFalse, reason: 'the skeleton does not shimmer');
      server.release();
      await tester.pump();
      await tester.pump();
      await tester.pump(frame);
      expect(find.byType(HomeSkeleton), findsNothing);
      expect(opacityOf(tester, find.text('Send us a message')), 1, reason: 'Home whole at once: no cross-fade, no stagger');
      await tester.tap(find.text('Messages'));
      await tester.pump();
      expect(find.byType(HomeTab), findsNothing, reason: 'the tab changes at once');
      await tester.pump(const Duration(seconds: 1)); // the tap's ripple
      expect(tester.binding.hasScheduledFrame, isFalse);
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

  group('Home', () {
    // Short titles: the test font draws every letter a square, and a title
    // that wraps is a taller row.
    final fiveArticles = <Map<String, dynamic>>[
      for (final t in <String>['Renew a licence', 'ID photos', 'Refunds', 'Book a course', 'Licence cards'])
        <String, dynamic>{'slug': t.toLowerCase().replaceAll(' ', '-'), 'title': t, 'description': null},
    ];

    Finder helpCard() => find.ancestor(of: find.text('Search for help'), matching: find.byType(MessengerCard)).first;
    Finder sendCard(WidgetTester tester) => find.byType(MessengerCard).at(find.text('Recent message').evaluate().isEmpty ? 0 : 1);

    testWidgets('the first open, the server slow: a skeleton from the first frame, cards at their final heights, then Home cross-fades in', (tester) async {
      server.articles = fiveArticles;
      server.conversations = <Map<String, dynamic>>[];
      server.hold(<String>[...GatedServer.opening, '/api/help/articles']);
      // Wide enough that no line wraps in the test font (every letter a
      // square), as none does in a real one on a phone.
      await host(tester, phone: const Phone('wide', Size(1024, 844)));
      await tester.tap(find.text('Open support'));
      await tester.pump();
      // (A pushed page's first frame is built offstage, for its heroes.)
      await tester.pump(frame);
      expect(find.byType(HomeSkeleton), findsOneWidget, reason: 'no spinner on white: Home, as a skeleton');
      await tester.pump(const Duration(milliseconds: 500));
      final skeletonHelp = tester.getSize(helpCard()).height;
      final skeletonSend = tester.getSize(find.byType(MessengerCard).first).height;

      server.release();
      final seen = <double>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(frame);
        seen.add(opacityOf(tester, find.text('Send us a message')));
      }
      final between = seen.where((o) => o > 0.02 && o < 0.98).length;
      expect(between, greaterThanOrEqualTo(8), reason: 'Home comes in over several frames, never in one: $seen');
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1] - 0.001), reason: 'it only ever grows clearer');
      }
      expect(seen.last, 1);
      expect(find.byType(HomeSkeleton), findsNothing);
      expect(tester.getSize(helpCard()).height, closeTo(skeletonHelp, 0.5), reason: 'the help card does not jump (it went 115 → 270 in 0.4.5)');
      expect(tester.getSize(sendCard(tester)).height, closeTo(skeletonSend, 0.5));
    });

    testWidgets("Home's parts come in one after another: the header, then each card 60 ms later, fading as they rise 12 points", (tester) async {
      server.articles = fiveArticles;
      final c = await host(tester);
      c.attach();
      await settle(tester);
      c.detach();
      await tester.tap(find.text('Open support'));
      await tester.pump();
      final greeting = find.text('Hi Ayesha 👋');
      final recent = find.text('Recent message');
      final send = find.text('Send us a message');
      final help = find.text('Search for help');
      expect(find.byType(HomeSkeleton), findsNothing, reason: 'opened before: Home at once');
      final rows = <List<double>>[];
      final rises = <double>[];
      for (var i = 0; i < 32; i++) {
        await tester.pump(frame);
        double own(Finder f) {
          // The stagger's fade only: not the sheet's.
          final fades = find.ancestor(of: f, matching: find.byType(FadeTransition)).evaluate().toList();
          return (fades.first.widget as FadeTransition).opacity.value;
        }

        rows.add(<double>[own(greeting), own(recent), own(send), own(help)]);
        final t = find.ancestor(of: help, matching: find.byType(Transform)).evaluate().first.widget as Transform;
        rises.add(t.transform.getTranslation().y);
      }
      // At 48 ms: the header is coming in, the cards not yet.
      expect(rows[2][0], greaterThan(0.2));
      expect(rows[2][1], 0);
      // At 96 ms the first card has started, the last not.
      expect(rows[5][1], greaterThan(0));
      expect(rows[5][3], 0);
      for (final r in rows) {
        expect(r[0], greaterThanOrEqualTo(r[1]));
        expect(r[1], greaterThanOrEqualTo(r[2]));
        expect(r[2], greaterThanOrEqualTo(r[3]));
      }
      expect(rows.last, <double>[1, 1, 1, 1]);
      expect(rises[12], inExclusiveRange(0, 12), reason: 'the help card rising');
      expect(rises.last, 0);
      final firstMoving = rises.indexWhere((y) => y < 12);
      expect(firstMoving, inInclusiveRange(10, 12), reason: 'the third card starts 180 ms in');
    });

    testWidgets('the help card: skeleton rows of 46 points, then the articles fade in, 30 ms apart', (tester) async {
      server.articles = fiveArticles;
      server.hold(<String>['/api/help/articles']);
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester, frames: 12);
      expect(find.byType(ArticleRowsSkeleton), findsOneWidget);
      final before = tester.getSize(helpCard()).height;
      server.release();
      await tester.pump();
      final first = find.text('Renew a licence');
      final last = find.text('Licence cards');
      final pairs = <(double, double)>[];
      for (var i = 0; i < 20; i++) {
        await tester.pump(frame);
        pairs.add((opacityOf(tester, first), opacityOf(tester, last)));
      }
      expect(pairs.first.$1, inExclusiveRange(0, 1), reason: 'the first row fading in');
      expect(pairs.first.$2, 0, reason: 'the fifth waits its turn');
      expect(pairs.any((p) => p.$2 > 0 && p.$2 < 1), isTrue);
      expect(pairs.last, (1.0, 1.0));
      expect(tester.getSize(helpCard()).height, closeTo(before, 0.5), reason: 'the same height: no jump');
    });

    testWidgets('a picture comes in over its placeholder in 200 ms; one already fetched is simply there', (tester) async {
      final placeholder = Container(key: const ValueKey<String>('initial'));
      final child = Container(key: const ValueKey<String>('photo'));
      final build = fadeOver(placeholder);
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const SizedBox();
      })));
      final waiting = build(context, child, null, false) as Stack;
      expect(waiting.children.first, same(placeholder));
      final fading = waiting.children.last as AnimatedOpacity;
      expect(fading.opacity, 0);
      expect(fading.duration, const Duration(milliseconds: 200));
      final loaded = (build(context, child, 0, false) as Stack).children.last as AnimatedOpacity;
      expect(loaded.opacity, 1, reason: 'then it fades up over the initial');
      expect(build(context, child, 0, true), same(child), reason: 'from the cache: no fade at all');
    });
  });

  group('fetched ahead', () {
    late SessionStore store;

    setUp(() async {
      GLSupportChat.debugReset();
      store = MemorySessionStore();
      GLSupportChat.debugOverride(
        client: server.client(),
        store: store,
        realtime: ({required String apiUrl, required String Function() token}) => FakeChannel(),
      );
    });
    tearDown(GLSupportChat.debugReset);

    Future<BuildContext> app(WidgetTester tester) async {
      late BuildContext context;
      usePhone(tester, Phone.iphone13);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const Scaffold(body: Text('The app'));
      })));
      return context;
    }

    int count(String what) => server.paths.where((p) => p == what).length;

    // Configured on the real clock: its badge polling is a real timer.
    Future<void> configure(WidgetTester tester) => tester.runAsync(() async {
          await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'product-1');
          await Future<void>.delayed(Duration.zero); // the look read back from the store
        });

    testWidgets('after login, Home is fetched in the background: present shows it in the first frame, signed in once, not live until opened', (tester) async {
      server.articles = <Map<String, dynamic>>[<String, dynamic>{'slug': 'renew', 'title': 'How do I renew my SIA licence?', 'description': null}];
      await configure(tester);
      final host = await app(tester);
      expect(await GLSupportChat.login(const GLSupportChatIdentity(id: 'A', name: 'Ayesha Khan', hash: 'h')), isTrue);
      await tester.pump();
      await tester.pump();
      expect(server.paths, contains('GET /widget/conversations'), reason: 'the Messages list, for Home');
      expect(server.paths, contains('GET /api/help/articles'), reason: 'the top articles, for Home');
      expect(server.paths, isNot(contains('GET /widget/messages')), reason: 'the open conversation waits for the open');
      expect(GLSupportChat.debugMessenger!.phase, MessengerPhase.ready);
      expect(GLSupportChat.debugMessenger!.link, LinkState.connecting, reason: 'no connection until it is opened');

      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(frame);
      expect(find.byType(HomeSkeleton), findsNothing);
      expect(find.text('Hi Ayesha 👋'), findsOneWidget);
      expect(find.text('How do I renew my SIA licence?'), findsOneWidget);
      await settle(tester);
      expect(count('POST /widget/auth'), 1, reason: "login's sign-in, used for both");
      Navigator.of(host, rootNavigator: true).pop();
      await settle(tester);
    });

    testWidgets("signed out while open: the skeleton never greets the next customer with the last one's name", (tester) async {
      await configure(tester);
      final host = await app(tester);
      await GLSupportChat.login(const GLSupportChatIdentity(id: 'A', name: 'Ayesha Khan', hash: 'h'));
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      expect(find.text('Hi Ayesha 👋'), findsOneWidget);
      server.hold(<String>['/widget/auth']);
      unawaited(GLSupportChat.logout());
      await settle(tester, frames: 4);
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(find.textContaining('Ayesha'), findsNothing, reason: 'nobody signed in now');
      unawaited(GLSupportChat.login(const GLSupportChatIdentity(id: 'B', name: 'Bilal Ahmed', hash: 'h')));
      await settle(tester, frames: 4);
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(find.text('Hi Bilal 👋'), findsOneWidget, reason: "the app's word for who it is, until the server's");
      expect(find.textContaining('Ayesha'), findsNothing);
      server.release();
      await settle(tester);
      Navigator.of(host, rootNavigator: true).pop();
      await settle(tester);
    });

    testWidgets('opened while the fetch ahead is out, then someone else signs in: one start, for them', (tester) async {
      final ready = <Map<String, Object?>>[];
      await tester.runAsync(() => GLSupportChat.configure(
            apiUrl: 'https://api.test',
            productId: 'product-1',
            onDiagnostic: (event, detail) {
              if (event == 'messenger_ready') ready.add(detail);
            },
          ));
      final host = await app(tester);
      server.hold(<String>['/widget/conversations']);
      await GLSupportChat.login(const GLSupportChatIdentity(id: 'A', name: 'Ayesha Khan', hash: 'h'));
      await tester.pump();
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      unawaited(GLSupportChat.login(const GLSupportChatIdentity(id: 'B', name: 'Bilal Ahmed', hash: 'h')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      server.release();
      await settle(tester, frames: 40);
      expect(ready, hasLength(1), reason: 'one start, not the first one carrying on for the next customer');
      expect(server.paths.where((p) => p == 'GET /widget/messages').length, 1);
      Navigator.of(host, rootNavigator: true).pop();
      await settle(tester);
    });

    testWidgets("after an app restart the skeleton is in last time's colour, logo, greeting and team", (tester) async {
      server.session = <String, dynamic>{
        ...server.session,
        'brandColor': '#0A7D4F',
        'welcomeGreeting': 'Hello from GuardPass',
        'identified': null,
        'team': <Object?>[
          <String, dynamic>{'name': 'Levi John', 'initials': 'LJ', 'avatarUrl': null},
          <String, dynamic>{'name': 'Nur Din', 'initials': 'ND', 'avatarUrl': null},
        ],
      };
      // A launch that signed in once: the look is kept.
      await configure(tester);
      final host = await app(tester);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      Navigator.of(host, rootNavigator: true).pop();
      await settle(tester);
      expect(await store.look('product-1'), isNotNull, reason: 'kept on the phone');
      expect((await store.look('product-1'))!['brandColor'], '#0A7D4F');

      // The next launch: nothing in memory, the server slow.
      GLSupportChat.debugReset();
      GLSupportChat.debugOverride(client: server.client(), store: store, realtime: ({required String apiUrl, required String Function() token}) => FakeChannel());
      await configure(tester);
      server.hold(<String>['/widget/auth']);
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(HomeSkeleton), findsOneWidget);
      expect(find.text('Hello from GuardPass'), findsOneWidget, reason: "the chatbot's greeting, not a bar");
      expect(find.byType(TeamFaces), findsOneWidget);
      final band = find.descendant(of: find.byType(HomeSkeleton), matching: find.byType(Container)).evaluate().map((e) => (e.widget as Container).decoration).whereType<BoxDecoration>().firstWhere((d) => d.gradient != null);
      expect((band.gradient! as LinearGradient).colors[1], const Color(0xFF0A7D4F), reason: 'the band in the chatbot colour from the first frame');
      server.release();
      await settle(tester);
      Navigator.of(host, rootNavigator: true).pop();
      await settle(tester);
    });
  });

  group('articles', () {
    final renew = <String, dynamic>{
      'slug': 'renew',
      'title': 'Renewing',
      'description': 'Three steps.',
      'html': '<h1>Before you start</h1><p>You can renew up to four months early.</p>'
          '<ul><li><p>Have your licence number ready:<br>\u200B</p></li></ul>'
          '<p><a href="https://www.get-licensed.co.uk/">Book A Course</a></p>'
          '<p>Or read the <a href="https://www.gov.uk/sia">SIA pages</a> first.</p>',
      'url': 'https://help.test/help/renew',
    };

    setUp(() {
      server.articles = <Map<String, dynamic>>[<String, dynamic>{'slug': 'renew', 'title': 'Renewing', 'description': null}];
      server.article = renew;
    });

    /// The size of the text run that says [text] in an article's HTML.
    double? fontSizeOf(WidgetTester tester, String text) {
      for (final e in find.byType(RichText).evaluate()) {
        double? found;
        (e.widget as RichText).text.visitChildren((span) {
          if (span is TextSpan && span.text == text) {
            found = span.style?.fontSize;
            return false;
          }
          return true;
        });
        if (found != null) return found;
      }
      return null;
    }

    testWidgets('three skeleton bars, then the article fades in as it rises 8 points', (tester) async {
      server.hold(<String>['/api/help/articles/renew']);
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Renewing'));
      await settle(tester);
      expect(find.byType(ArticleSkeleton), findsOneWidget, reason: 'not "Loading…"');
      expect(find.text('Loading…'), findsNothing);
      server.release();
      await tester.pump();
      final body = find.text('You can renew up to four months early.', findRichText: true);
      final seen = <(double, double)>[];
      for (var i = 0; i < 16; i++) {
        await tester.pump(frame);
        if (body.evaluate().isEmpty) continue;
        final rise = find.ancestor(of: body, matching: find.byType(Transform)).evaluate().map((e) => (e.widget as Transform).transform.getTranslation().y).where((y) => y > 0);
        seen.add((opacityOf(tester, body), rise.isEmpty ? 0 : rise.first));
      }
      expect(seen.where((s) => s.$1 > 0.02 && s.$1 < 0.98).length, greaterThanOrEqualTo(6), reason: 'a fade over frames, not a pop: $seen');
      expect(seen.first.$2, inExclusiveRange(4, 8.01), reason: 'it starts lower');
      expect(seen.last, (1.0, 0.0));
      expect(find.byType(ArticleSkeleton), findsNothing);
    });

    testWidgets('the top five are fetched while Home shows: one opened is there in the first frame', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      expect(server.paths, contains('GET /api/help/articles/renew'), reason: 'fetched ahead');
      await tester.tap(find.text('Renewing'));
      await tester.pump();
      await tester.pump(frame);
      expect(find.byType(ArticleSkeleton), findsNothing);
      expect(find.text('You can renew up to four months early.', findRichText: true), findsOneWidget);
      expect(server.paths.where((p) => p == 'GET /api/help/articles/renew').length, 1, reason: 'once a session');
      await settle(tester);
      await tester.tap(find.byTooltip('Back'));
      await settle(tester);
      await tester.tap(find.text('Renewing').first);
      await settle(tester);
      expect(server.paths.where((p) => p == 'GET /api/help/articles/renew').length, 1, reason: 'opened again: from memory');
    });

    testWidgets("a paragraph that is only a link is a button in the brand colour; a link in a sentence stays a link; headings below the title's size", (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Renewing'));
      await settle(tester);
      final button = find.widgetWithText(FilledButton, 'Book A Course');
      expect(button, findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(44));
      final style = tester.widget<FilledButton>(button).style!;
      expect(style.backgroundColor!.resolve(<WidgetState>{}), const Color(0xFF1F6FEB), reason: "the chatbot's colour");
      expect(style.foregroundColor!.resolve(<WidgetState>{}), Colors.white);
      expect(style.padding!.resolve(<WidgetState>{}), const EdgeInsets.symmetric(horizontal: 20, vertical: 12));
      expect(find.widgetWithText(FilledButton, 'SIA pages'), findsNothing, reason: 'a link inside a sentence');
      expect(find.text('Or read the SIA pages first.', findRichText: true), findsOneWidget);
      expect(fontSizeOf(tester, 'Before you start'), 20, reason: 'h1 at 20, under the 22-point title');
      expect(find.text('Have your licence number ready:', findRichText: true), findsOneWidget, reason: 'the stray line break and zero-width space gone');
      expect(tidyArticleHtml('<li><p>Ready:<br>\u200B</p></li><p>Go<br/> </p>'), '<li><p>Ready:</p></li><p>Go</p>');
      final open = find.ancestor(of: find.text('Open in the help centre'), matching: find.byType(TextButton));
      expect(tester.getSize(open).height, greaterThanOrEqualTo(44));
      expect(tester.getCenter(open).dx, closeTo(195, 1), reason: 'centred, with room around it');
    });
  });

  group('the thread', () {
    Finder page() => find.byType(ConversationPage);
    Finder threadList() => find.descendant(of: page(), matching: find.byType(ListView));
    Finder field() => find.descendant(of: page(), matching: find.byType(TextField)).last;

    /// The top of the composer (the thread above it ends there; the thread's
    /// own rect also moves with its glide).
    double footerTop(WidgetTester tester) => tester.getTopLeft(find.descendant(of: page(), matching: find.byType(AnimatedSize)).last).dy;

    Future<ManualChannel> openChat(WidgetTester tester) async {
      final manual = ManualChannel(autoConnect: true);
      usePhone(tester, Phone.iphone13);
      final c = controllerOn(server, manual);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1')),
      ));
      await settle(tester, frames: 14);
      expect(page(), findsOneWidget);
      return manual;
    }

    testWidgets('the composer grows a line at a time over 150 ms, and the thread with it — no 46-point jump; it shrinks the same way on Send', (tester) async {
      final manual = await openChat(tester);
      manual.answers['visitor:message'] = echo(<String>[]);
      final one = tester.getSize(field()).height;
      final before = footerTop(tester);
      await tester.enterText(field(), 'line one\nline two\nline three');
      await tester.pump();
      final tops = await sample(tester, 12, () => footerTop(tester));
      final steps = <double>[before, ...tops];
      var moving = 0;
      for (var i = 1; i < steps.length; i++) {
        final d = steps[i - 1] - steps[i];
        expect(d, greaterThanOrEqualTo(-0.01), reason: 'growing only');
        expect(d, lessThan(30), reason: 'frame $i moved ${d.toStringAsFixed(1)}: no jump');
        if (d > 0.5) moving++;
      }
      expect(moving, greaterThanOrEqualTo(4), reason: 'over several frames');
      // One line, the row is the photo button's 48; three, the field's.
      expect(before - steps.last, closeTo(tester.getSize(field()).height - (one > 48 ? one : 48), 0.5), reason: 'by exactly the two lines');

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      final back = await sample(tester, 14, () => footerTop(tester));
      expect(back.first, lessThan(before - 10), reason: 'not snapped back in one frame');
      expect(back.last, closeTo(before, 0.5));
    });

    testWidgets('Send: the bubble is whole at once; "Sending…" only after 600 ms; the server\'s copy keeps the row, its time fading in', (tester) async {
      final manual = await openChat(tester);
      manual.answers['visitor:message'] = echo(<String>[]);
      manual.holdAcks = Completer<void>();
      await tester.enterText(field(), 'Is it posted?');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      final bubble = find.descendant(of: threadList(), matching: find.text('Is it posted?'));
      final sending = find.text('Sending…');
      final early = <(double, double)>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(frame);
        early.add((opacityOf(tester, bubble), opacityOf(tester, sending)));
      }
      for (var i = 0; i < 40; i++) {
        expect(early[i].$1, 1, reason: 'frame ${i + 1}: whole, never dimmed or faded');
        if ((i + 1) * 16 < 600) expect(early[i].$2, 0, reason: 'frame ${i + 1}: nothing said yet');
      }
      expect(early.last.$2, greaterThan(0), reason: 'slow: now it says so');
      final row = find.byKey(const ValueKey<String>('out:local-1'));
      expect(row, findsWidgets);
      manual.holdAcks!.complete();
      final after = <(double, double)>[];
      for (var i = 0; i < 14; i++) {
        await tester.pump(frame);
        after.add((opacityOf(tester, sending), opacityOf(tester, find.byIcon(Icons.done).last)));
      }
      expect(row, findsWidgets, reason: 'the same row, now the server\'s copy');
      expect(find.byKey(const ValueKey<String>('msg:sent-1')), findsNothing);
      expect(after.where((a) => a.$1 > 0.02 && a.$1 < 0.98).length, greaterThanOrEqualTo(3), reason: '"Sending…" fades: $after');
      expect(after.last, (0.0, 1.0));
      expect(opacityOf(tester, bubble), 1);
    });

    testWidgets('the open conversation, the first time: a spinner, then the thread fades in; the composer waits at its own height', (tester) async {
      server.hold(<String>['/widget/messages']);
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      expect(find.descendant(of: page(), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.descendant(of: page(), matching: find.byType(TextField)), findsNothing, reason: 'nothing to type in yet');
      expect(find.text('Loading…'), findsOneWidget, reason: 'the locked composer says why');
      final lockedTop = tester.getTopLeft(find.text('Loading…')).dy;
      server.release();
      await tester.pump();
      final seen = <double>[];
      for (var i = 0; i < 16; i++) {
        await tester.pump(frame);
        seen.add(opacityOf(tester, find.descendant(of: page(), matching: find.text('Let me check.'))));
      }
      expect(seen.where((o) => o > 0.02 && o < 0.98).length, greaterThanOrEqualTo(5), reason: 'a fade, not a pop: $seen');
      expect(seen.last, 1);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.getTopLeft(find.text('Type a message…')).dy, closeTo(lockedTop, 0.5), reason: 'the composer did not move');
    });

    testWidgets('a past conversation opened again is there at once, and refreshes behind', (tester) async {
      server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Let me check.'), row('old', open: false, body: 'Your refund has gone through.')];
      server.details['old'] = detail('old', <Map<String, dynamic>>[
        msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old'),
        msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old'),
      ], open: false);
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Messages'));
      await settle(tester);
      await tester.tap(find.text('Your refund has gone through.'));
      await settle(tester);
      expect(find.text('Can I have a refund?'), findsOneWidget);
      await tester.tap(find.byTooltip('Back').last);
      await settle(tester);

      server.hold(<String>['/widget/conversations/old']);
      server.details['old'] = detail('old', <Map<String, dynamic>>[
        msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old'),
        msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old'),
        msg('c', 'agent', 'And the receipt is on its way.', conversationId: 'old'),
      ], open: false);
      await tester.tap(find.text('Your refund has gone through.').first);
      await tester.pump();
      await tester.pump(frame);
      expect(find.text('Can I have a refund?'), findsOneWidget, reason: 'what it said last time, before any answer');
      expect(find.descendant(of: page(), matching: find.byType(CircularProgressIndicator)), findsNothing);
      server.release();
      await settle(tester);
      expect(find.text('And the receipt is on its way.'), findsOneWidget, reason: 'refreshed behind');
    });

    testWidgets("the workflow's picture holds its 4:3 room from the start", (tester) async {
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('p', 'bot', 'Here is the map.', meta: <String, dynamic>{
          'image': <String, dynamic>{'url': 'https://cdn.test/map.png'},
        }),
      ]);
      await openChat(tester);
      final box = find.descendant(of: threadList(), matching: find.byType(AspectRatio));
      expect(box, findsOneWidget);
      final size = tester.getSize(box);
      expect(size.width / size.height, closeTo(4 / 3, 0.01));
      expect(size.height, greaterThan(100), reason: 'its room taken before the picture loads');
    });
  });

  group('tabs and small bars', () {
    testWidgets('tabs fade through: out in 90 ms, in over 210 ms from 92%; never two at once; the status bar changes with what shows', (tester) async {
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      Finder over(Type tab, Type t) => find.descendant(of: find.byType(MessengerTabs), matching: find.ancestor(of: find.byType(tab), matching: find.byType(t)));
      double fade(Type tab) => over(tab, FadeTransition).evaluate().isEmpty ? 0 : tester.widget<FadeTransition>(over(tab, FadeTransition).first).opacity.value;
      double scale(Type tab) => tester.widget<ScaleTransition>(over(tab, ScaleTransition).first).scale.value;
      SystemUiOverlayStyle style() => tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.descendant(of: find.byType(MessengerTabs), matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first).value;
      await tester.tap(find.text('Messages'));
      await tester.pump();
      final frames = <(double, double, double, Brightness?)>[];
      for (var i = 0; i < 22; i++) {
        await tester.pump(frame);
        frames.add((fade(HomeTab), fade(MessagesTab), scale(MessagesTab), style().statusBarIconBrightness));
      }
      var homeFrames = 0;
      var messagesFrames = 0;
      for (final f in frames) {
        expect(f.$1 == 0 || f.$2 == 0, isTrue, reason: 'one tab at a time: $f');
        if (f.$1 > 0) {
          homeFrames++;
          expect(f.$4, Brightness.light, reason: 'Home on screen: icons for the brand band');
        }
        if (f.$2 > 0) {
          messagesFrames++;
          expect(f.$4, Brightness.dark, reason: 'Messages on screen: icons for white');
          expect(f.$3, greaterThanOrEqualTo(0.92));
        }
      }
      expect(homeFrames, inInclusiveRange(3, 6), reason: 'Home goes in about 90 ms');
      expect(messagesFrames, greaterThanOrEqualTo(10), reason: 'Messages comes in over about 210 ms');
      expect(frames.firstWhere((f) => f.$2 > 0).$3, lessThan(0.95), reason: 'from about 92%');
      expect(frames.last.$2, 1);
      expect(frames.last.$3, 1);
    });

    testWidgets('"Reconnecting…" opens over 200 ms and closes the same way, never in one frame', (tester) async {
      final manual = ManualChannel(autoConnect: true);
      usePhone(tester, Phone.iphone13);
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: controllerOn(server, manual), screen: GLSupportChatScreen.conversation('conv-1'))));
      await settle(tester, frames: 14);
      final bar = find.byType(ConnectionBar);
      manual.drop();
      await tester.pump();
      final open = await sample(tester, 16, () => tester.getSize(bar).height);
      expect(open.where((h) => h > 0.5 && h < open.last - 0.5).length, greaterThanOrEqualTo(4), reason: 'opening: $open');
      for (var i = 1; i < open.length; i++) {
        expect(open[i] - open[i - 1], lessThan(14), reason: 'no jump');
      }
      expect(find.text('Reconnecting…'), findsOneWidget);
      manual.open();
      await tester.pump();
      final close = await sample(tester, 16, () => tester.getSize(bar).height);
      expect(close.where((h) => h > 0.5 && h < open.last - 0.5).length, greaterThanOrEqualTo(4), reason: 'closing: $close');
      expect(close.last, 0);
      expect(find.text('Reconnecting…'), findsNothing);
    });

    testWidgets('the "New message" pill fades in and out', (tester) async {
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++)
          msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
      ]);
      final manual = ManualChannel(autoConnect: true);
      usePhone(tester, Phone.iphone13);
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: controllerOn(server, manual), screen: GLSupportChatScreen.conversation('conv-1'))));
      await settle(tester, frames: 14);
      final list = find.descendant(of: find.byType(ConversationPage), matching: find.byType(ListView));
      await tester.drag(list, const Offset(0, 600));
      await settle(tester);
      manual.server('message:created', msg('r1', 'agent', 'Found it.', at: at(40)));
      await tester.pump();
      final pill = find.text('New message');
      final shown = await sample(tester, 14, () => opacityOf(tester, pill));
      expect(shown.where((o) => o > 0.02 && o < 0.98).length, greaterThanOrEqualTo(4), reason: 'fading in: $shown');
      expect(shown.last, 1);
      await tester.tap(pill);
      await tester.pump();
      final gone = await sample(tester, 14, () => opacityOf(tester, pill));
      expect(gone.where((o) => o > 0.02 && o < 0.98).length, greaterThanOrEqualTo(3), reason: 'fading out: $gone');
      expect(pill, findsNothing);
    });
  });

  group('reactions under an article', () {
    late List<(String, Map<String, Object?>)> diagnostics;

    setUp(() {
      diagnostics = <(String, Map<String, Object?>)>[];
      server.article = <String, dynamic>{
        'slug': 'renew',
        'title': 'Renewing',
        'description': null,
        'html': '<p>You can renew up to four months early.</p>',
        'url': 'https://help.test/help/renew',
      };
    });

    Future<MessengerController> openArticle(WidgetTester tester) async {
      usePhone(tester, const Phone('tall', Size(390, 1400)));
      final api = server.api();
      api.reauthenticate = () async => (await api.authenticate()).token;
      final c = MessengerController(
        api: api,
        signIn: () => api.authenticate(visitorId: 'visitor-1'),
        realtimeFactory: ({required String apiUrl, required String Function() token}) => FakeChannel(),
        onDiagnostic: (event, detail) => diagnostics.add((event, detail)),
      );
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.iOS),
        home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.article('renew')),
      ));
      await settle(tester, frames: 14);
      expect(find.text('Did this answer your question?'), findsOneWidget);
      return c;
    }

    List<Map<String, dynamic>> sent() => server.requests
        .where((r) => r.url.path == '/widget/article-reaction')
        .map((r) => (jsonDecode(r.body) as Map).cast<String, dynamic>()..['auth'] = r.headers['authorization'])
        .toList();

    Finder face(String label) => find.bySemanticsLabel(label);
    /// How large the face is drawn now (not where it is going).
    double scaleOf(WidgetTester tester, String emoji) =>
        tester.widget<ScaleTransition>(find.descendant(of: find.ancestor(of: find.text(emoji), matching: find.byType(AnimatedScale)), matching: find.byType(ScaleTransition))).scale.value;

    testWidgets('three faces, named and 56 points each; a tap sends {slug, reaction} with the visitor token, the face grows and the others fade', (tester) async {
      final semantics = tester.ensureSemantics();
      await openArticle(tester);
      for (final label in <String>['Disappointed', 'Neutral', 'Smiley']) {
        expect(face(label), findsOneWidget);
        expect(tester.getSize(find.ancestor(of: find.text(<String, String>{'Disappointed': '😞', 'Neutral': '😐', 'Smiley': '😃'}[label]!), matching: find.byType(InkWell))).width, greaterThanOrEqualTo(44));
      }
      await tester.tap(find.text('😃'));
      await tester.pump();
      final grows = await sample(tester, 14, () => scaleOf(tester, '😃'));
      expect(grows.where((s) => s > 1.01 && s < 1.29).length, greaterThanOrEqualTo(3), reason: 'it grows over frames: $grows');
      expect(scaleOf(tester, '😃'), 1.3);
      expect(opacityOf(tester, find.text('😞')), closeTo(0.4, 0.01));
      expect(opacityOf(tester, find.text('😐')), closeTo(0.4, 0.01));
      expect(sent(), <Map<String, dynamic>>[<String, dynamic>{'slug': 'renew', 'reaction': 'happy', 'auth': 'Bearer tok-1'}]);
      expect(find.text('Still need help?'), findsNothing, reason: 'only after 😞');

      await tester.tap(find.text('😐'));
      await settle(tester, frames: 5);
      expect(sent().last['reaction'], 'neutral', reason: 'the choice can change');
      expect(scaleOf(tester, '😐'), 1.3);
      expect(scaleOf(tester, '😃'), 1);
      semantics.dispose();
    });

    for (final status in <int>[400, 401, 404, 429]) {
      testWidgets('the server says $status: the choice stays, nothing on screen, a diagnostic', (tester) async {
        server.reactionStatus = status;
        await openArticle(tester);
        await tester.tap(find.text('😐'));
        await settle(tester, frames: 6);
        expect(scaleOf(tester, '😐'), 1.3, reason: 'still chosen');
        expect(find.byType(SnackBar), findsNothing);
        expect(find.textContaining('nope'), findsNothing);
        expect(diagnostics.where((d) => d.$1 == 'article_reaction_failed').single.$2, <String, Object?>{'status': status, 'slug': 'renew'});
      });
    }

    testWidgets('after 😞: "Still need help?" and a way into the conversation', (tester) async {
      await openArticle(tester);
      await tester.tap(find.text('😞'));
      await tester.pump();
      final heights = await sample(tester, 14, () => tester.getSize(find.byType(ArticleReactions)).height);
      expect(heights.where((h) => h > heights.first + 1 && h < heights.last - 1).length, greaterThanOrEqualTo(3), reason: 'it opens, not pops: $heights');
      expect(find.text('Still need help?'), findsOneWidget);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      expect(find.byType(ConversationPage), findsOneWidget);
      expect(tester.widget<ConversationPage>(find.byType(ConversationPage)).conversationId, isNull, reason: 'the live conversation');
    });

    testWidgets('remembered for the article while signed in', (tester) async {
      final c = await openArticle(tester);
      await tester.tap(find.text('😃'));
      await settle(tester, frames: 5);
      expect(c.reactions, <String, String>{'renew': 'happy'});
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.article('renew'))));
      await settle(tester, frames: 14);
      expect(scaleOf(tester, '😃'), 1.3, reason: 'opened again: still chosen');
      c.reset();
      expect(c.reactions, isEmpty, reason: 'gone with the customer');
    });

    test('the API call: POST /widget/article-reaction with the bearer token, as every /widget call', () async {
      final api = server.api()..token = 'tok-9';
      await api.articleReaction('renew', 'sad');
      final r = server.requests.single;
      expect('${r.method} ${r.url}', 'POST https://api.test/widget/article-reaction');
      expect(r.headers['authorization'], 'Bearer tok-9');
      expect(jsonDecode(r.body), <String, dynamic>{'slug': 'renew', 'reaction': 'sad'});
      server.reactionStatus = 429;
      await expectLater(api.articleReaction('renew', 'sad'), throwsA(isA<ApiException>().having((e) => e.status, 'status', 429)));
    });
  });

  // Found by a review of the first version of 0.4.6 (15 Oct).
  group('review', () {
    testWidgets('fetched ahead but never opened: the app coming back to the front opens no connection', (tester) async {
      var channels = 0;
      final api = server.api();
      final c = MessengerController(
        api: api,
        signIn: () => api.authenticate(visitorId: 'visitor-1'),
        realtimeFactory: ({required String apiUrl, required String Function() token}) {
          channels++;
          return FakeChannel();
        },
      );
      addTearDown(c.dispose);
      await c.prefetch();
      await tester.pump();
      expect(c.phase, MessengerPhase.ready);
      c.lifecycleChanged(AppLifecycleState.inactive);
      c.lifecycleChanged(AppLifecycleState.paused);
      c.lifecycleChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(channels, 0, reason: 'nothing on screen: nothing live');
      expect(server.paths, isNot(contains('GET /widget/messages')));
    });

    testWidgets("a pull on Home that loses its list (a sign-out under the finger) springs back, and the app takes taps again", (tester) async {
      server.articles = <Map<String, dynamic>>[
        for (var i = 0; i < 5; i++) <String, dynamic>{'slug': 'a$i', 'title': 'Article number $i about the licence', 'description': null},
      ];
      final c = await host(tester, phone: Phone.iphoneSE);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      final top = sheetY(tester)!;
      final g = await tester.startGesture(tester.getCenter(find.text('Send us a message')));
      for (var i = 0; i < 4; i++) {
        await g.moveBy(const Offset(0, 25));
        await tester.pump(frame);
      }
      expect(sheetY(tester), greaterThan(top + 30), reason: 'held part way down');
      c.reset(); // Home goes for the skeleton, under the finger
      await settle(tester, frames: 3);
      await g.up();
      await settle(tester);
      expect(sheetY(tester), top, reason: 'back up, not left half down');
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      expect(navigator.userGestureInProgress, isFalse, reason: 'no gesture left open');
      await tester.tap(find.byTooltip('Close').first);
      await settle(tester);
      expect(find.byType(GLSupportChatPage), findsNothing, reason: 'it still takes taps');
    });

    testWidgets("Android's back while the sheet is held: it goes down when let go, never left on screen out of the history", (tester) async {
      await host(tester, platform: TargetPlatform.android);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('Search for help')));
      for (var i = 0; i < 3; i++) {
        await g.moveBy(const Offset(0, 20));
        await tester.pump(frame);
      }
      await tester.binding.handlePopRoute();
      await tester.pump(frame);
      for (var i = 0; i < 3; i++) {
        await g.moveBy(const Offset(0, -20));
        await tester.pump(frame);
      }
      await g.up();
      await settle(tester);
      expect(find.byType(GLSupportChatPage), findsNothing);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      expect(find.byType(GLSupportChatPage), findsOneWidget, reason: 'the app works as before');
    });

    testWidgets('a list pulled, pushed back past the top and pulled again, in one touch: the sheet stays with the finger', (tester) async {
      server.articles = <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++) <String, dynamic>{'slug': 'a$i', 'title': 'Article number $i about the licence', 'description': null},
      ];
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Help').last);
      await settle(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('Article number 2 about the licence')));
      Future<void> move(double dy, int times) async {
        for (var i = 0; i < times; i++) {
          await g.moveBy(Offset(0, dy));
          await tester.pump(frame);
        }
      }

      await move(20, 4); // down: the sheet comes
      await move(-20, 6); // back up past the top: the sheet settles, the list takes the rest
      await move(20, 6); // and down again
      final held = sheetY(tester)!;
      expect(held, greaterThan(sheetTop + 20), reason: "pulling again");
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(frame);
      expect(sheetY(tester), closeTo(held, 0.5), reason: 'the first settling does not take it from the finger');
      await g.up();
      await settle(tester);
      expect(sheetY(tester), sheetTop);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
      expect(navigator.userGestureInProgress, isFalse);
    });

    testWidgets('a conversation opened over the tabs while it signs in goes when the sign-in fails: the way out shows', (tester) async {
      server.hold(<String>['/widget/auth']);
      await host(tester);
      await tester.tap(find.text('Open support'));
      await settle(tester);
      await tester.tap(find.text('Messages'));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      expect(find.byType(ConversationPage), findsOneWidget);
      server.failing['/widget/auth'] = 500;
      server.release();
      await settle(tester, frames: 20);
      expect(find.byType(ConversationPage), findsNothing);
      expect(find.text("We can't open the chat right now"), findsOneWidget);
    });
  });
}
