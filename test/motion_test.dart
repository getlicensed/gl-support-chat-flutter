import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';
import 'package:gl_support_chat/src/ui/sheet.dart';
import 'package:gl_support_chat/src/ui/tabs.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';

// Motion, as in Intercom's messenger (12 Oct): what comes in live fades in,
// the typing row opens and closes in place and the reply takes it, the tabs
// cross-fade, Home fades in after the spinner, the sheet rises and falls —
// and none of it when the phone asks for less motion.
void main() {
  late GatedServer server;
  late FakeChannel channel;

  const levi = '9b1c3a5e-0000-4000-8000-000000000001';
  String at(int minute) => DateTime.utc(2026, 10, 6, 11, minute).toIso8601String();

  setUp(() {
    server = GatedServer();
    channel = FakeChannel();
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Let me check.')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('m1', 'visitor', 'Where is my licence card?', at: at(0)),
      msg('m2', 'agent', 'Let me check.', at: at(1)),
    ]);
  });

  void lessMotion(WidgetTester tester) {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  Finder page() => find.byType(ConversationPage);
  Finder threadList() => find.descendant(of: page(), matching: find.byType(ListView));
  Finder composer() => find.descendant(of: page(), matching: find.byType(TextField)).last;
  Finder typingRow() => find.bySemanticsLabel(RegExp('typing', caseSensitive: false));

  /// The typing row's place in the thread (the row's label sits on the list item above it).
  Finder typingSlot() => find.byKey(const ValueKey<String>('typing'));

  /// The fade a row of the thread is in, if it came in live; null if it is simply there.
  FadeTransition? fadeOf(WidgetTester tester, String text) {
    final f = find.descendant(of: threadList(), matching: find.ancestor(of: find.text(text), matching: find.byType(FadeTransition)));
    final found = f.evaluate();
    return found.isEmpty ? null : found.first.widget as FadeTransition;
  }

  /// How far below its place a row of the thread is drawn.
  double riseOf(WidgetTester tester, String text) {
    var y = 0.0;
    for (final e in find.descendant(of: threadList(), matching: find.ancestor(of: find.text(text), matching: find.byType(Transform))).evaluate()) {
      y += (e.widget as Transform).transform.getTranslation().y;
    }
    return y;
  }

  Future<void> openChat(WidgetTester tester, {Phone phone = Phone.iphone13}) async {
    usePhone(tester, phone);
    await openMessenger(tester, server, channel, screen: GLSupportChatScreen.conversation('conv-1'));
    await settle(tester);
  }

  /// A message from the server, as the inbox sends one, and the frame that draws it.
  Future<void> arrive(WidgetTester tester, Map<String, dynamic> m) async {
    channel.server('message:created', m);
    await tester.pump(); // the controller tells the screens in the next frame
  }

  group('messages', () {
    testWidgets('a reply that comes in live fades in and rises, once; history and a catch-up are simply there', (tester) async {
      await openChat(tester);
      expect(fadeOf(tester, 'Let me check.'), isNull, reason: 'history is simply there');
      expect(fadeOf(tester, 'Where is my licence card?'), isNull);

      await arrive(tester, msg('m3', 'agent', 'It was posted on Monday.', at: at(2)));
      await tester.pump(const Duration(milliseconds: 16));
      final fading = fadeOf(tester, 'It was posted on Monday.');
      expect(fading, isNotNull, reason: 'it came in live');
      expect(fading!.opacity.value, inExclusiveRange(0, 1));
      expect(riseOf(tester, 'It was posted on Monday.'), inExclusiveRange(0, 8), reason: 'a few pixels below its place, on its way up');
      await tester.pump(const Duration(milliseconds: 220));
      expect(fadeOf(tester, 'It was posted on Monday.')!.opacity.value, 1);
      expect(riseOf(tester, 'It was posted on Monday.'), 0);

      // Redrawn for something else: it does not play again.
      channel.server('presence:update', <String, dynamic>{'agentsOnline': 1});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(fadeOf(tester, 'It was posted on Monday.')!.opacity.value, 1);

      // A catch-up (a reconnect, the app back from the background) brings one in: simply there.
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Where is my licence card?', at: at(0)),
        msg('m2', 'agent', 'Let me check.', at: at(1)),
        msg('m3', 'agent', 'It was posted on Monday.', at: at(2)),
        msg('m4', 'agent', 'Tracking: RM123456.', at: at(3)),
      ]);
      channel.drop();
      channel.connect(); // the connect fetches what was missed
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await settle(tester, frames: 2);
      expect(find.text('Tracking: RM123456.'), findsOneWidget);
      expect(fadeOf(tester, 'Tracking: RM123456.'), isNull, reason: 'a catch-up does not animate');
      expect(fadeOf(tester, 'It was posted on Monday.')?.opacity.value ?? 1, 1, reason: "the fetch's copy keeps the row as it was, not played again");
    });

    testWidgets('reopened: what came in meanwhile is simply there', (tester) async {
      await openChat(tester);
      await tester.tap(find.byTooltip('Back'));
      await settle(tester);
      expect(page(), findsNothing);
      // In live while the customer is on the Messages list.
      channel.server('message:created', msg('m3', 'agent', 'It was posted on Monday.', at: at(2)));
      await settle(tester, frames: 2);
      await tester.tap(find.text('Send us a message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.descendant(of: threadList(), matching: find.text('It was posted on Monday.')), findsOneWidget);
      expect(fadeOf(tester, 'It was posted on Monday.'), isNull);
      await settle(tester);
    });

    testWidgets("the customer's own message rises in as they send it; the server's copy takes its place without a second fade", (tester) async {
      final ack = Completer<void>();
      final slow = _SlowChannel(ack.future);
      slow.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m9', 'visitor', data['body'] as String, at: at(5))};
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, slow, screen: GLSupportChatScreen.conversation('conv-1'));
      await settle(tester);
      await tester.enterText(composer(), 'Thank you');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Sending…'), findsOneWidget);
      expect(fadeOf(tester, 'Thank you')!.opacity.value, inExclusiveRange(0, 1));
      await settle(tester, frames: 4);
      ack.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('Sending…'), findsNothing);
      expect(find.byIcon(Icons.done), findsNWidgets(2), reason: 'delivered, as the first one was');
      expect(fadeOf(tester, 'Thank you'), isNull, reason: 'the confirmed copy is simply there, in the same place');
    });

    testWidgets("the customer's answer from a workflow button comes in with a fade; the server's copy of a bubble on its way does not", (tester) async {
      final ack = Completer<void>();
      final slow = _SlowChannel(ack.future);
      slow.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m9', 'visitor', data['body'] as String, at: at(5))};
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, slow, screen: GLSupportChatScreen.conversation('conv-1'));
      await settle(tester);

      slow.server('message:created', msg('v2', 'visitor', 'CCTV', at: at(2)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(fadeOf(tester, 'CCTV')!.opacity.value, inExclusiveRange(0, 1));
      await settle(tester, frames: 4);

      await tester.enterText(composer(), 'Thank you');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await settle(tester, frames: 6);
      // The server's copy comes over the connection before the answer to the send.
      slow.server('message:created', msg('m9', 'visitor', 'Thank you', at: DateTime.now().toUtc().toIso8601String()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final copies = find.descendant(of: threadList(), matching: find.text('Thank you'));
      final fading = find.descendant(of: threadList(), matching: find.ancestor(of: copies, matching: find.byType(FadeTransition)));
      for (final f in fading.evaluate()) {
        expect((f.widget as FadeTransition).opacity.value, 1, reason: 'the bubble on its way has come in; its copy does not fade in again');
      }
      ack.complete();
      await settle(tester, frames: 4);
      expect(copies, findsOneWidget);
    });

    testWidgets('a long thread at the latest: a reply takes the typing row\'s place without a jump, then the thread glides up', (tester) async {
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++)
          msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
      ]);
      await openChat(tester);
      final last = find.text('Message number 29, about the licence card and when it will arrive.');

      final open = tester.getRect(last).top;
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final rowBox = find.descendant(of: typingSlot(), matching: find.byType(ClipRect)).first;
      final growing = tester.getSize(rowBox).height;
      final dots = find.descendant(of: typingSlot(), matching: find.byType(FadeTransition)).first;
      expect(tester.widget<FadeTransition>(dots).opacity.value, inExclusiveRange(0, 1), reason: 'the typing row fades in');
      await tester.pump(const Duration(milliseconds: 250));
      final full = tester.getSize(rowBox).height;
      expect(growing, lessThan(full), reason: 'and grows into place');
      expect(tester.getRect(last).top, lessThan(open), reason: 'the thread makes room for it');

      // The teammate sends: "stopped typing" first, the message just after.
      final before = tester.getRect(last).top;
      channel.server('typing:stop', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(typingRow(), findsOneWidget, reason: 'the row waits a moment for the reply');
      expect(tester.getRect(last).top, before);
      await arrive(tester, msg('r1', 'agent', 'Found it: posted on Monday.', at: at(30)));
      expect(typingRow(), findsNothing, reason: 'the reply takes its place at once');
      expect(tester.getRect(last).top, before, reason: 'nothing on screen jumps');
      final reply = find.text('Found it: posted on Monday.');
      final view = tester.getRect(threadList());
      expect(tester.getRect(reply).bottom, greaterThan(view.bottom), reason: 'the rest of the reply is just below, out of view');
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final halfway = tester.getRect(last).top;
      expect(halfway, lessThan(before), reason: 'then the thread glides up to it');
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getRect(last).top, lessThan(halfway));
      final scroll = tester.widget<ListView>(threadList()).controller!;
      expect(scroll.offset, 0, reason: 'at the latest');
      expect(tester.getRect(reply).bottom, lessThanOrEqualTo(view.bottom));
    });

    testWidgets('a short thread (it cannot scroll): what is on screen stays put as a reply comes in, then eases up', (tester) async {
      await openChat(tester);
      final last = find.descendant(of: threadList(), matching: find.text('Let me check.'));
      final before = tester.getRect(last).top;
      expect(tester.widget<ListView>(threadList()).controller!.position.maxScrollExtent, 0, reason: 'shorter than the screen');
      await arrive(tester, msg('r1', 'agent', 'Found it: posted on Monday, so it should be with you by Thursday.', at: at(3)));
      expect(tester.getRect(last).top, before, reason: 'nothing jumps');
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      final halfway = tester.getRect(last).top;
      expect(halfway, lessThan(before), reason: 'easing up');
      await tester.pump(const Duration(milliseconds: 200));
      final settled = tester.getRect(last).top;
      expect(settled, lessThan(halfway));
      await settle(tester);
      expect(tester.getRect(last).top, settled, reason: 'and stays');
      // Taps land where the rows are drawn.
      expect(tester.getRect(find.text('Found it: posted on Monday, so it should be with you by Thursday.')).bottom, lessThanOrEqualTo(tester.getRect(threadList()).bottom));
    });

    testWidgets('a reader further up keeps their place while someone types below and stops', (tester) async {
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++)
          msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
      ]);
      await openChat(tester);
      // Just past "at the latest": the foot of the thread is still built, out of view.
      tester.widget<ListView>(threadList()).controller!.jumpTo(200);
      await settle(tester);
      final view = tester.getRect(threadList());
      final reading = find.descendant(of: threadList(), matching: find.textContaining('Message number')).evaluate().firstWhere((e) {
        final top = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
        return top > view.top && top < view.bottom - 40;
      });
      final text = (reading.widget as Text).textSpan!.toPlainText();
      final at = tester.getRect(find.text(text)).top;

      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
      await tester.pump();
      expect(tester.getRect(find.text(text)).top, at, reason: 'not a pixel, in the very next frame');
      await settle(tester);
      expect(tester.getRect(find.text(text)).top, at);
      channel.server('typing:stop', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
      await tester.pump();
      await settle(tester);
      expect(tester.getRect(find.text(text)).top, at);
    });

    testWidgets('typing that stops with no reply closes in place', (tester) async {
      await openChat(tester);
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
      await settle(tester, frames: 5);
      expect(typingRow(), findsOneWidget);
      final rowBox = find.descendant(of: typingSlot(), matching: find.byType(ClipRect)).first;
      final full = tester.getSize(rowBox).height;
      channel.server('typing:stop', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.getSize(rowBox).height, full, reason: 'a moment first, for a reply');
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getSize(rowBox).height, inExclusiveRange(0, full), reason: 'then it closes');
      await tester.pump(const Duration(milliseconds: 120));
      expect(typingRow(), findsNothing);
    });
  });

  group('tabs, Home and the sheet', () {
    testWidgets('the tabs cross-fade, and each keeps its state', (tester) async {
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, channel);
      final greeting = find.text('Hi Ayesha 👋');
      expect(greeting, findsOneWidget);
      await tester.tap(find.text('Messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(greeting, findsOneWidget, reason: 'Home stays beneath while Messages fades in');
      // The tab's own fade, not the route's above it.
      final messages = find.descendant(of: find.byType(MessengerTabs), matching: find.ancestor(of: find.byType(MessagesTab), matching: find.byType(FadeTransition))).first;
      expect(tester.widget<FadeTransition>(messages).opacity.value, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 120));
      expect(greeting, findsNothing, reason: 'then Home goes');
      expect(tester.widget<FadeTransition>(messages).opacity.value, 1);

      await tester.tap(find.text('Help').last);
      await settle(tester, frames: 4);
      await tester.enterText(find.descendant(of: find.byType(HelpTab), matching: find.byType(TextField)), 'renew');
      await tester.tap(find.text('Home'));
      await settle(tester, frames: 4);
      await tester.tap(find.text('Help').last);
      await settle(tester, frames: 4);
      expect(find.descendant(of: find.byType(HelpTab), matching: find.text('renew')), findsOneWidget, reason: 'the search typed is still there');
    });

    testWidgets('Home fades in once when it arrives after the spinner; opened again, it is simply there', (tester) async {
      usePhone(tester, Phone.iphone13);
      server.hold(<String>['/widget/auth']);
      final c = controllerFor(server, channel);
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c)));
      await tester.pump();
      expect(find.text('Connecting to support…'), findsOneWidget);
      server.release();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final greeting = find.text('Hi Ayesha 👋');
      expect(greeting, findsOneWidget);
      double opacity() => find
          .ancestor(of: greeting, matching: find.byType(FadeTransition))
          .evaluate()
          .map((e) => (e.widget as FadeTransition).opacity.value)
          .reduce((a, b) => a * b);
      final top = tester.getRect(greeting).top;
      expect(opacity(), inExclusiveRange(0, 1), reason: 'fading in');
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacity(), 1);
      expect(tester.getRect(greeting).top, top, reason: 'opacity only: nothing moves');

      // Closed and opened again for the same customer: Home at once.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c)));
      await tester.pump();
      expect(opacity(), 1);
      await settle(tester);
      c.dispose();
    });

    test('the sheet rises in 400 ms and goes down in 250 ms; at once with less motion', () {
      final route = messengerRoute(const SizedBox(), reduceMotion: false) as MessengerSheetRoute;
      expect(route.transitionDuration, const Duration(milliseconds: 400));
      expect(route.reverseTransitionDuration, const Duration(milliseconds: 250));
      expect(route.opaque, isFalse, reason: 'the app shows behind it');
      expect(route.barrierColor, const Color(0x66000000), reason: 'dimmed by 40%');
      expect(route.settings.name, 'gl_support_chat', reason: 'close pops it by name');
      final still = messengerRoute(const SizedBox(), reduceMotion: true) as MessengerSheetRoute;
      expect(still.transitionDuration, Duration.zero);
      expect(still.reverseTransitionDuration, Duration.zero);
    });
  });

  group('present', () {
    setUp(() async {
      GLSupportChat.debugReset();
      GLSupportChat.debugOverride(
        client: server.client(),
        store: MemorySessionStore(),
        realtime: ({required String apiUrl, required String Function() token}) => channel,
      );
      await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'product-1');
    });
    tearDown(GLSupportChat.debugReset);

    Future<BuildContext> app(WidgetTester tester) async {
      late BuildContext context;
      usePhone(tester, Phone.iphone13);
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const Scaffold(body: Text('The app'));
      })));
      return context;
    }

    double sheetTop(WidgetTester tester) => tester.getTopLeft(find.byType(GLSupportChatPage)).dy;

    testWidgets('the sheet rises from the bottom, decelerating, and goes down again', (tester) async {
      final host = await app(tester);
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final early = sheetTop(tester);
      expect(early, inExclusiveRange(57, 844));
      expect(early, lessThan(57 + 787 * 0.3), reason: 'emphasised deceleration: most of the way up in the first quarter');
      await tester.pump(const Duration(milliseconds: 300));
      expect(sheetTop(tester), 57, reason: 'below the status bar and a 10-point strip of the app');
      await settle(tester);

      Navigator.of(host, rootNavigator: true).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(sheetTop(tester), inExclusiveRange(57, 844), reason: 'going down');
      await tester.pump(const Duration(milliseconds: 131));
      expect(find.byType(GLSupportChatPage), findsNothing, reason: 'gone within 250 ms');
    });

    testWidgets('less motion: the sheet is up at once, and gone at once', (tester) async {
      lessMotion(tester);
      final host = await app(tester);
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(sheetTop(tester), 57);
      await settle(tester);
      Navigator.of(host, rootNavigator: true).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(GLSupportChatPage), findsNothing);
    });
  });

  group('less motion', () {
    testWidgets('nothing fades, grows or glides: a reply, the typing row, the tabs', (tester) async {
      lessMotion(tester);
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        for (var i = 0; i < 30; i++)
          msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
      ]);
      await openChat(tester);

      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'});
      await tester.pump();
      final rowBox = find.descendant(of: typingSlot(), matching: find.byType(ClipRect)).first;
      final full = tester.getSize(rowBox).height;
      expect(full, greaterThan(30), reason: 'whole at once');
      final dots = find.descendant(of: typingSlot(), matching: find.byType(FadeTransition)).first;
      expect(tester.widget<FadeTransition>(dots).opacity.value, 1);

      await arrive(tester, msg('r1', 'agent', 'Found it: posted on Monday.', at: at(30)));
      expect(fadeOf(tester, 'Found it: posted on Monday.'), isNull, reason: 'no fade');
      expect(typingRow(), findsNothing);
      final scroll = tester.widget<ListView>(threadList()).controller!;
      expect(scroll.offset, 0, reason: 'at the latest at once, no glide');

      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
      await tester.pump();
      channel.server('typing:stop', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'});
      await tester.pump();
      expect(typingRow(), findsNothing, reason: 'gone at once');

      await tester.tap(find.byTooltip('Back'));
      await settle(tester);
      await tester.tap(find.text('Home'));
      await tester.pump();
      expect(find.byType(MessagesTab), findsNothing, reason: 'the tab changes at once, no cross-fade');
      expect(find.byType(HomeTab), findsOneWidget);
    });
  });

  // Found by a review of the first version of all this (12 Oct).
  group('review', () {
    List<Map<String, dynamic>> longThread() => <Map<String, dynamic>>[
          for (var i = 0; i < 30; i++)
            msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
        ];
    ScrollController scroll(WidgetTester tester) => tester.widget<ListView>(threadList()).controller!;

    testWidgets('a reply taller than the screen on a small phone with the keyboard up: no error, and it is in view', (tester) async {
      server.details['conv-1'] = detail('conv-1', longThread());
      await openChat(tester, phone: Phone.iphoneSE);
      setKeyboard(tester, Phone.iphoneSE, Phone.iphoneSE.keyboard);
      await settle(tester);
      final long = 'Your card was printed on Monday and posted second class, so allow up to five working days. ' * 5;
      expect(long.length, greaterThan(420));
      await arrive(tester, msg('r1', 'agent', long.trim(), at: at(40)));
      await settle(tester);
      expect(scroll(tester).offset, 0);
      expect(find.descendant(of: threadList(), matching: find.text(long.trim())), findsOneWidget);
    });

    testWidgets('a row that came in live does not play again when scrolled away and back', (tester) async {
      server.details['conv-1'] = detail('conv-1', longThread());
      await openChat(tester);
      const reply = 'Found it: posted on Monday.';
      await arrive(tester, msg('r1', 'agent', reply, at: at(40)));
      await settle(tester);
      scroll(tester).jumpTo(2000);
      await settle(tester, frames: 2);
      expect(find.descendant(of: threadList(), matching: find.text(reply)), findsNothing, reason: 'far off screen: no longer built');
      scroll(tester).jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(fadeOf(tester, reply), isNull, reason: 'built again, simply there');
    });

    testWidgets('a reply that came while the reader was up the thread is simply there when they go down to it', (tester) async {
      server.details['conv-1'] = detail('conv-1', longThread());
      await openChat(tester);
      scroll(tester).jumpTo(2000);
      await settle(tester, frames: 2);
      const reply = 'Found it: posted on Monday.';
      await arrive(tester, msg('r1', 'agent', reply, at: at(40)));
      await settle(tester, frames: 3);
      expect(find.text('New message'), findsOneWidget);
      await tester.tap(find.text('New message'));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        final fade = fadeOf(tester, reply);
        expect(fade == null || fade.opacity.value == 1, isTrue, reason: 'no fade on the way down');
      }
    });

    testWidgets('a second reply landing while the thread still glides to the first: no pill, and both in view', (tester) async {
      server.details['conv-1'] = detail('conv-1', longThread());
      await openChat(tester);
      final tall = 'Your card was printed on Monday and posted second class, so allow up to five working days. ' * 3;
      await arrive(tester, msg('r1', 'agent', tall.trim(), at: at(40)));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));
      expect(scroll(tester).offset, greaterThan(120), reason: 'still on its way down');
      await arrive(tester, msg('r2', 'agent', 'And here is the tracking number.', at: at(41)));
      expect(find.text('New message'), findsNothing);
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('New message'), findsNothing);
      await settle(tester);
      expect(find.textContaining('New message'), findsNothing);
      expect(scroll(tester).offset, 0);
      final view = tester.getRect(threadList());
      expect(tester.getRect(find.text('And here is the tracking number.')).bottom, lessThanOrEqualTo(view.bottom));
    });

    testWidgets('a tab and straight back: the one left is never shown whole over it', (tester) async {
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, channel);
      Finder fadeOver(Type tab) => find.descendant(of: find.byType(MessengerTabs), matching: find.ancestor(of: find.byType(tab), matching: find.byType(FadeTransition))).first;
      await tester.tap(find.text('Messages'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 60));
      final messagesShown = tester.widget<FadeTransition>(fadeOver(MessagesTab)).opacity.value;
      expect(messagesShown, inExclusiveRange(0, 1));
      await tester.tap(find.text('Home'));
      await tester.pump();
      // Messages is beneath now, whole; Home over it shows as much of itself as it did.
      final home = tester.widget<FadeTransition>(fadeOver(HomeTab)).opacity.value;
      expect(home, closeTo(1 - messagesShown, 0.05), reason: 'Messages stays as faint as it was');
      await settle(tester, frames: 4);
      expect(find.byType(MessagesTab), findsNothing);
      expect(tester.widget<FadeTransition>(fadeOver(HomeTab)).opacity.value, 1);
    });

    testWidgets('a hidden tab takes no focus: the help search lets go when the customer leaves Help', (tester) async {
      usePhone(tester, Phone.iphone13);
      server.articles = <Map<String, dynamic>>[<String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': null}];
      await openMessenger(tester, server, channel);
      await tester.tap(find.text('Help').last);
      await settle(tester, frames: 4);
      final field = find.descendant(of: find.byType(HelpTab), matching: find.byType(EditableText));
      await tester.tap(field);
      await tester.pump();
      final node = tester.widget<EditableText>(field).focusNode;
      expect(node.hasFocus, isTrue);
      await tester.tap(find.text('Home'));
      await settle(tester, frames: 4);
      expect(node.hasFocus, isFalse);
      expect(node.canRequestFocus, isFalse, reason: 'nothing hidden takes focus');
    });
  });
}

/// A connection whose answers wait for [gate]: the message on its way is
/// drawn before the server's copy replaces it, as on a phone.
class _SlowChannel extends FakeChannel {
  _SlowChannel(this.gate);
  final Future<void> gate;

  @override
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 20)}) async {
    await gate;
    return super.request(event, data, timeout: timeout);
  }
}
