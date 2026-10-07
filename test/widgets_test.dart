import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';

import 'support/fakes.dart';

// The screens, driven as a customer would: what they see and what tapping
// sends. The server and the socket are pretend (support/fakes.dart).
void main() {
  late FakeServer server;
  late FakeChannel channel;

  setUp(() {
    server = FakeServer();
    channel = FakeChannel();
    server.articles = <Map<String, dynamic>>[
      <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': 'Three steps, about ten minutes.'},
      <String, dynamic>{'slug': 'id-photo', 'title': 'Taking a good ID photo', 'description': null},
    ];
  });

  Future<MessengerController> open(WidgetTester tester, {GLSupportChatScreen screen = GLSupportChatScreen.home}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final c = controllerFor(server, channel);
    await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: screen)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return c;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Home: the greeting, how to write to us, the recent conversation and help', (tester) async {
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'It is in the post today.')];
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[msg('m1', 'agent', 'It is in the post today.')]);
    await open(tester);
    expect(find.text('Hi Ayesha 👋'), findsOneWidget);
    expect(find.text('Send us a message'), findsOneWidget);
    expect(find.text('We typically reply in a few minutes'), findsOneWidget, reason: 'neutral until presence is known');
    expect(find.text('Recent message'), findsOneWidget);
    expect(find.text('It is in the post today.'), findsOneWidget);
    expect(find.text('How do I renew my SIA licence?'), findsOneWidget);
    channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 2});
    await tester.pump();
    expect(find.text("We're online — reply in a few minutes"), findsOneWidget);
  });

  testWidgets('an empty thread offers the chips, and a chip is the first message', (tester) async {
    await open(tester);
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    expect(find.text('Ask a question, or pick one to get started'), findsOneWidget);
    channel.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m1', 'visitor', data['body'] as String, conversationId: 'conv-1')};
    await tester.tap(find.text('How do I renew my licence?'));
    await settle(tester);
    expect(channel.requests.last.$1, 'visitor:message');
    expect(channel.requests.last.$2['body'], 'How do I renew my licence?');
    expect(find.byIcon(Icons.done), findsOneWidget, reason: 'their message, delivered');
  });

  testWidgets('typing and sending from the composer', (tester) async {
    await open(tester);
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    channel.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m1', 'visitor', data['body'] as String, conversationId: 'conv-1')};
    await tester.enterText(find.byType(TextField), 'My certificate has not arrived');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await settle(tester);
    expect(find.text('My certificate has not arrived'), findsOneWidget);
    channel.server('message:created', msg('m2', 'agent', 'Sorry about that — sending another now.'));
    await tester.pump();
    expect(find.text('Sorry about that — sending another now.'), findsOneWidget);
    expect(find.textContaining('Levi John ·'), findsOneWidget, reason: 'the agent’s name and time above their reply');
  });

  testWidgets('a refused message says why, with Try again', (tester) async {
    await open(tester);
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': "You're sending messages very quickly — wait 9s and try again."};
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Send'));
    await settle(tester);
    expect(find.text("You're sending messages very quickly — wait 9s and try again."), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('workflow buttons under the live question; no composer until typing is allowed', (tester) async {
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 1};
    server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1)];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('p1', 'bot', 'Which course is it about?', meta: <String, dynamic>{
        'buttons': <Object?>[
          <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'},
          <String, dynamic>{'id': 'b2', 'label': 'CCTV'},
        ],
        'lockComposer': true,
      }),
    ]);
    await open(tester, screen: GLSupportChatScreen.messages);
    await settle(tester);
    expect(find.text('Which course is it about?'), findsOneWidget, reason: 'unread replies open the conversation from a push tap');
    // As in Intercom: no composer at all while the buttons wait (7 Oct) — not a greyed-out one.
    expect(find.byType(TextField), findsNothing);
    expect(find.byTooltip('Send a photo'), findsNothing);
    await tester.tap(find.text('CCTV'));
    await tester.pump();
    expect(channel.requests.last.$1, 'workflow:choose');
    expect(channel.requests.last.$2, <String, dynamic>{'conversationId': 'conv-1', 'promptId': 'p1', 'buttonId': 'b2'});
  });

  testWidgets("the chatbot's logo beside the bot, and in the header when no faces are chosen", (tester) async {
    server.session = <String, dynamic>{...server.session, 'team': <Object?>[], 'logoUrl': 'https://logo.test/gl.png'};
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 1};
    server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1)];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('p1', 'bot', 'Hello 👋 How can we help?'),
      msg('a1', 'agent', 'Hi, Levi here.'),
    ]);
    await open(tester, screen: GLSupportChatScreen.messages);
    await settle(tester);
    // One in the header (the admin chose nobody's face), one beside the bot; the agent keeps a person's avatar.
    expect(find.byType(LogoAvatar), findsNWidgets(2));
  });

  testWidgets('Messages: every conversation; a closed one reads but does not reply', (tester) async {
    server.conversations = <Map<String, dynamic>>[row('old', open: false, body: 'Your refund has gone through.')];
    server.details['old'] = detail('old', <Map<String, dynamic>>[
      msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old'),
      msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old'),
    ], open: false);
    await open(tester);
    await tester.tap(find.text('Messages'));
    await settle(tester);
    expect(find.textContaining('· Closed'), findsOneWidget);
    await tester.tap(find.text('Your refund has gone through.'));
    await settle(tester);
    expect(find.text('Can I have a refund?'), findsOneWidget);
    expect(find.text('This conversation has ended'), findsOneWidget);
    expect(find.byType(TextField), findsNothing, reason: 'no composer on a closed conversation');
    expect(server.requests.last.url.path, '/widget/seen');
  });

  testWidgets('Help: search narrows the list at once', (tester) async {
    await open(tester, screen: GLSupportChatScreen.help);
    expect(find.text('Taking a good ID photo'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'renew');
    await tester.pump();
    expect(find.text('Taking a good ID photo'), findsNothing);
    expect(find.text('How do I renew my SIA licence?'), findsOneWidget);
  });

  testWidgets('cannot sign in: the fallback screen, and Try again works', (tester) async {
    server.authStatus = 500;
    await open(tester);
    expect(find.text("We can't open the chat right now"), findsOneWidget);
    expect(find.textContaining('we.care@get-licensed.co.uk'), findsOneWidget, reason: 'a way to reach the team without our servers');
    server.authStatus = 200;
    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(find.text('Hi Ayesha 👋'), findsOneWidget);
  });

  testWidgets('configure() never called: the fallback screen, not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: GLSupportChatPage(controller: null)));
    expect(find.text("We can't open the chat right now"), findsOneWidget);
  });
}
