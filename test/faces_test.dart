import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/api/realtime.dart';
import 'package:gl_support_chat/src/core/format.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';

import 'support/fakes.dart';
import 'support/phone.dart';

// The faces in the chat (12 Oct): the chatbot's own avatar in its circle, the
// logo on the brand colour without one (GL's white logo vanished on white),
// and whoever is typing beside the dots.
void main() {
  late FakeServer server;
  late FakeChannel channel;
  final brand = BrandColors('#1F6FEB');

  setUp(() {
    server = FakeServer();
    channel = FakeChannel();
    // Nobody's face chosen: the header shows the chatbot's circle too.
    server.session = <String, dynamic>{...server.session, 'team': <Object?>[]};
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
    server.conversations = <Map<String, dynamic>>[row('conv-1')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('p1', 'bot', 'Hello 👋 How can we help?'),
      msg('a1', 'agent', 'Hi, Levi here.'),
    ]);
  });

  Future<void> openChat(WidgetTester tester) async {
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel, screen: GLSupportChatScreen.conversation('conv-1'));
    await settle(tester);
  }

  Finder network(String url) => find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage && (w.image as NetworkImage).url == url);
  Finder inCircles(Finder f) => find.descendant(of: find.byType(LogoAvatar), matching: f);
  Iterable<Container> circles(WidgetTester tester) => tester.widgetList<Container>(find.descendant(of: find.byType(LogoAvatar), matching: find.byType(Container)));
  bool onBrand(Container c) => c.decoration is BoxDecoration && (c.decoration! as BoxDecoration).color == brand.primary;
  bool onWhite(Container c) => c.decoration is BoxDecoration && (c.decoration! as BoxDecoration).color == Colors.white;

  test('the session: an https chat avatar only', () {
    MessengerSession parse(Object? avatar) =>
        MessengerSession.fromJson(<String, dynamic>{'token': 't', 'visitorId': 'v', 'brandColor': '#112233', 'avatarUrl': avatar});
    expect(parse('https://cdn.test/avatar.png').avatarUrl, 'https://cdn.test/avatar.png');
    expect(parse('HTTPS://cdn.test/a.png').avatarUrl, 'HTTPS://cdn.test/a.png');
    expect(parse('http://cdn.test/avatar.png').avatarUrl, isNull, reason: 'a phone refuses plain http');
    expect(parse('javascript:alert(1)').avatarUrl, isNull);
    expect(parse(null).avatarUrl, isNull, reason: 'an older server sends none');
    expect(parse(42).avatarUrl, isNull);
  });

  testWidgets('the chat avatar fills the circle: cover, no padding, no white', (tester) async {
    server.session = <String, dynamic>{
      ...server.session,
      'logoUrl': 'https://logo.test/gl-white.png',
      'avatarUrl': 'https://cdn.test/avatar.png',
    };
    await openChat(tester);
    // The header (nobody's face chosen) and beside the bot.
    expect(find.byType(LogoAvatar), findsNWidgets(2));
    final avatars = tester.widgetList<Image>(inCircles(network('https://cdn.test/avatar.png')));
    expect(avatars.length, 2);
    for (final image in avatars) {
      expect(image.fit, BoxFit.cover, reason: 'a real avatar fills its circle');
    }
    for (final box in tester.widgetList<ClipOval>(inCircles(find.byType(ClipOval)))) {
      expect(tester.getSize(find.byWidget(box)).width, anyOf(28, 34), reason: 'the picture is the whole circle, no ring of padding');
    }
    expect(circles(tester).where(onWhite), isEmpty, reason: 'never on white');
  });

  testWidgets('without a chat avatar: the logo, whole, on the brand colour', (tester) async {
    server.session = <String, dynamic>{...server.session, 'logoUrl': 'https://logo.test/gl-white.png'};
    await openChat(tester);
    final logos = tester.widgetList<Image>(inCircles(network('https://logo.test/gl-white.png')));
    expect(logos.length, 2);
    for (final image in logos) {
      expect(image.fit, BoxFit.contain, reason: 'whole, whatever its shape');
    }
    expect(circles(tester).where(onBrand).length, 2, reason: 'the circle is the brand colour');
    expect(circles(tester).where(onWhite), isEmpty, reason: "GL's white logo vanished on white");
    // About 12% of the circle around the logo.
    final pad = tester.widget<Padding>(find.ancestor(of: network('https://logo.test/gl-white.png').first, matching: find.byType(Padding)).first);
    expect(pad.padding, const EdgeInsets.all(34 * 0.12));
    // The network is not there in tests: the logo fails, and the letter shows on the brand colour.
    expect(find.descendant(of: find.byType(LogoAvatar), matching: find.text('G')), findsNWidgets(2));
  });

  testWidgets('neither: the initial on the brand colour', (tester) async {
    await openChat(tester);
    expect(find.byType(LogoAvatar), findsNWidgets(2));
    expect(inCircles(find.byType(Image)), findsNothing);
    expect(find.descendant(of: find.byType(LogoAvatar), matching: find.text('G')), findsNWidgets(2), reason: "GuardPass's initial");
    expect(circles(tester).where(onBrand).length, 2);
  });

  // ---- who is typing ---------------------------------------------------------

  const levi = '9b1c3a5e-0000-4000-8000-000000000001';
  Finder typingRow() => find.bySemanticsLabel(RegExp('typing', caseSensitive: false));
  Finder inTyping(Finder f) => find.descendant(of: typingRow(), matching: f);

  test('typing: a teammate named, an old server naming nobody, the workflow; never the customer', () {
    expect(
      TypingAuthor.fromJson(<String, dynamic>{'conversationId': 'c', 'authorType': 'agent', 'authorId': levi, 'authorName': ' Levi John '}),
      const TypingAuthor(type: 'agent', id: levi, name: 'Levi John'),
    );
    expect(TypingAuthor.fromJson(<String, dynamic>{'conversationId': 'c', 'authorType': 'agent'}), const TypingAuthor(type: 'agent'));
    expect(TypingAuthor.fromJson(<String, dynamic>{'conversationId': 'c'}), const TypingAuthor(type: 'agent'), reason: 'no type was a teammate before');
    expect(TypingAuthor.fromJson(<String, dynamic>{'conversationId': 'c', 'authorType': 'bot'})!.isBot, isTrue);
    expect(TypingAuthor.fromJson(<String, dynamic>{'conversationId': 'c', 'authorType': 'visitor'}), isNull);
    expect(TypingAuthor.fromJson(<String, dynamic>{'authorType': 'agent', 'authorId': 7, 'authorName': ''}), const TypingAuthor(type: 'agent'));
  });

  testWidgets('the controller keeps who is typing, and redraws only when that changes', (tester) async {
    final c = controllerFor(server, channel);
    await c.start();
    var redraws = 0;
    c.addListener(() => redraws++);
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
    await tester.pump();
    expect(c.typingAuthor, const TypingAuthor(type: 'agent', id: levi, name: 'Levi John'));
    expect(c.agentTyping, isTrue);
    redraws = 0;
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
    await tester.pump();
    expect(redraws, 0, reason: 'the same teammate still typing: nothing new to draw');
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
    await tester.pump();
    expect(redraws, 1, reason: 'someone else typing now');
    expect(c.typingAuthor!.isBot, isTrue);
    channel.server('message:created', msg('b1', 'bot', 'Which course is it about?'));
    await tester.pump();
    expect(c.typingAuthor, isNull, reason: 'the message ends the dots');
    await tester.pump(const Duration(seconds: 6));
    c.dispose();
  });

  testWidgets("a teammate typing: their photo, the one their replies show; their initial when it does not load", (tester) async {
    await openChat(tester);
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
    await settle(tester);
    expect(find.bySemanticsLabel('Levi John is typing'), findsOneWidget);
    // The same picture as beside Levi's message: one request, one cached image.
    final photo = network('https://api.test/widget/avatar/$levi');
    expect(inTyping(photo), findsOneWidget);
    expect(find.descendant(of: find.byType(Row), matching: photo), findsNWidgets(2), reason: 'the typing row and the author row ask for the same photo');
    // No network in tests: the photo fails, as a teammate without one does.
    expect(inTyping(find.text('L')), findsOneWidget, reason: 'the initial');
    expect(inTyping(find.byIcon(Icons.person_outline)), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a teammate with a malformed id: the initial, no request', (tester) async {
    await openChat(tester);
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': '../../secret', 'authorName': 'Levi John'});
    await settle(tester);
    expect(inTyping(find.byType(Image)), findsNothing);
    expect(inTyping(find.text('L')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('an older server names nobody: the plain person, as before', (tester) async {
    await openChat(tester);
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent'});
    await settle(tester);
    expect(find.bySemanticsLabel('Typing'), findsOneWidget);
    expect(inTyping(find.byIcon(Icons.person_outline)), findsOneWidget);
    expect(inTyping(find.byType(Image)), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets("the workflow typing: the chatbot's circle", (tester) async {
    server.session = <String, dynamic>{...server.session, 'avatarUrl': 'https://cdn.test/avatar.png'};
    await openChat(tester);
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
    await settle(tester);
    expect(inTyping(find.byType(LogoAvatar)), findsOneWidget);
    expect(inTyping(network('https://cdn.test/avatar.png')), findsOneWidget);
    expect(inTyping(find.byIcon(Icons.person_outline)), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });
}
