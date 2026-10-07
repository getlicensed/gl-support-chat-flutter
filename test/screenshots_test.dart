import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/messenger_page.dart';

import 'support/fakes.dart';

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
          '<h2>What you need</h2><ul><li>Your current licence number</li><li>A recent photo</li><li>A valid first aid certificate</li></ul>'
          '<p>Then apply on the <a href="https://www.gov.uk/sia">SIA website</a>.</p>',
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
}
