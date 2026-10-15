import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/messenger_page.dart';

import 'support/gated.dart';
import 'support/phone.dart';
import 'support/thread.dart';

// What the thread builds again, and when (0.4.8). Measured on 15 Oct: any
// change in the controller — a teammate typing, someone coming online, a
// seen receipt — rebuilt the page, the header, the composer and every row on
// screen; an AI answer typing out did it 14 times a second; the keyboard
// rising rebuilt the thread on every frame (16 page builds and 155 bubble
// builds in 16 frames). Now a row is built again only when its own message
// changes.

/// The widgets a message's row is built from (its bubble's box is the
/// typing dots' too, so it is not counted apart).
const messageRows = <String>{'_Bubble', '_RichText', '_MineRow', '_TeamRow'};

void main() {
  testWidgets('a typing tick, a seen receipt, someone coming online, a keystroke: no message row is built again', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20));
    await frames(tester, 2);

    final typing = await BuildCounts.during(() async {
      channel.server('typing:start', leviTyping());
      await frames(tester, 3);
    });
    expect(typing.of(messageRows), 0, reason: 'typing starts: $typing');
    expect(typing['ConversationPage'], 0, reason: 'nor the page');
    expect(typing['_ComposerState'] + typing['_Composer'], 0, reason: 'nor the composer');

    final dots = await BuildCounts.during(() => frames(tester, 10));
    expect(dots.of(messageRows), 0, reason: 'the dots run: $dots');

    final stop = await BuildCounts.during(() async {
      channel.server('typing:stop', leviTyping());
      await frames(tester, 3);
    });
    expect(stop.of(messageRows), 0, reason: 'typing stops: $stop');
    await frames(tester, 70);

    expect(find.descendant(of: page(), matching: find.text('Active now')), findsOneWidget);
    final presence = await BuildCounts.during(() async {
      channel.server('presence:update', <String, dynamic>{'agentsOnline': 0});
      await frames(tester, 3);
    });
    expect(presence.of(messageRows), 0, reason: 'everyone goes: $presence');
    expect(find.descendant(of: page(), matching: find.text('Away — replies by email')), findsOneWidget, reason: 'the header says so');

    final seen = await BuildCounts.during(() async {
      channel.server('conversation:seen', <String, dynamic>{'conversationId': 'conv-1', 'seenBy': 'agent', 'seenAt': now()});
      await frames(tester, 3);
    });
    expect(seen.of(messageRows), 0, reason: 'a seen receipt redraws the tick, not the row: $seen');

    final key = await BuildCounts.during(() async {
      await tester.enterText(composer(), 'H');
      await frames(tester, 3);
    });
    expect(key.of(messageRows), 0, reason: 'a keystroke: $key');
  });

  testWidgets('a reply: its own rows are built, no other', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20));
    final reply = await BuildCounts.during(() async {
      channel.server('message:created', <String, dynamic>{
        'id': 'r1', 'conversationId': 'conv-1', 'body': 'A reply.', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John', 'createdAt': now(),
      });
      await frames(tester, 15);
    });
    expect(reply['_Bubble'], 1, reason: 'the reply, once: $reply');
    expect(reply['_MineRow'], 0, reason: "the customer's own rows: $reply");
  });

  testWidgets('an AI answer typing out builds its own row at each step, and no other', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20));
    final stream = await BuildCounts.during(() async {
      channel.server('ai:stream_start', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'authorName': 'GL Assistant', 'createdAt': now()});
      for (var i = 0; i < 20; i++) {
        channel.server('ai:stream_chunk', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'delta': 'word$i '});
      }
      await frames(tester, 62);
    });
    // The typewriter steps every 75 ms: about 13 a second, each one word or
    // more of the one answer.
    expect(stream['_Bubble'], inInclusiveRange(2, 15), reason: 'the answer, step by step: $stream');
    expect(stream['_MineRow'], 0, reason: 'nothing else: $stream');
    expect(stream['_Header'], 0, reason: 'nor the header: $stream');
    expect(stream['ConversationPage'], 0);
  });

  testWidgets('the keyboard rising: no row and not the page is built again on its frames', (tester) async {
    await openThread(tester, threadServer(long: 20));
    final rising = await BuildCounts.during(() async {
      for (var i = 1; i <= 16; i++) {
        setKeyboard(tester, Phone.iphone13, 336 * Curves.easeOut.transform(i / 16));
        await tester.pump(frame);
      }
    });
    expect(rising.of(messageRows), 0, reason: 'the keyboard: $rising');
    expect(rising['ConversationPage'], 0, reason: 'nor the page');
    expect(rising['_Header'], 0, reason: 'nor the header');
    expect(rising['_KeyboardRoom'], 16, reason: 'one small widget reads it, once a frame');
  });

  testWidgets('Home, Messages and Help under a conversation wait while it changes, and catch up when they show again', (tester) async {
    final server = threadServer(long: 20);
    usePhone(tester, Phone.iphone13);
    final channel = ManualChannel(autoConnect: true);
    final c = controllerOn(server, channel);
    await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: TargetPlatform.iOS), home: GLSupportChatPage(controller: c)));
    await frames(tester, 40);
    await tester.tap(find.text('Send us a message'));
    await frames(tester, 40);
    const tabs = <String>{'MessengerTabs', 'HomeTab', '_Home', 'MessagesTab', 'HelpTab', '_RecentCard'};
    final stream = await BuildCounts.during(() async {
      channel.server('ai:stream_start', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'authorName': 'GL Assistant', 'createdAt': now()});
      for (var i = 0; i < 20; i++) {
        channel.server('ai:stream_chunk', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'delta': 'word$i '});
      }
      await frames(tester, 62);
      channel.server('message:created', <String, dynamic>{
        'id': 'r1', 'conversationId': 'conv-1', 'body': 'Your card is on its way.', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John', 'createdAt': now(),
      });
      await frames(tester, 10);
    });
    expect(stream.of(tabs), 0, reason: 'out of sight under the conversation: $stream');
    await tester.tap(find.byTooltip('Back').last);
    await frames(tester, 40);
    expect(find.text('Your card is on its way.'), findsOneWidget, reason: "Home's recent message, caught up");
  });
}
