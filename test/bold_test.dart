import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/core/format.dart';

import 'support/fakes.dart';
import 'support/thread.dart';

// 0.4.12: the inbox's chat box writes bold as WhatsApp does, `*words*`
// (22 Nov), and a macro's pictures go as "1." with its screenshot, "2." with
// its own. The team's words show bold, without their stars, and come before
// their photo, as on the website.

/// The website messenger's own cases (test:chat-format in the server's
/// repo): the same words must be bold in both.
const boldCases = <(String, List<String>)>[
  ('Your course is on *14 Dec*.', <String>['14 Dec']),
  ('**AI bold** too', <String>['AI bold']),
  ('5*3*2 = 30', <String>[]),
  ('* not a list item *', <String>[]),
  ('*Terms apply', <String>[]),
  ('a *b c* d *e*', <String>['b c', 'e']),
  ('*a*b', <String>[]),
  ('x*y* z', <String>[]),
  ('*one\ntwo*', <String>[]),
  ('(*inside brackets*)', <String>['inside brackets']),
  ('*Booking ref* GL123', <String>['Booking ref']),
  ('**', <String>[]),
  ('***', <String>[]),
  ('*a**b*', <String>['a**b']),
  ('ünï *ç* ü', <String>['ç']),
  ('*', <String>[]),
  ('', <String>[]),
];

Finder _photos() => find.descendant(of: threadList(), matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 240), skipOffstage: false);

/// The run of a RichText in the thread whose text is [text].
TextSpan? _span(WidgetTester tester, String text) {
  for (final rt in tester.widgetList<RichText>(find.descendant(of: threadList(), matching: find.byType(RichText)))) {
    TextSpan? hit;
    rt.text.visitChildren((s) {
      if (s is TextSpan && s.text == text) {
        hit = s;
        return false;
      }
      return true;
    });
    if (hit != null) return hit;
  }
  return null;
}

void main() {
  group('bold in the team\'s words', () {
    test('by WhatsApp\'s rule, as the website messenger reads it', () {
      for (final (text, want) in boldCases) {
        final got = boldSpans(text).map((s) {
          final len = text.startsWith('**', s.start) ? 2 : 1;
          return text.substring(s.start + len, s.end - len);
        }).toList();
        expect(got, want, reason: text);
        expect(linkify(text, bold: true).where((r) => r.bold).map((r) => r.text).toList(), want, reason: text);
      }
    });

    test('only when asked: the customer\'s own words stay as typed', () {
      expect(linkify('Your course is on *14 Dec*.').map((r) => r.text).join(), 'Your course is on *14 Dec*.');
      expect(linkify('Your course is on *14 Dec*.').any((r) => r.bold), isFalse);
    });

    test('links first, bold between them; a full stop after a bare address stays outside', () {
      final runs = linkify('See [the guide](https://x.test/g) by *Friday*, or https://x.test/a.', bold: true);
      expect(runs.map((r) => (r.text, r.url, r.bold)).toList(), <(String, String?, bool)>[
        ('See ', null, false),
        ('the guide', 'https://x.test/g', false),
        (' by ', null, false),
        ('Friday', null, true),
        (', or ', null, false),
        ('https://x.test/a', 'https://x.test/a', false),
        ('.', null, false),
      ]);
    });

    test('the Messages list shows the team\'s words without their marks, the customer\'s as typed', () {
      ConversationSummary last(String body, String author) =>
          ConversationSummary.fromJson(<String, dynamic>{'id': 'c', 'open': true, 'lastMessageAt': '2026-11-22T10:00:00.000Z', 'lastMessage': <String, dynamic>{'body': body, 'authorType': author}});
      expect(previewLine(last('Your course is on *14 Dec*. [Book](https://x.test/b)', 'agent')), 'Your course is on 14 Dec. Book');
      expect(previewLine(last('5*3*2 *ok*', 'visitor')), 'You: 5*3*2 *ok*');
      expect(plainMessageText('[SIA ID guide](https://x.test/sia.pdf) — *today*'), 'SIA ID guide — today');
    });
  });

  testWidgets('in the thread: the team\'s *words* bold without stars, the customer\'s as typed, and "2." over its screenshot', (tester) async {
    final server = threadServer();
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('v', 'visitor', 'Is it *this* week?', at: ago(6)),
      msg('a1', 'agent', 'Your course is on *14 Dec*.', at: ago(5)),
      msg('a2', 'agent', '2.', at: ago(4), attachments: <Object?>[
        <String, dynamic>{'name': 'step-2.png', 'url': 'https://cdn.test/step-2.png', 'contentType': 'image/png', 'width': 800, 'height': 400},
      ]),
    ]);
    await openThread(tester, server);

    final bold = _span(tester, '14 Dec');
    expect(bold, isNotNull, reason: 'the bold words are a run of their own, without their stars');
    expect(bold!.style?.fontWeight, FontWeight.w700);
    expect(_span(tester, 'Your course is on *14 Dec*.'), isNull);
    expect(_span(tester, 'Is it *this* week?'), isNotNull, reason: 'the customer\'s own words are not read for marks');

    final step = find.descendant(of: threadList(), matching: find.text('2.', findRichText: true));
    expect(step, findsOneWidget);
    expect(_photos(), findsOneWidget);
    expect(tester.getRect(step).bottom, lessThanOrEqualTo(tester.getRect(_photos()).top), reason: 'the team\'s words over their photo, as on the website');
  });
}
