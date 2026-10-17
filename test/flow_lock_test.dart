import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';

// 0.4.10, from the CS manager's report of 17 Oct: "Learners should not have
// the option to type a manual message when the Workflow is active." The
// composer (and the photo button) is locked for as long as the workflow
// runs, as the server says it — GET /widget/messages `flow` and the
// `flow:update` event — between a tap and the next question too, except on
// buttons whose path lets the customer type. A server that says nothing of
// the flow gets 0.4.9's lock, on the last message, exactly.

Map<String, dynamic> choice({bool letType = false}) => <String, dynamic>{'awaiting': 'choice', 'letCustomerType': letType, 'workingUntil': null};
Map<String, dynamic> answer() => <String, dynamic>{'awaiting': 'answer', 'letCustomerType': false, 'workingUntil': null};
Map<String, dynamic> working([DateTime? until]) =>
    <String, dynamic>{'awaiting': null, 'letCustomerType': false, 'workingUntil': until?.toUtc().toIso8601String()};

/// The server's `flow:update` for conv-1.
Map<String, dynamic> update(Map<String, dynamic>? flow, {String conversationId = 'conv-1'}) => <String, dynamic>{'conversationId': conversationId, 'flow': flow};

String at(int minute) => DateTime.utc(2026, 10, 17, 10, minute).toIso8601String();

/// The bot's question with buttons; [letType]: its path lets the customer type.
Map<String, dynamic> buttons(String id, {bool letType = false, int minute = 1}) => msg(id, 'bot', 'Which course is it about?', at: at(minute), meta: <String, dynamic>{
      'buttons': <Object?>[
        <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'},
        <String, dynamic>{'id': 'b2', 'label': 'CCTV'},
      ],
      'lockComposer': !letType,
    });

/// The bot asking for a detail.
Map<String, dynamic> askEmail(String id, {int minute = 3}) => msg(id, 'bot', 'What is your email?', at: at(minute), meta: <String, dynamic>{
      'collect': <String, dynamic>{'field': 'email', 'label': 'Email', 'inputType': 'email'},
      'lockComposer': true,
    });

