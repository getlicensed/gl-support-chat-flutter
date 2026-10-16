import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/format.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/tabs.dart';

import 'support/contrast.dart';
import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';

// The messenger's contrast, every screen, iPhone and Android (0.4.9, from the
// director's "increase the widget's contrast"). The words of a message read
// at 7:1 or better; every other word at 4.5:1; icons, field borders and the
// focused field's line at 3:1. Measured against what is painted behind each
// mark on the screen (support/contrast.dart), in the chatbot colours GL uses
// and in others that test the rules: a pale one, a mid one, a dark one.
//
// The whole table, with every mark and its ratio:
//
//   GL_CONTRAST_OUT=/path/contrast.md flutter test test/contrast_test.dart
//
// GL_CONTRAST_REPORT=1 writes it without failing on a mark under target.

/// The brand colour the screens are drawn in: FakeServer's, then the
/// others the rules must hold for.
const _main = '#1F6FEB';
const _others = <String>['#6366F1', '#0B3D91', '#14B8A6', '#FBBF24', '#E11D48', '#FFFFFF', '#000000'];

DateTime _t0 = DateTime.now().subtract(const Duration(minutes: 9));
String _at(int m) => _t0.add(Duration(minutes: m)).toUtc().toIso8601String();

FakeServer _seeded(String brand) {
  _t0 = DateTime.now().subtract(const Duration(minutes: 9));
  final server = FakeServer();
  server.session = <String, dynamic>{...server.session, 'brandColor': brand};
  server.articles = <Map<String, dynamic>>[
    <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': 'Three steps, about ten minutes.'},
    <String, dynamic>{'slug': 'id-photo', 'title': 'Taking a good ID photo', 'description': 'Light, background and size.'},
  ];
  server.article = <String, dynamic>{
    'slug': 'renew-sia',
    'title': 'How do I renew my SIA licence?',
    'description': 'Three steps, about ten minutes.',
    'html': '<p>You can renew up to <strong>four months</strong> before your licence expires.</p>'
        '<h2>What you need</h2><ul><li><p>Your current licence number</p></li></ul>'
        '<p>Then apply on the <a href="https://www.gov.uk/sia">SIA website</a>, or book with us:</p>'
        '<p><a href="https://www.get-licensed.co.uk/">Book A Course</a></p>',
    'url': 'https://help.test/help/renew-sia',
  };
  server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 2};
  server.conversations = <Map<String, dynamic>>[
    row('conv-1', body: 'Which course is it about?', authorType: 'bot', unread: 2, at: _at(7)),
    row('old', open: false, body: 'Your refund has gone through.', at: '2026-09-21T10:00:00.000Z'),
  ];
  server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    msg('m1', 'visitor', 'Hi, my licence card has not arrived yet.', at: _at(0)),
    msg('m2', 'agent', 'Sorry to hear that. See https://www.gov.uk/sia for delivery times.', at: _at(2)),
    msg('m3', 'ai', 'While you wait: most cards arrive within 5 working days.', authorName: 'GL Assistant', at: _at(3)),
    msg('m4', 'agent', '[Document]', at: _at(4), attachments: <Object?>[
      <String, dynamic>{'name': 'Confirmation-letter.pdf', 'url': 'https://api.test/files/abc.sig', 'contentType': 'application/pdf'},
    ]),
    msg('m5', 'visitor', 'Thank you!', at: _at(5)),
    msg('m6', 'bot', 'This article may help.', at: _at(6), meta: <String, dynamic>{
      'article': <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?'},
      'file': <String, dynamic>{'name': 'Checklist.pdf', 'url': 'https://api.test/files/def.sig'},
    }),
    msg('p1', 'bot', 'Which course is it about?', at: _at(7), meta: <String, dynamic>{
      'buttons': <Object?>[
        <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'},
        <String, dynamic>{'id': 'b2', 'label': 'CCTV'},
      ],
      'lockComposer': true,
    }),
  ], agentLastSeenAt: _at(5));
  server.details['old'] = detail('old', <Map<String, dynamic>>[
    msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old', at: '2026-09-21T09:50:00.000Z'),
    msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old', at: '2026-09-21T10:00:00.000Z'),
    msg('c', 'bot', 'How would you rate the help you received?', conversationId: 'old', at: '2026-09-21T10:01:00.000Z', meta: <String, dynamic>{
      'csat': <String, dynamic>{'ratingId': 'r1'},
    }),
  ], open: false);
  return server;
}

