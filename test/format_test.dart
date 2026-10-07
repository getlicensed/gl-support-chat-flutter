import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/core/format.dart';

// The rules the screens follow — the website messenger's wording and
// behaviour, so the app and the website say the same thing.
void main() {
  MessengerSession session(Map<String, dynamic> extra) =>
      MessengerSession.fromJson(<String, dynamic>{'token': 't', 'visitorId': 'v', 'productName': 'GuardPass', ...extra});

  group('greeting', () {
    test('a signed-in customer by first name, else the chatbot greeting, else Hi there', () {
      expect(greetingFor(session({'identified': {'name': 'Ayesha Khan', 'type': 'learner'}, 'welcomeGreeting': 'Welcome!'})), 'Hi Ayesha 👋');
      expect(greetingFor(session({'welcomeGreeting': 'Welcome to GuardPass'})), 'Welcome to GuardPass');
      expect(greetingFor(session({})), 'Hi there 👋');
    });
  });

  group('presence lines', () {
    const closed = OfficeHours(open: false, opensLabel: 'tomorrow at 9am', awayMessage: 'We are away right now.');
    test('unknown reads as the neutral, positive line — never away', () {
      final p = presenceLines(null, closed);
      expect(p.home, 'We typically reply in a few minutes');
      expect(p.header, 'Active now');
      expect(p.away, isFalse);
    });
    test('someone online outranks the clock', () {
      expect(presenceLines(2, closed).home, "We're online — reply in a few minutes");
    });
    test('nobody online: when we are back, or by email', () {
      expect(presenceLines(0, closed).home, "We're away — back tomorrow at 9am");
      expect(presenceLines(0, closed).header, 'Back tomorrow at 9am');
      expect(presenceLines(0, const OfficeHours(open: true)).home, "We're away — we'll reply by email");
    });
    test('the away paragraph above the email field', () {
      expect(awayParagraph(closed), 'We are away right now. We are back tomorrow at 9am.');
      expect(awayParagraph(const OfficeHours(open: true, awayMessage: 'x')), '');
      expect(awayParagraph(null), '');
    });
  });

  group('WhatsApp chip', () {
    test('in the app {page} is "the <chatbot> app", {url} is empty and its dash goes', () {
      final link = whatsappChipLink(number: '447700900123', template: null, productLabel: 'GuardPass');
      expect(link!.host, 'wa.me');
      expect(link.path, '/447700900123');
      expect(link.queryParameters['text'], "Hi, I'd like to book a course. I'm looking at the GuardPass app");
    });
    test('a chatbot template with {product}', () {
      final link = whatsappChipLink(number: '447700900123', template: 'Hi, I want {product} — {url}', productLabel: 'APLH');
      expect(link!.queryParameters['text'], 'Hi, I want APLH');
    });
    test('no number, no link', () {
      expect(whatsappChipLink(number: null, template: null, productLabel: 'x'), isNull);
    });
  });

  group('links in a message', () {
    test('markdown links and bare URLs; trailing punctuation stays outside', () {
      final runs = linkify('See [the guide](https://x.com/guide) or https://x.com/a. Thanks!');
      expect(runs.map((r) => r.text).toList(), <String>['See ', 'the guide', ' or ', 'https://x.com/a', '.', ' Thanks!']);
      expect(runs[1].url, 'https://x.com/guide');
      expect(runs[3].url, 'https://x.com/a');
      expect(runs[4].isLink, isFalse);
    });
    test('plain text stays plain, never HTML', () {
      final runs = linkify('<b>hi</b> javascript:alert(1)');
      expect(runs.length, 1);
      expect(runs.first.isLink, isFalse);
    });
  });

  test('the AI hand-over marker never reaches the customer', () {
    expect(stripEscalationMarker('I am not sure — let me get the team. [[NEEDS_HUMAN]]'), 'I am not sure — let me get the team');
    expect(stripEscalationMarker('All good.'), 'All good.');
  });

  test('a photo message shows only what was typed under the picture', () {
    ChatMessage m(String body, {bool file = true}) => ChatMessage(
          id: '1',
          conversationId: 'c',
          body: body,
          authorType: 'visitor',
          createdAt: DateTime(2026),
          attachments: file ? const <Attachment>[Attachment(name: 'a.jpg', url: 'upload://x', contentType: 'image/jpeg')] : const <Attachment>[],
        );
    expect(bodyBesideFiles(m('[Photo]')), '');
    expect(bodyBesideFiles(m('[Photo] front side')), 'front side');
    expect(bodyBesideFiles(m('[Photo] text', file: false)), '[Photo] text', reason: 'no file: the text is what they typed');
    final fromTeam = ChatMessage(
      id: '2',
      conversationId: 'c',
      body: '[Document]',
      authorType: 'agent',
      createdAt: DateTime(2026),
      attachments: const <Attachment>[Attachment(name: 'guide.pdf', url: 'https://api.test/files/x', contentType: 'application/pdf')],
    );
    expect(bodyBesideFiles(fromTeam), '', reason: "the team's file speaks for itself too");
  });

  test('the typewriter catches up when a lot is waiting', () {
    expect(dripStep(5), 1);
    expect(dripStep(60), 3);
    expect(dripStep(1000), 8);
  });

  test('Messages list times', () {
    final now = DateTime(2026, 10, 6, 15);
    expect(shortAgo(now.subtract(const Duration(seconds: 20)), now), 'now');
    expect(shortAgo(now.subtract(const Duration(minutes: 5)), now), '5m');
    expect(shortAgo(now.subtract(const Duration(hours: 3)), now), '3h');
    expect(shortAgo(now.subtract(const Duration(days: 2)), now), '2d');
    expect(shortAgo(DateTime(2026, 9, 1), now), '1 Sep');
    expect(shortAgo(DateTime(2025, 9, 1), now), '1 Sep 2025');
  });

  test('brand colours: the website messenger’s formulas', () {
    final b = BrandColors('#6366F1');
    expect(b.hex, '#6366f1');
    expect(BrandColors('#000000').hover, const Color(0xFF000000), reason: 'darkening stops at black');
    expect(BrandColors('not a colour').hex, '#6366f1', reason: 'a bad value falls back to the default');
  });
}
