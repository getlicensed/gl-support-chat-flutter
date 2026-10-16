import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';
import 'package:gl_support_chat/src/ui/text_size.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';
import 'support/phone.dart';

// Text size (0.4.9, from the director's "customers who find the fonts small
// can increase them"): Aa in every header of the messenger; Small, Default,
// Large, Extra large times the phone's own size, at most 2.0 in all (or the
// phone's own, if larger); kept on the phone.
void main() {
  late FakeServer server;
  late FakeChannel channel;

  setUp(() {
    MessengerTextSize.debugReset();
    addTearDown(MessengerTextSize.debugReset);
    server = FakeServer()
      ..articles = <Map<String, dynamic>>[
        <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': 'Three steps.'},
      ]
      ..article = <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'html': '<p>You can renew early.</p>'}
      ..openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0}
      ..conversations = <Map<String, dynamic>>[row('conv-1', body: 'Your card is on its way.')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[msg('m1', 'agent', 'Your card is on its way.')]);
    channel = FakeChannel();
  });

  Finder aa() => find.byTooltip(TextSizeButton.label);

  /// How large a word of 10 points is drawn in [f]'s place.
  double tenPointsIn(WidgetTester tester, Finder f) => MediaQuery.textScalerOf(tester.element(f)).scale(10);

  Future<void> choose(WidgetTester tester, String name) async {
    await tester.tap(aa().first);
    await settle(tester);
    // At a large size the sheet scrolls (the test's square letters are
    // wider than a phone's).
    await tester.ensureVisible(find.text(name));
    await tester.pump();
    await tester.tap(find.text(name));
    await settle(tester, frames: 4);
    await tester.ensureVisible(find.byTooltip('Done'));
    await tester.pump();
    await tester.tap(find.byTooltip('Done'));
    await settle(tester);
  }

  testWidgets('Aa is in every header — Home, Messages, Help, a conversation, an article — 44 points square, named "Text size"', (tester) async {
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel);
    void there(String where) {
      expect(aa(), findsOneWidget, reason: where);
      expect(tester.getSize(aa()), const Size(44, 44), reason: where);
      expect(tester.getSemantics(aa()), isSemantics(label: TextSizeButton.label, isButton: true, hasTapAction: true), reason: where);
    }

    there('Home');
    await tester.tap(find.text('Messages'));
    await settle(tester);
    there('Messages');
    await tester.tap(find.text('Help'));
    await settle(tester);
    there('Help');
    await tester.tap(find.text('How do I renew my SIA licence?'));
    await settle(tester, frames: 16);
    there('an article');
    await tester.tap(find.byTooltip('Back'));
    await settle(tester);
    await tester.tap(find.text('Messages'));
    await settle(tester);
    await tester.tap(find.text('Your card is on its way.'));
    await settle(tester);
    expect(find.descendant(of: find.byType(ConversationPage), matching: aa()), findsOneWidget);
    there('a conversation');
  });

  testWidgets('the sheet: four sizes, each in its own size, the one in use ticked; a choice changes every word at once, the screens opened since too', (tester) async {
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel);
    final greeting = find.text('Hi Ayesha 👋');
    expect(tenPointsIn(tester, greeting), 10);

    await tester.tap(aa());
    await settle(tester);
    for (final name in <String>['Small', 'Default', 'Large', 'Extra large']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(tester.getSemantics(find.bySemanticsLabel('Default')), isSemantics(label: 'Default', isButton: true, isSelected: true, isInMutuallyExclusiveGroup: true, hasTapAction: true, hasSelectedState: true));
    expect(find.byIcon(Icons.check), findsOneWidget);
    double drawnAt(String name) => tester.renderObject<RenderParagraph>(find.text(name)).textScaler.scale(10);
    expect(drawnAt('Small'), closeTo(9, 0.001), reason: 'each choice in its own size');
    expect(drawnAt('Extra large'), closeTo(13, 0.001));

    final preview = find.textContaining('Your licence card was posted');
    await tester.tap(find.text('Extra large'));
    await tester.pump();
    expect(tenPointsIn(tester, preview), closeTo(13, 0.001), reason: 'the preview, live');
    expect(tenPointsIn(tester, greeting), closeTo(13, 0.001), reason: 'and the messenger behind it, at once');
    expect(tester.getSemantics(find.bySemanticsLabel('Extra large')), isSemantics(label: 'Extra large', isButton: true, isSelected: true, isInMutuallyExclusiveGroup: true, hasTapAction: true, hasSelectedState: true));
    await tester.tap(find.byTooltip('Done'));
    await settle(tester);

    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    expect(tenPointsIn(tester, find.text('Your card is on its way.')), closeTo(13, 0.001), reason: 'a conversation opened since');
    expect(tester.takeException(), isNull);
  });

  testWidgets("it multiplies the phone's own size; the total stops at 2.0 — or at the phone's own, never made smaller", (tester) async {
    for (final (phone, chosen, expected) in <(double, String, double)>[
      (1.0, 'Small', 0.9),
      (1.3, 'Large', 1.3 * 1.15),
      (1.8, 'Extra large', 2.0),
      (2.5, 'Extra large', 2.5),
      (2.5, 'Small', 2.25),
    ]) {
      MessengerTextSize.debugReset();
      await tester.pumpWidget(const SizedBox());
      usePhone(tester, Phone.iphone13, textScale: phone);
      await openMessenger(tester, server, channel);
      await choose(tester, chosen);
      expect(tenPointsIn(tester, find.text('Recent message')), closeTo(10 * expected, 0.001), reason: 'phone $phone, $chosen');
    }
  });

  testWidgets('kept on the phone: chosen once, there at the next launch; a sign-out keeps it (it is not about the customer)', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await MessengerTextSize.load(const PrefsSessionStore());
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel);
    await choose(tester, 'Large');
    expect((await SharedPreferences.getInstance()).getDouble('gl_support_chat.text_size'), 1.15);

    // The next launch.
    MessengerTextSize.debugReset();
    expect(MessengerTextSize.factor.value, 1.0);
    await MessengerTextSize.load(const PrefsSessionStore());
    expect(MessengerTextSize.factor.value, 1.15);
  });

  test('read at configure, from the store the visitor id is kept in; a sign-out leaves it', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final store = MemorySessionStore();
    await store.saveTextSize(1.3);
    GLSupportChat.debugOverride(
      store: store,
      client: MockClient((_) async => http.Response('{"unreadCount": 0}', 200, headers: <String, String>{'content-type': 'application/json'})),
    );
    await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'p1');
    await Future<void>.delayed(Duration.zero);
    expect(MessengerTextSize.factor.value, 1.3);
    await GLSupportChat.logout();
    expect(await store.textSize(), 1.3);
    expect(MessengerTextSize.factor.value, 1.3);
  });

  test('a stored value that is not one of the four is ignored', () async {
    final store = MemorySessionStore();
    await store.saveTextSize(3.7);
    await MessengerTextSize.load(store);
    expect(MessengerTextSize.factor.value, 1.0);
  });
}
