import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
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
}