/// The app's own theme is Material 3 (Flutter's default), or 2: the
/// messenger takes that from the app.
var _material3 = true;

/// A tall phone, so a whole screen is laid out at once.
const _tall = Phone('tall iPhone', Size(390, 1500));

typedef _Steps = Future<void> Function(WidgetTester tester, FakeChannel channel);

/// [screen] of the messenger, opened on [start] for [server], after [steps].
Future<List<Mark>> _measure(
  WidgetTester tester,
  String name,
  TargetPlatform platform, {
  required FakeServer server,
  GLSupportChatScreen start = GLSupportChatScreen.home,
  _Steps? steps,
  bool online = true,
}) async {
  usePhone(tester, _tall);
  final channel = FakeChannel();
  final c = controllerFor(server, channel);
  await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: platform, useMaterial3: _material3), home: GLSupportChatPage(controller: c, screen: start)));
  await settle(tester, frames: 12);
  channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': online ? 1 : 0});
  await settle(tester, frames: 4);
  if (steps != null) await steps(tester, channel);
  await settle(tester, frames: 12);
  final marks = auditScreen(tester, screen: name, platform: platform == TargetPlatform.iOS ? 'iOS' : 'Android');
  await tester.pumpWidget(const SizedBox());
  return marks;
}

Future<void> _tap(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last);
  await settle(tester, frames: 12);
}

/// Every screen, in [brand].
Future<List<Mark>> _everyScreen(WidgetTester tester, TargetPlatform p, String brand) async {
  final marks = <Mark>[];
  Future<void> add(Future<List<Mark>> m) async => marks.addAll(await m);

  // Home, still signing in: the skeleton in the colours last seen.
  final held = GatedServer.from(_seeded(brand))..hold(<String>['/widget/auth']);
  usePhone(tester, _tall);
  final c = controllerFor(held, FakeChannel());
  await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: p, useMaterial3: _material3), home: GLSupportChatPage(controller: c)));
  await settle(tester, frames: 12);
  marks.addAll(auditScreen(tester, screen: 'Home skeleton', platform: p == TargetPlatform.iOS ? 'iOS' : 'Android'));
  held.release();
  await settle(tester, frames: 4);
  await tester.pumpWidget(const SizedBox());

  await add(_measure(tester, 'Home', p, server: _seeded(brand)));
  await add(_measure(tester, 'Messages', p, server: _seeded(brand), steps: (t, _) => _tap(t, 'Messages')));
  await add(_measure(tester, 'Help', p, server: _seeded(brand), start: GLSupportChatScreen.help));
  await add(_measure(tester, 'Thread', p, server: _seeded(brand), start: GLSupportChatScreen.conversation('conv-1')));
  await add(_measure(tester, 'Thread, typing', p, server: _seeded(brand)..details['conv-1'] = _withoutPrompt(), start: GLSupportChatScreen.conversation('conv-1'),
      steps: (t, channel) async {
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': '9b1c3a5e-0000-4000-8000-000000000001', 'authorName': 'Levi John'});
    await t.tap(find.byType(TextField).last);
    await t.enterText(find.byType(TextField).last, 'My licence number is 1234');
  }));
  await add(_measure(tester, 'Thread, a detail asked for', p, server: _seeded(brand)..details['conv-1'] = _collecting(), start: GLSupportChatScreen.conversation('conv-1')));
  await add(_measure(tester, 'Thread, a send refused', p, server: _seeded(brand)..details['conv-1'] = _withoutPrompt(), start: GLSupportChatScreen.conversation('conv-1'),
      steps: (t, channel) async {
    channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': 'Message too long'};
    await t.enterText(find.byType(TextField).last, 'A long message');
    await t.pump();
    await t.tap(find.bySemanticsLabel('Send'));
  }));
  await add(_measure(tester, 'Thread, away', p, server: _seeded(brand)..details['conv-1'] = _withoutPrompt()
    ..session = <String, dynamic>{..._seeded(brand).session, 'officeHours': <String, dynamic>{'open': false, 'opensLabel': 'tomorrow at 9am', 'awayMessage': 'We are away right now.'}},
      start: GLSupportChatScreen.conversation('conv-1'), online: false));
  await add(_measure(tester, 'New conversation', p,
      server: _seeded(brand)
        ..openInfo = <String, dynamic>{'conversationId': null}
        ..conversations = <Map<String, dynamic>>[]
        ..session = <String, dynamic>{
          ..._seeded(brand).session,
          'suggestedQuestions': <Object?>[
            <String, dynamic>{'text': 'How do I renew my licence?', 'articleSlug': null, 'action': 'message'},
            <String, dynamic>{'text': 'Chat on WhatsApp', 'articleSlug': null, 'action': 'whatsapp', 'whatsappText': 'Hello'},
          ],
        },
      steps: (t, _) => _tap(t, 'Send us a message')));
  await add(_measure(tester, 'Closed, with CSAT', p, server: _seeded(brand), start: GLSupportChatScreen.conversation('old'), steps: (t, _) async {
    await t.tap(find.text('Great'));
    await settle(t, frames: 6);
    await t.enterText(find.byType(TextField).last, 'Quick and kind');
  }));
  await add(_measure(tester, 'Article', p, server: _seeded(brand), start: GLSupportChatScreen.article('renew-sia'), steps: (t, _) async {
    await settle(t, frames: 12);
    await t.tap(find.text('😞'));
  }));
  await add(_measure(tester, 'Cannot open', p, server: _seeded(brand)..authStatus = 500));
  return marks;
}

