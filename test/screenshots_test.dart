import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/messenger_page.dart';

import 'support/fakes.dart';
import 'support/gated.dart';

// Not a check: renders the main screens to test/screens/*.png (gitignored)
// with real fonts, to look at a change without a phone.
//
//   GL_SCREENSHOTS=1 flutter test test/screenshots_test.dart
//
// Emoji draw as boxes here (no emoji font in tests); on a phone they are fine.
void main() {
  final enabled = Platform.environment['GL_SCREENSHOTS'] == '1';

  setUpAll(() async {
    if (!enabled) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    final root = Platform.environment['FLUTTER_ROOT'] ?? '/opt/homebrew/share/flutter';
    final dir = '$root/bin/cache/artifacts/material_fonts';
    Future<ByteData> font(String file) async => ByteData.view((await File('$dir/$file').readAsBytes()).buffer);
    final roboto = FontLoader('Roboto');
    for (final f in <String>['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf', 'Roboto-Black.ttf']) {
      roboto.addFont(font(f));
    }
    await roboto.load();
    await (FontLoader('MaterialIcons')..addFont(font('MaterialIcons-Regular.otf'))).load();
  });

  FakeServer seeded() {
    final server = FakeServer();
    server.articles = <Map<String, dynamic>>[
      <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': 'Three steps, about ten minutes.'},
      <String, dynamic>{'slug': 'id-photo', 'title': 'Taking a good ID photo', 'description': 'Light, background and size.'},
      <String, dynamic>{'slug': 'refunds', 'title': 'Refunds and cancellations', 'description': null},
    ];
    server.article = <String, dynamic>{
      'slug': 'renew-sia',
      'title': 'How do I renew my SIA licence?',
      'description': 'Three steps, about ten minutes.',
      'html': '<p>You can renew up to <strong>four months</strong> before your licence expires.</p>'
          '<h2>What you need</h2><ul><li><p>Your current licence number<br>\u200B</p></li><li><p>A recent photo</p></li><li><p>A valid first aid certificate</p></li></ul>'
          '<p>Then apply on the <a href="https://www.gov.uk/sia">SIA website</a>, or book your refresher with us:</p>'
          '<p><a href="https://www.get-licensed.co.uk/">Book A Course</a></p>',
      'url': 'https://help.test/help/renew-sia',
    };
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
    server.conversations = <Map<String, dynamic>>[
      row('conv-1', body: 'Which course is it about?', authorType: 'bot', at: DateTime.now().subtract(const Duration(minutes: 3)).toUtc().toIso8601String()),
      row('old', open: false, body: 'Your refund has gone through.', at: '2026-09-21T10:00:00.000Z'),
    ];
    final t = DateTime.now().subtract(const Duration(minutes: 9));
    String at(int m) => t.add(Duration(minutes: m)).toUtc().toIso8601String();
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('m1', 'visitor', 'Hi, my licence card has not arrived yet.', at: at(0)),
      msg('m2', 'agent', 'Sorry to hear that, Ayesha. Let me check — it was posted on 2 October. See https://www.gov.uk/sia for delivery times.', at: at(2)),
      msg('m3', 'visitor', 'Thank you!', at: at(3)),
      msg('m4', 'ai', 'While you wait: most cards arrive within 5 working days.', authorName: 'GL Assistant', at: at(5)),
      msg('p1', 'bot', 'Which course is it about?', at: at(6), meta: <String, dynamic>{
        'buttons': <Object?>[
          <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'},
          <String, dynamic>{'id': 'b2', 'label': 'CCTV'},
        ],
        'lockComposer': true,
      }),
    ], agentLastSeenAt: at(4));
    server.details['old'] = detail('old', <Map<String, dynamic>>[
      msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old', at: '2026-09-21T09:50:00.000Z'),
      msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old', at: '2026-09-21T10:00:00.000Z'),
      msg('c', 'bot', 'How would you rate the help you received?', conversationId: 'old', at: '2026-09-21T10:01:00.000Z', meta: <String, dynamic>{
        'csat': <String, dynamic>{'ratingId': 'r1'},
      }),
    ], open: false);
    return server;
  }

  Future<void> render(WidgetTester tester, String name, Future<void> Function(WidgetTester tester) go, {FakeServer? server}) async {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    addTearDown(tester.view.reset);
    final channel = FakeChannel();
    final c = controllerFor(server ?? seeded(), channel);
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey<String>('screen'),
      child: MaterialApp(debugShowCheckedModeBanner: false, home: GLSupportChatPage(controller: c)),
    ));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 1});
    await go(tester);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    autoUpdateGoldenFiles = true;
    await expectLater(find.byKey(const ValueKey<String>('screen')), matchesGoldenFile('screens/$name.png'));
    autoUpdateGoldenFiles = false;
  }

  Future<void> nothing(WidgetTester _) async {}

  testWidgets('home', (t) => render(t, 'home', nothing), skip: !enabled);
  testWidgets('messages', (t) => render(t, 'messages', (t) => t.tap(find.text('Messages'))), skip: !enabled);
  testWidgets('help', (t) => render(t, 'help', (t) => t.tap(find.text('Help').last)), skip: !enabled);
  testWidgets('conversation', (t) => render(t, 'conversation', (t) => t.tap(find.text('Send us a message'))), skip: !enabled);
  testWidgets('closed conversation', (t) => render(t, 'closed', (t) async {
        await t.tap(find.text('Messages'));
        for (var i = 0; i < 4; i++) {
          await t.pump(const Duration(milliseconds: 60));
        }
        await t.tap(find.text('Your refund has gone through.'));
      }), skip: !enabled);
  testWidgets('article', (t) => render(t, 'article', (t) => t.tap(find.text('How do I renew my SIA licence?'))), skip: !enabled);
  testWidgets('new conversation', (t) {
    final s = seeded()
      ..openInfo = <String, dynamic>{'conversationId': null}
      ..conversations = <Map<String, dynamic>>[];
    return render(t, 'new', (t) => t.tap(find.text('Send us a message')), server: s);
  }, skip: !enabled);
  testWidgets('cannot open', (t) => render(t, 'fallback', nothing, server: seeded()..authStatus = 500), skip: !enabled);

  // 0.4.6: the moments in between, not only where they land.
  Future<void> shoot(WidgetTester tester, String name) async {
    autoUpdateGoldenFiles = true;
    await expectLater(find.byKey(const ValueKey<String>('screen')), matchesGoldenFile('screens/$name.png'));
    autoUpdateGoldenFiles = false;
  }

  void phone(WidgetTester tester, {double height = 844}) {
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = Size(390 * 2, height * 2);
    tester.view.viewPadding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
    tester.view.padding = const FakeViewPadding(top: 47 * 2, bottom: 34 * 2);
    addTearDown(tester.view.reset);
  }

  /// An app behind the sheet, as GuardPass would be.
  Widget app(Widget Function(BuildContext) open) => RepaintBoundary(
        key: const ValueKey<String>('screen'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(platform: TargetPlatform.iOS, fontFamily: 'Roboto', colorSchemeSeed: const Color(0xFF0B3D91)),
          home: Builder(
            builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('GuardPass')),
              body: ListView(children: [
                for (final t in <String>['My courses', 'Bookings', 'Licence', 'Jobs'])
                  ListTile(title: Text(t), subtitle: const Text('Tap to see more'), leading: const Icon(Icons.folder_outlined)),
                Center(child: TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).push(messengerRoute(open(context))), child: const Text('Support'))),
              ]),
            ),
          ),
        ),
      );

  testWidgets('sheet mid-open', (t) async {
    phone(t);
    final c = controllerFor(seeded(), FakeChannel());
    await t.pumpWidget(app((_) => GLSupportChatPage(controller: c)));
    await t.tap(find.text('Support'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 40));
    await shoot(t, 'sheet-mid-open');
    await t.pump(const Duration(seconds: 1));
    await shoot(t, 'sheet-up');
  }, skip: !enabled);

  testWidgets('sheet first frames', (t) async {
    phone(t);
    final c = controllerFor(seeded(), FakeChannel());
    await t.pumpWidget(app((_) => GLSupportChatPage(controller: c)));
    await t.tap(find.text('Support'));
    await t.pump();
    // The first six frames of the rise, side by side.
    final frames = <ui.Image>[];
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 16));
      frames.add((await t.runAsync(() => captureImage(find.byKey(const ValueKey<String>('screen')).evaluate().single)))!);
    }
    t.view.physicalSize = const Size(390 * 6 * 2 + 5 * 8 * 2, 844 * 2);
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey<String>('screen'),
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: Row(textDirection: TextDirection.ltr, children: [
          for (var i = 0; i < frames.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            RawImage(image: frames[i], width: 390, height: 844),
          ],
        ]),
      ),
    ));
    await shoot(t, 'sheet-first-frames');
    for (final f in frames) {
      f.dispose();
    }
    await t.pumpWidget(const SizedBox());
  }, skip: !enabled);

  testWidgets('home skeleton', (t) async {
    phone(t);
    final server = GatedServer.from(seeded())..hold(<String>['/widget/auth']);
    final c = controllerFor(server, FakeChannel());
    await t.pumpWidget(app((_) => GLSupportChatPage(controller: c)));
    await t.tap(find.text('Support'));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    await shoot(t, 'home-skeleton');
    server.release();
    await t.pump();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await shoot(t, 'home-skeleton-to-home');
    await t.pump(const Duration(seconds: 1));
  }, skip: !enabled);

  testWidgets('home staggered', (t) async {
    phone(t);
    final c = controllerFor(seeded(), FakeChannel());
    c.attach();
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    c.detach();
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey<String>('screen'),
      child: MaterialApp(debugShowCheckedModeBanner: false, home: GLSupportChatPage(controller: c)),
    ));
    await t.pump(const Duration(milliseconds: 16));
    await t.pump(const Duration(milliseconds: 150));
    await shoot(t, 'home-staggered');
    await t.pump(const Duration(seconds: 1));
  }, skip: !enabled);

  // 0.4.9: the photo viewer, open, and dragged part way down to close.
  testWidgets('photo viewer', (t) async {
    phone(t);
    const id = 'aaaaaaaa-0000-4000-8000-000000000001';
    final server = seeded();
    server.files[id] = (await t.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 900, 1200), Paint()..color = const Color(0xFF4A90D9));
      canvas.drawCircle(const Offset(450, 600), 300, Paint()..color = const Color(0xFFFFD54F));
      final data = await (await recorder.endRecording().toImage(900, 1200)).toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }))!;
    final messages = (server.details['conv-1']!['messages'] as List).cast<Map<String, dynamic>>();
    messages.insert(3, msg('ph', 'visitor', '[Photo]', at: messages[2]['createdAt'] as String, attachments: <Object?>[
      <String, dynamic>{'name': 'licence-back.png', 'url': 'upload://$id', 'contentType': 'image/png'},
    ]));
    final c = controllerFor(server, FakeChannel());
    await t.pumpWidget(RepaintBoundary(
      key: const ValueKey<String>('screen'),
      child: MaterialApp(debugShowCheckedModeBanner: false, home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1'))),
    ));
    Future<void> decode() async {
      for (var i = 0; i < 3; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await t.pump(const Duration(milliseconds: 16));
      }
    }

    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    await decode();
    await shoot(t, 'viewer-thread');
    await t.tap(find.byWidgetPredicate((w) => w is SizedBox && w.width == 240), warnIfMissed: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await shoot(t, 'viewer-flying');
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
    }
    await decode();
    await shoot(t, 'viewer');
    final finger = await t.startGesture(const Offset(195, 420));
    for (var i = 0; i < 5; i++) {
      await finger.moveBy(const Offset(0, 20));
      await t.pump(const Duration(milliseconds: 16));
    }
    await shoot(t, 'viewer-dragged');
    await finger.up();
    await t.pump(const Duration(seconds: 1));
  }, skip: !enabled);

  for (final face in <String?>[null, '😞']) {
    testWidgets('article with a button and reactions ${face ?? ''}', (t) async {
      phone(t, height: 1300);
      final c = controllerFor(seeded(), FakeChannel());
      await t.pumpWidget(RepaintBoundary(
        key: const ValueKey<String>('screen'),
        child: MaterialApp(debugShowCheckedModeBanner: false, home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.article('renew-sia'))),
      ));
      for (var i = 0; i < 20; i++) {
        await t.pump(const Duration(milliseconds: 60));
      }
      if (face != null) {
        await t.tap(find.text(face));
        for (var i = 0; i < 10; i++) {
          await t.pump(const Duration(milliseconds: 60));
        }
      }
      await shoot(t, face == null ? 'article-button-reactions' : 'article-reacted-sad');
    }, skip: !enabled);
  }
}