void main() {
  late FakeServer server;
  late FakeChannel channel;

  setUp(() {
    server = FakeServer();
    channel = FakeChannel();
  });

  /// conv-1 open, ending with [thread]; the server says [flow] — or nothing
  /// of it, for a server from before 17 Oct.
  void serve(List<Map<String, dynamic>> thread, {Map<String, dynamic>? flow, bool saysFlow = true}) {
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0, if (saysFlow) 'flow': flow};
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Which course is it about?', authorType: 'bot')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[msg('m0', 'visitor', 'Hi', at: at(0)), ...thread]);
  }

  group('the server says what the workflow is doing', () {
    test('from GET /widget/messages: each state locks, or not, and says why', () async {
      final cases = <(String, List<Map<String, dynamic>>, Map<String, dynamic>?, String?, String?)>[
        // what, the thread's end, flow, the hint, the live question
        ('buttons', <Map<String, dynamic>>[buttons('p1')], choice(), 'Choose an option above', 'p1'),
        ('buttons on a path that lets them type', <Map<String, dynamic>>[buttons('p1', letType: true)], choice(letType: true), null, 'p1'),
        ('a detail asked for', <Map<String, dynamic>>[askEmail('p2')], answer(), 'Answer the question above', 'p2'),
        ('between steps', <Map<String, dynamic>>[buttons('p1'), msg('v1', 'visitor', 'CCTV', at: at(2))], working(DateTime.now().add(const Duration(seconds: 20))), 'One moment…', null),
        ('no workflow: a teammate took over, the buttons are dead', <Map<String, dynamic>>[buttons('p1')], null, null, null),
      ];
      for (final (what, thread, flow, hint, prompt) in cases) {
        server = FakeServer();
        channel = FakeChannel();
        serve(thread, flow: flow);
        final c = controllerFor(server, channel);
        await c.start();
        expect(c.flowKnown, isTrue, reason: what);
        expect(c.composerLock, hint, reason: what);
        expect(c.livePrompt?.id, prompt, reason: what);
        c.dispose();
      }
    });

    test('flow:update: every change in turn, the end too', () async {
      serve(<Map<String, dynamic>>[msg('a1', 'agent', 'Hello', at: at(1))], flow: null);
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.composerLock, isNull, reason: 'no workflow');

      channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
      expect(c.composerLock, 'One moment…', reason: 'it started: the bot is typing');
      channel.server('message:created', buttons('p1', minute: 2));
      channel.server('flow:update', update(choice()));
      expect(c.composerLock, 'Choose an option above');
      expect(c.livePrompt?.id, 'p1');

      await c.choose(c.livePrompt!, const FlowButton('b2', 'CCTV'));
      channel.server('message:created', msg('v1', 'visitor', 'CCTV', at: at(3)));
      channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
      expect(c.composerLock, 'One moment…', reason: 'between the tap and the next question: locked (0.4.9 opened it here)');

      channel.server('message:created', askEmail('p2', minute: 4));
      channel.server('flow:update', update(answer()));
      expect(c.composerLock, 'Answer the question above');
      expect(c.livePrompt?.id, 'p2');

      expect(await c.collect(c.livePrompt!, 'ayesha@example.com'), isTrue);
      channel.server('message:created', msg('v2', 'visitor', 'ayesha@example.com', at: at(5)));
      channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
      expect(c.composerLock, 'One moment…');

      channel.server('message:created', buttons('p3', letType: true, minute: 6));
      channel.server('flow:update', update(choice(letType: true)));
      expect(c.composerLock, isNull, reason: 'this path lets them type');
      expect(c.livePrompt?.id, 'p3', reason: 'and its buttons are live');

      channel.server('flow:update', update(null));
      expect(c.composerLock, isNull, reason: 'the flow ended (they typed, or a teammate took over)');
      expect(c.livePrompt, isNull, reason: 'its buttons are dead');
      c.dispose();
    });

    test("another conversation's update, or one without the field, changes nothing", () async {
      serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
      final c = controllerFor(server, channel);
      await c.start();
      channel.server('flow:update', update(null, conversationId: 'conv-2'));
      channel.server('flow:update', <String, dynamic>{'conversationId': 'conv-1'});
      expect(c.composerLock, 'Choose an option above');
      expect(c.livePrompt?.id, 'p1');
      c.dispose();
    });

    test('a teammate assigns without replying and the update is missed: a tap is told not_in_flow, and the composer opens', () async {
      serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.composerLock, 'Choose an option above');
      channel.answers['workflow:choose'] = (_) => <String, dynamic>{'ok': false, 'error': 'not_in_flow'};
      await c.choose(c.livePrompt!, const FlowButton('b1', 'Door Supervisor'));
      expect(c.flow, isNull);
      expect(c.flowKnown, isTrue);
      expect(c.composerLock, isNull, reason: 'unlocked');
      expect(c.livePrompt, isNull, reason: 'the buttons are no longer live');
      expect(c.flowNotice, isNull, reason: 'nothing to tell the customer');
      c.dispose();
    });

    test('the same for a detail asked for', () async {
      serve(<Map<String, dynamic>>[askEmail('p2')], flow: answer());
      final c = controllerFor(server, channel);
      await c.start();
      channel.answers['workflow:collect'] = (_) => <String, dynamic>{'ok': false, 'error': 'not_in_flow'};
      expect(await c.collect(c.livePrompt!, 'ayesha@example.com'), isTrue, reason: 'the box closes');
      expect(c.composerLock, isNull);
      expect(c.livePrompt, isNull);
      c.dispose();
    });

    test('a server from before 17 Oct, without `flow`: exactly 0.4.9 — the lock on the last message alone', () async {
      serve(<Map<String, dynamic>>[buttons('p1')], saysFlow: false);
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.flowKnown, isFalse);
      expect(c.composerLock, 'Choose an option above');
      channel.server('message:created', msg('v1', 'visitor', 'CCTV', at: at(2)));
      expect(c.composerLock, isNull, reason: 'between the tap and the next question it was open, and stays so');
      channel.server('message:created', buttons('p3', letType: true, minute: 3));
      expect(c.composerLock, isNull);
      expect(c.livePrompt?.id, 'p3');
      channel.answers['workflow:choose'] = (_) => <String, dynamic>{'ok': false, 'error': 'not_in_flow'};
      await c.choose(c.livePrompt!, const FlowButton('b1', 'Door Supervisor'));
      expect(c.flowKnown, isFalse, reason: 'a tap told not_in_flow settles the question, as before, and no more');
      expect(c.livePrompt, isNull);
      channel.server('message:created', buttons('p4', minute: 4));
      expect(c.livePrompt?.id, 'p4', reason: 'the next question is live');
      expect(c.composerLock, 'Choose an option above');
      c.dispose();
    });

    test('a reconnect, a refresh and a reload restore it; a sign-out forgets it', () async {
      serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.composerLock, 'Choose an option above');

      // Off the network while the bot moved on: the updates were missed.
      channel.drop();
      serve(<Map<String, dynamic>>[buttons('p1'), msg('v1', 'visitor', 'CCTV', at: at(2)), askEmail('p2')], flow: answer());
      channel.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.composerLock, 'Answer the question above', reason: 'the connect caught up');
      expect(c.livePrompt?.id, 'p2');

      serve(<Map<String, dynamic>>[buttons('p1'), msg('v1', 'visitor', 'CCTV', at: at(2)), askEmail('p2'), msg('a1', 'agent', 'Levi here.', at: at(4))], flow: null);
      await c.refresh();
      expect(c.composerLock, isNull, reason: 'a teammate took over meanwhile');

      // The app started again: a new controller.
      serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
      final again = controllerFor(server, FakeChannel());
      await again.start();
      expect(again.composerLock, 'Choose an option above');

      again.reset();
      expect(again.flowKnown, isFalse);
      expect(again.flow, isNull);
      c.dispose();
      again.dispose();
    });

    test('no conversation open, and the field left out: no workflow runs, once the server has said it ever does', () async {
      serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
      final c = controllerFor(server, channel);
      await c.start();
      c.setViewingLive(true); // reading it as a teammate closes it
      server.openInfo = <String, dynamic>{'conversationId': null, 'unreadCount': 0, 'csat': null};
      await c.refresh();
      expect(c.live, isNotEmpty, reason: 'kept on screen while they read it');
      expect(c.flowKnown, isTrue);
      expect(c.composerLock, isNull, reason: 'not the closed one\'s last question');
      expect(c.livePrompt, isNull);

      // A server that has never said: as 0.4.9.
      final older = FakeServer();
      older.openInfo = <String, dynamic>{'conversationId': null, 'unreadCount': 0, 'csat': null};
      final o = controllerFor(older, FakeChannel());
      await o.start();
      expect(o.flowKnown, isFalse);
      c.dispose();
      o.dispose();
    });

    test('a fetch that went out before a flow:update brings older news: it is not taken over it', () async {
      final gated = GatedServer();
      server = gated;
      serve(<Map<String, dynamic>>[buttons('p1')], flow: working(DateTime.now().add(const Duration(seconds: 20))));
      final c = controllerFor(gated, channel);
      await c.start();
      expect(c.composerLock, 'One moment…');
      gated.hold(<String>['/widget/messages']);
      final refreshed = c.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      channel.server('flow:update', update(choice()));
      gated.release();
      await refreshed;
      expect(c.composerLock, 'Choose an option above', reason: "the update, not the fetch's working");
      c.dispose();
    });

    test('FlowState reads the server defensively', () {
      expect(FlowState.fromJson(null), isNull);
      expect(FlowState.fromJson('choice'), isNull);
      final f = FlowState.fromJson(<String, dynamic>{'awaiting': null, 'letCustomerType': 'yes', 'workingUntil': 'soon'})!;
      expect(f.working, isTrue);
      expect(f.letCustomerType, isFalse);
      expect(f.workingUntil, isNull);
      expect(OpenConversationInfo.fromJson(<String, dynamic>{'conversationId': 'c'}).saysFlow, isFalse);
      expect(OpenConversationInfo.fromJson(<String, dynamic>{'conversationId': 'c', 'flow': null}).saysFlow, isTrue);
    });
  });

  testWidgets('workingUntil passes with no word from the server: the composer opens (a pretend clock)', (tester) async {
    final t0 = DateTime.utc(2026, 10, 17, 10);
    serve(<Map<String, dynamic>>[msg('a1', 'agent', 'Hello', at: at(1))], flow: null);
    final c = controllerFor(server, channel, clock: () => t0);
    await c.start();

    channel.server('flow:update', update(working(t0.add(const Duration(seconds: 8)))));
    expect(c.composerLock, 'One moment…');
    await tester.pump(const Duration(milliseconds: 7900));
    expect(c.composerLock, 'One moment…', reason: 'not yet');
    await tester.pump(const Duration(milliseconds: 200));
    expect(c.composerLock, isNull, reason: 'its time passed: open');
    expect(c.flowKnown, isTrue);

    // A word before the time: the clock is the old one's, and stops.
    channel.server('flow:update', update(working(t0.add(const Duration(seconds: 8)))));
    await tester.pump(const Duration(seconds: 2));
    channel.server('message:created', buttons('p1', minute: 2));
    channel.server('flow:update', update(choice()));
    await tester.pump(const Duration(seconds: 10));
    expect(c.composerLock, 'Choose an option above', reason: 'buttons wait as long as it takes');
    expect(c.livePrompt?.id, 'p1');

    // Far ahead — a phone whose clock runs slow reads it so: two minutes at most.
    channel.server('flow:update', update(working(t0.add(const Duration(hours: 1)))));
    await tester.pump(MessengerController.longestWork - const Duration(seconds: 1));
    expect(c.composerLock, 'One moment…');
    await tester.pump(const Duration(seconds: 2));
    expect(c.composerLock, isNull);
    expect(c.livePrompt?.id, 'p1', reason: 'a lapse opens the box; it does not kill a question');

    // Already past — a phone whose clock runs fast: open at once, as 0.4.9 was.
    channel.server('flow:update', update(working(t0.subtract(const Duration(seconds: 5)))));
    expect(c.composerLock, isNull);

    // No time given: the longest.
    channel.server('flow:update', update(working()));
    expect(c.composerLock, 'One moment…');
    await tester.pump(MessengerController.longestWork + const Duration(milliseconds: 10));
    expect(c.composerLock, isNull);
    c.dispose();
  });

  group('on screen', () {
    Finder page() => find.byType(ConversationPage);
    Finder field() => find.descendant(of: page(), matching: find.byType(TextField));
    Finder photo() => find.ancestor(of: find.byIcon(Icons.add_photo_alternate_outlined), matching: find.byType(Pressable));

    Future<MessengerController> openChat(WidgetTester tester, {TargetPlatform platform = TargetPlatform.iOS}) async {
      usePhone(tester, Phone.iphone13);
      final c = controllerFor(server, channel);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: platform),
        home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1')),
      ));
      await settle(tester, frames: 16);
      return c;
    }

    for (final platform in <TargetPlatform>[TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('each state: the hint, the photo button, the buttons (${platform.name})', (tester) async {
        serve(<Map<String, dynamic>>[buttons('p1')], flow: choice());
        await openChat(tester, platform: platform);
        expect(find.text('Choose an option above'), findsOneWidget);
        expect(field(), findsNothing, reason: 'nothing to type in');
        expect(tester.widget<Pressable>(photo()).onTap, isNull, reason: 'no photo either');
        expect(find.text('CCTV'), findsOneWidget);

        channel.server('message:created', msg('v1', 'visitor', 'CCTV', at: at(2)));
        channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
        await settle(tester);
        expect(find.text('One moment…'), findsOneWidget);
        expect(find.text('Choose an option above'), findsNothing);
        expect(field(), findsNothing);

        channel.server('message:created', askEmail('p2'));
        channel.server('flow:update', update(answer()));
        await settle(tester);
        expect(find.text('Answer the question above'), findsOneWidget);
        expect(field(), findsOneWidget, reason: "the bot's own box for the detail, in the thread");
        expect(find.descendant(of: find.byType(ListView), matching: find.byType(TextField)), findsOneWidget);

        channel.server('message:created', msg('v2', 'visitor', 'ayesha@example.com', at: at(4)));
        channel.server('message:created', buttons('p3', letType: true, minute: 5));
        channel.server('flow:update', update(choice(letType: true)));
        await settle(tester);
        expect(field(), findsOneWidget, reason: 'this path lets them type');
        expect(find.text('Type a message…'), findsOneWidget);
        expect(tester.widget<Pressable>(photo()).onTap, isNotNull);
        expect(find.text('Door Supervisor'), findsOneWidget, reason: 'and its buttons are live');

        channel.server('flow:update', update(null));
        await settle(tester);
        expect(find.text('Door Supervisor'), findsNothing, reason: 'the flow ended: no dead buttons');
        expect(field(), findsOneWidget);
        expect(find.bySemanticsLabel('Send'), findsOneWidget);
      });
    }

    testWidgets('a lock that comes while they type puts the keyboard away; the draft is there when it goes', (tester) async {
      serve(<Map<String, dynamic>>[buttons('p1', letType: true)], flow: choice(letType: true));
      await openChat(tester);
      await tester.tap(field());
      await tester.enterText(field(), 'My booking reference is');
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
      await settle(tester);
      expect(tester.testTextInput.isVisible, isFalse, reason: 'nothing to type in');
      expect(field(), findsNothing);
      channel.server('flow:update', update(choice(letType: true)));
      await settle(tester);
      expect(tester.widget<TextField>(field()).controller!.text, 'My booking reference is');
    });
  });

  // Frame by frame, 16 ms apart, as usual and with less motion asked for
  // (the messenger moves the same either way: 0.4.7).
  for (final lessMotion in <bool>[false, true]) {
    group(lessMotion ? 'frames, less motion asked for:' : 'frames:', () {
      const frame = Duration(milliseconds: 16);
      Finder page() => find.byType(ConversationPage);
      Finder field() => find.descendant(of: page(), matching: find.byType(TextField));
      Finder box() => find.ancestor(of: find.byIcon(Icons.add_photo_alternate_outlined), matching: find.byType(AnimatedSize)).first;

      setUp(() {
        if (!lessMotion) return;
        final dispatcher = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
        dispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
      });

      double opacityOf(WidgetTester tester, Finder f) {
        if (f.evaluate().isEmpty) return 0;
        var o = 1.0;
        for (final e in find.ancestor(of: f.first, matching: find.byType(FadeTransition)).evaluate()) {
          o *= (e.widget as FadeTransition).opacity.value;
        }
        return o;
      }

      Future<void> openChat(WidgetTester tester) async {
        usePhone(tester, Phone.iphone13);
        final c = controllerFor(server, channel);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1')),
        ));
        await settle(tester, frames: 16);
      }

      testWidgets('the lock comes, changes and goes: nothing moves, the hints cross-fade', (tester) async {
        serve(<Map<String, dynamic>>[buttons('p1', letType: true)], flow: choice(letType: true));
        await openChat(tester);
        final top = tester.getTopLeft(box()).dy;
        final height = tester.getSize(box()).height;
        final question = tester.getTopLeft(find.text('Which course is it about?')).dy;
        final photoAt = tester.getCenter(find.byIcon(Icons.add_photo_alternate_outlined));
        final sendAt = tester.getCenter(find.byIcon(Icons.arrow_upward));

        Future<void> through(String step, Map<String, dynamic> flow, String shown, String gone) async {
          channel.server('flow:update', update(flow));
          final seen = <(double, double)>[];
          for (var i = 0; i < 16; i++) {
            await tester.pump(frame);
            expect(tester.getTopLeft(box()).dy, top, reason: '$step, frame ${i + 1}: the composer did not move');
            expect(tester.getSize(box()).height, height, reason: '$step, frame ${i + 1}: nor change its height');
            expect(tester.getTopLeft(find.text('Which course is it about?')).dy, question, reason: '$step, frame ${i + 1}: nor the thread');
            expect(tester.getCenter(find.byIcon(Icons.add_photo_alternate_outlined)), photoAt);
            expect(tester.getCenter(find.byIcon(Icons.arrow_upward)), sendAt);
            seen.add((opacityOf(tester, find.text(shown)), opacityOf(tester, find.text(gone))));
          }
          expect(seen.where((s) => s.$1 > 0.02 && s.$1 < 0.98).length, greaterThanOrEqualTo(5), reason: '$step: "$shown" fades in, not a pop: $seen');
          expect(seen.where((s) => s.$2 > 0.02 && s.$2 < 0.98).length, greaterThanOrEqualTo(5), reason: '$step: "$gone" fades out: $seen');
          expect(seen.last, (1.0, 0.0), reason: step);
        }

        await through('locked between steps', working(DateTime.now().add(const Duration(seconds: 20))), 'One moment…', 'Type a message…');
        expect(field(), findsNothing);
        await through('buttons that do not let them type', choice(), 'Choose an option above', 'One moment…');
        await through('a path that lets them type', choice(letType: true), 'Type a message…', 'Choose an option above');
        expect(field(), findsOneWidget);
      });

      testWidgets('three lines typed when the lock comes: the box eases down to one line, never a jump', (tester) async {
        serve(<Map<String, dynamic>>[buttons('p1', letType: true)], flow: choice(letType: true));
        await openChat(tester);
        final oneLine = tester.getTopLeft(box()).dy;
        await tester.enterText(field(), 'line one\nline two\nline three');
        await settle(tester);
        final threeLines = tester.getTopLeft(box()).dy;
        expect(oneLine - threeLines, greaterThan(30));
        channel.server('flow:update', update(working(DateTime.now().add(const Duration(seconds: 20)))));
        final tops = <double>[threeLines];
        for (var i = 0; i < 30; i++) {
          await tester.pump(frame);
          tops.add(tester.getTopLeft(box()).dy);
        }
        var moving = 0;
        for (var i = 1; i < tops.length; i++) {
          final d = tops[i] - tops[i - 1];
          expect(d, greaterThanOrEqualTo(-0.01), reason: 'only down: $tops');
          expect(d, lessThan(16), reason: 'frame $i moved ${d.toStringAsFixed(1)}: no jump');
          if (d > 0.5) moving++;
        }
        expect(moving, greaterThanOrEqualTo(4), reason: 'over several frames: $tops');
        expect(tops.last, closeTo(oneLine, 0.5), reason: 'one line, the height of the box unlocked');

        // Open again: the three lines are there, the box easing back up.
        channel.server('flow:update', update(null));
        final back = <double>[tops.last];
        for (var i = 0; i < 20; i++) {
          await tester.pump(frame);
          back.add(tester.getTopLeft(box()).dy);
        }
        for (var i = 1; i < back.length; i++) {
          expect(back[i - 1] - back[i], lessThan(16), reason: 'frame $i: no jump up either: $back');
        }
        expect(back.last, closeTo(threeLines, 0.5));
        await tester.pump(const Duration(seconds: 4)); // the "typing" the draft started has stopped
      });
    });
  }
}