Map<String, dynamic> _withoutPrompt() {
  final d = _seeded(_main).details['conv-1']!;
  final messages = (d['messages'] as List).cast<Map<String, dynamic>>().where((m) => m['id'] != 'p1').toList();
  return detail('conv-1', messages, agentLastSeenAt: _at(5));
}

Map<String, dynamic> _collecting() {
  final d = _seeded(_main).details['conv-1']!;
  final messages = (d['messages'] as List).cast<Map<String, dynamic>>().where((m) => m['id'] != 'p1').toList()
    ..add(msg('p2', 'bot', 'What is your email address?', at: _at(7), meta: <String, dynamic>{
      'collect': <String, dynamic>{'field': 'email', 'label': 'Email', 'inputType': 'email'},
      'lockComposer': true,
    }));
  return detail('conv-1', messages, agentLastSeenAt: _at(5));
}

void main() {
  final out = Platform.environment['GL_CONTRAST_OUT'];
  final reportOnly = Platform.environment['GL_CONTRAST_REPORT'] == '1';
  final all = <Mark>[];
  final others = <Mark>[];

  tearDownAll(() {
    if (out == null) return;
    final b = StringBuffer('# Contrast, measured\n\nBrand colour $_main (the pretend server\'s), iPhone and Android.\n\n')
      ..writeln(contrastTable(all))
      ..writeln()
      ..writeln('# Other brand colours: what falls under its target\n')
      ..writeln(others.isEmpty ? 'Not measured.' : '');
    for (final brand in _others) {
      final here = others.where((m) => m.screen.startsWith('$brand ')).toList();
      if (here.isEmpty) continue;
      final failing = here.where((m) => !m.passes).toList();
      b.writeln('## $brand: ${here.length} marks, ${failing.length} under target\n');
      if (failing.isNotEmpty) b.writeln(contrastTable(failing));
    }
    writeReport(out, b.toString());
  });

  for (final p in <TargetPlatform>[TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('every screen on ${p.name}, in $_main: each mark reads at its target', (tester) async {
      final marks = await _everyScreen(tester, p, _main);
      all.addAll(marks);
      expect(marks.length, greaterThan(150), reason: 'the screens were drawn and measured');
      if (!reportOnly) expect(marks.where((m) => !m.passes).map((m) => '$m').toList(), isEmpty);
    });
  }

  testWidgets('every screen in an app still on Material 2, on Android, in $_main: each mark reads at its target', (tester) async {
    _material3 = false;
    addTearDown(() => _material3 = true);
    final marks = await _everyScreen(tester, TargetPlatform.android, _main);
    expect(marks.length, greaterThan(150));
    if (!reportOnly) expect(marks.where((m) => !m.passes).map((m) => '$m').toList(), isEmpty);
  });

  test('words on the brand colour: white or near-black, whichever reads better — not by how light it is', () {
    expect(BrandColors('#1F6FEB').onPrimary, Colors.white);
    expect(BrandColors('#0B3D91').onPrimary, Colors.white);
    expect(BrandColors('#14B8A6').onPrimary, Palette.text, reason: 'white read 2.5:1 on this teal, near-black 7.1:1');
    expect(BrandColors('#FBBF24').onPrimary, Palette.text);
    expect(BrandColors('#FFFFFF').onPrimary, Palette.text);
  });

  test('each shade reaches its target, and a brand colour that already does is left as it is', () {
    for (final hex in <String>[_main, ..._others]) {
      final b = BrandColors(hex);
      expect(contrastRatio(b.onPrimary, b.surface), greaterThanOrEqualTo(4.5), reason: '$hex: a button, the header');
      expect(contrastRatio(b.onPrimary, b.surfaceTop), greaterThanOrEqualTo(4.5), reason: "$hex: Home's band");
      expect(contrastRatio(b.onPrimary, b.surfaceEnd), greaterThanOrEqualTo(4.5), reason: "$hex: the header's foot");
      expect(contrastRatio(b.onPrimary, b.bubble), greaterThanOrEqualTo(7), reason: "$hex: the customer's words");
      expect(contrastRatio(b.ink, Colors.white), greaterThanOrEqualTo(4.5), reason: '$hex: ink on white');
      expect(contrastRatio(b.ink, b.light), greaterThanOrEqualTo(4.5), reason: "$hex: a chip's words");
      expect(contrastRatio(b.inkOn(Palette.agentBubble, 7), Palette.agentBubble), greaterThanOrEqualTo(7), reason: "$hex: a link in the team's bubble");
      if (contrastRatio(b.onPrimary, b.primary) >= 7) expect(b.bubble, b.primary, reason: '$hex reads already');
      if (contrastRatio(b.onPrimary, b.primary) >= 4.5) expect(b.surface, b.primary, reason: '$hex reads already');
    }
    // Moved no further than it must: one step less would not read.
    final gl = BrandColors(_main);
    expect(contrastRatio(gl.onPrimary, gl.bubble), lessThan(7.2));
    expect(gl.surface, gl.primary);
    expect(BrandColors('#6366F1').surface, isNot(BrandColors('#6366F1').primary), reason: 'the default indigo is 4.47:1 under white');
  });

  testWidgets("a keyboard's focus rings what it is on, at 3:1 against what is round it", (tester) async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
    usePhone(tester, Phone.iphone13);
    final c = controllerFor(_seeded(_main), FakeChannel());
    await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: TargetPlatform.iOS), home: GLSupportChatPage(controller: c)));
    await settle(tester, frames: 12);
    final ringed = <String>[];
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (final e in find.byWidgetPredicate((w) => w is CustomPaint && w.foregroundPainter is PressHighlight && (w.foregroundPainter! as PressHighlight).ring != null).evaluate()) {
        final ring = ((e.widget as CustomPaint).foregroundPainter! as PressHighlight).ring!;
        final box = e.renderObject! as RenderBox;
        final edge = box.localToGlobal(Offset(1, box.size.height / 2));
        final behind = backgroundAt(e, edge);
        ringed.add('${hex(ring)} on ${hex(behind)}');
        expect(contrastRatio(ring, behind), greaterThanOrEqualTo(3), reason: 'ring ${hex(ring)} on ${hex(behind)}');
      }
    }
    expect(ringed, isNotEmpty, reason: 'the keyboard reached something to tap');

    // A button's line while it has the focus.
    final style = Theme.of(tester.element(find.byType(MessengerTabs))).filledButtonTheme.style!;
    final side = style.side!.resolve(<WidgetState>{WidgetState.focused})!;
    expect(side.width, 2);
    expect(contrastRatio(side.color, Colors.white), greaterThanOrEqualTo(3));
    expect(style.side!.resolve(<WidgetState>{}), isNull, reason: 'no line without the focus');
  });

  for (final brand in _others) {
    testWidgets('every screen in $brand: each mark reads at its target', (tester) async {
      final marks = [
        for (final m in await _everyScreen(tester, TargetPlatform.iOS, brand))
          Mark(screen: '$brand ${m.screen}', platform: m.platform, kind: m.kind, what: m.what, fg: m.fg, bg: m.bg, exempt: m.exempt),
      ];
      others.addAll(marks);
      if (!reportOnly) expect(marks.where((m) => !m.passes).map((m) => '$m').toList(), isEmpty);
    });
  }
}
