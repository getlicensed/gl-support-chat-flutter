import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/core/format.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';

import 'support/fakes.dart';
import 'support/phone.dart';

// The faces in the chat (12 Oct): the chatbot's own avatar in its circle, the
// logo on the brand colour without one (GL's white logo vanished on white).
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
      expect(tester.getSize(find.byWidget(box)).width, anyOf(22, 34), reason: 'the picture is the whole circle, no ring of padding');
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
}
