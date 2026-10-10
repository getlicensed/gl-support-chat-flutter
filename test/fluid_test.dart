import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/core/format.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:gl_support_chat/src/messenger_page.dart';

import 'support/fakes.dart';
import 'support/gated.dart';

// 0.4.5: the messenger opens at once from what it already has, sends while
// it connects, catches up when the app comes back, and opens the
// conversation a push is about — and what it keeps never outlives the
// customer it belongs to. The server and the socket are pretend
// (support/fakes.dart, support/gated.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GatedServer server;

  setUp(() {
    server = GatedServer();
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'It is in the post today.')];
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('m1', 'visitor', 'Where is my certificate?'),
      msg('m2', 'agent', 'It is in the post today.'),
    ]);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  int count(String what) => server.paths.where((p) => p == what).length;

  group('opens at once', () {
    test('reopened for the same customer: what it had is there before any request completes, then it refreshes behind it', () async {
      final c = controllerFor(server, FakeChannel());
      c.attach();
      await c.start();
      c.detach();
      expect(c.link, LinkState.connecting, reason: 'closed: the connection goes, what it showed stays');
      expect(c.live.map((m) => m.id), <String>['m1', 'm2']);

      server.hold(GatedServer.opening);
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Where is my certificate?'),
        msg('m2', 'agent', 'It is in the post today.'),
        msg('m3', 'agent', 'Here is the tracking number.'),
      ]);
      final answered = server.finished.length;
      c.attach();
      expect(c.phase, MessengerPhase.ready, reason: 'no spinner: the screens draw what it had');
      expect(c.live.map((m) => m.id), <String>['m1', 'm2']);
      expect(c.conversations.single.lastBody, 'It is in the post today.');
      expect(c.refreshing, isTrue);
      await pumpEventQueue();
      expect(server.finished.length, answered, reason: 'nothing has come back yet');
      expect(server.started, contains('GET /widget/messages'), reason: 'with the token it holds, the catch-up goes out at once, beside the sign-in');

      server.release();
      await pumpEventQueue();
      expect(c.live.map((m) => m.id), <String>['m1', 'm2', 'm3'], reason: 'merged, once each');
      expect(c.refreshing, isFalse);
      c.dispose();
    });

    testWidgets('reopened: the first frame shows what it had — on a small phone, with big text, under a dark app theme', (tester) async {
      final c = controllerFor(server, FakeChannel());
      addTearDown(tester.view.reset);
      Future<void> open(Size size, {double scale = 1.0, ThemeData? theme}) async {
        tester.view.devicePixelRatio = 3;
        tester.view.physicalSize = size * 3;
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: GLSupportChatPage(controller: c),
        ));
      }

      await open(const Size(390, 844));
      expect(find.text('Connecting to support…'), findsOneWidget, reason: 'the very first open has nothing to show yet');
      await settle(tester);
      for (final (size, scale, theme) in <(Size, double, ThemeData?)>[
        (const Size(390, 844), 1.0, null),
        (const Size(375, 667), 1.3, null),
        (const Size(360, 740), 2.0, ThemeData.dark()),
      ]) {
        await tester.pumpWidget(const SizedBox()); // closed
        server.hold(GatedServer.opening);
        await open(size, scale: scale, theme: theme);
        expect(find.text('Connecting to support…'), findsNothing, reason: '$size ×$scale: no spinner');
        expect(find.text('It is in the post today.'), findsOneWidget, reason: '$size ×$scale: the recent message, from what it had');
        server.release();
        await settle(tester);
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('loads side by side', () {
    test('after sign-in the open conversation, the list and the connection all start together', () async {
      final channel = ManualChannel(autoConnect: true);
      server.hold(<String>['/widget/messages', '/widget/conversations']);
      final c = controllerOn(server, channel);
      final starting = c.start();
      await pumpEventQueue();
      expect(server.started, containsAll(<String>['GET /widget/messages', 'GET /widget/conversations']));
      expect(server.finished, isNot(contains('GET /widget/messages')));
      expect(server.finished, isNot(contains('GET /widget/conversations')));
      expect(channel.connects, 1, reason: 'the connection does not wait for the loads');
      expect(c.connected, isTrue);

      server.release(<String>['/widget/conversations']);
      await pumpEventQueue();
      expect(c.conversationsLoaded, isTrue, reason: 'each lands as it comes');
      expect(c.phase, MessengerPhase.loading, reason: 'the first open waits for the open conversation too');
      server.release();
      await starting;
      expect(c.phase, MessengerPhase.ready);
      expect(c.live.length, 2);
      c.dispose();
    });

    test('one load failing blanks nothing else', () async {
      server.failing['/widget/conversations'] = 500;
      var c = controllerOn(server, ManualChannel(autoConnect: true));
      await c.start();
      expect(c.phase, MessengerPhase.ready);
      expect(c.live.map((m) => m.id), <String>['m1', 'm2']);
      expect(c.conversationsLoaded, isTrue);
      c.dispose();

      server.failing
        ..clear()
        ..['/widget/conversations/conv-1'] = 500;
      c = controllerOn(server, ManualChannel(autoConnect: true));
      await c.start();
      expect(c.phase, MessengerPhase.ready, reason: 'it used to be the "cannot open" screen');
      expect(c.conversations.single.id, 'conv-1');
      expect(c.liveId, 'conv-1');
      c.dispose();
    });
  });

  group('sending while it connects', () {
    test('written while connecting: shown at once, sent in order once connected, never twice', () async {
      final channel = ManualChannel();
      channel.answers['visitor:message'] = echo(<String>[]);
      final c = controllerOn(server, channel);
      await c.start();
      expect(c.phase, MessengerPhase.ready);
      expect(c.link, LinkState.connecting);

      final first = c.send('First');
      final second = c.send('Second');
      expect(c.outgoing.map((o) => o.text), <String>['First', 'Second'], reason: 'on screen at once');
      expect(c.outgoing.every((o) => o.queued && !o.failed), isTrue, reason: 'waiting, not failed');
      await pumpEventQueue();
      expect(channel.requests, isEmpty, reason: 'nothing handed to a connection that is not up');

      channel.open();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(channel.sent, <String>['First', 'Second']);
      expect(c.outgoing, isEmpty);
      expect(c.live.map((m) => m.body), containsAllInOrder(<String>['First', 'Second']));

      channel
        ..drop()
        ..open();
      await pumpEventQueue();
      expect(channel.sent, <String>['First', 'Second'], reason: 'a reconnect sends nothing again');
      expect(c.live.where((m) => m.body == 'First').length, 1);
      c.dispose();
    });

    test('the connection drops before its turn: it waits again rather than failing', () async {
      final channel = ManualChannel(autoConnect: true);
      channel.answers['visitor:message'] = echo(<String>[]);
      final c = controllerOn(server, channel);
      await c.start();
      final ack = channel.holdAcks = Completer<void>();
      final a = c.send('A');
      final b = c.send('B');
      await pumpEventQueue();
      expect(channel.sent, <String>['A'], reason: 'one at a time, in order');

      channel.drop();
      channel.holdAcks = null;
      ack.complete();
      expect(await a, isTrue);
      await pumpEventQueue();
      expect(channel.sent, <String>['A'], reason: 'B is not handed to a dropped connection');
      expect(c.outgoing.single.text, 'B');
      expect(c.outgoing.single.queued, isTrue);
      expect(c.outgoing.single.failed, isFalse);

      channel.open();
      expect(await b, isTrue);
      expect(channel.sent, <String>['A', 'B']);
      c.dispose();
    });

    test('a tap on a workflow button while connecting is sent once connected', () async {
      server.openInfo = <String, dynamic>{'conversationId': null};
      server.workflow = <String, dynamic>{
        'workflowId': 'wf-1',
        'letCustomerType': false,
        'messages': <Object?>[
          <String, dynamic>{
            'body': 'What can we help with?',
            'meta': <String, dynamic>{
              'buttons': <Object?>[
                <String, dynamic>{'id': 'b1', 'label': 'Book a course'}
              ],
            },
          },
        ],
      };
      final channel = ManualChannel();
      channel.answers['workflow:start'] = (_) => <String, dynamic>{'ok': true, 'conversationId': 'conv-9'};
      final c = controllerOn(server, channel);
      await c.start();
      final tapped = c.startWorkflow(c.preview!.messages.first.meta!.buttons.first);
      await pumpEventQueue();
      expect(c.flowBusy, isTrue);
      expect(channel.requests, isEmpty);
      channel.open();
      await tapped;
      expect(channel.requests.single.$1, 'workflow:start');
      expect(c.liveId, 'conv-9');
      c.dispose();
    });
  });

  group('never outlives its customer', () {
    test('a reset drops what was waiting to go, the draft and every conversation — none of it is sent as the next customer', () async {
      final channel = ManualChannel();
      final c = controllerOn(server, channel);
      await c.start();
      final waiting = c.send('My card number is 1234');
      c.composerChanged('and the expiry is');
      expect(c.draft, 'and the expiry is');

      c.reset();
      expect(await waiting, isFalse);
      expect(c.outgoing, isEmpty);
      expect(c.live, isEmpty);
      expect(c.conversations, isEmpty);
      expect(c.liveId, isNull);
      expect(c.draft, isEmpty);
      expect(c.session, isNull);
      expect(c.phase, MessengerPhase.loading);

      await c.start();
      channel.open();
      await pumpEventQueue();
      expect(channel.sent, isEmpty);
      c.dispose();
    });

    test('signed out while the list was loading: their unread count never reaches the badge', () async {
      final unread = <int>[];
      final c = controllerOn(server, ManualChannel(autoConnect: true), unread: unread);
      await c.start();
      server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 3)];
      server.hold(<String>['/widget/conversations']);
      final loading = c.refreshConversations();
      await pumpEventQueue();
      final told = List<int>.of(unread);
      c.dispose(); // what logout() does to a messenger that is not on screen
      server.release();
      await loading;
      expect(unread, told);
    });

    test('answers on their way for the customer before land nowhere after a reset', () async {
      final c = controllerOn(server, ManualChannel(autoConnect: true));
      await c.start();
      server.hold(<String>['/widget/conversations', '/widget/conversations/conv-1']);
      final refreshing = c.refresh();
      await pumpEventQueue();
      c.reset();
      server.release();
      await refreshing;
      await pumpEventQueue();
      expect(c.conversations, isEmpty);
      expect(c.live, isEmpty);
      expect(c.liveId, isNull);
      c.dispose();
    });
  });

  group('the app goes and comes back', () {
    test('in the background nothing is marked seen; back, it reconnects and catches up once, without duplicates', () async {
      final channel = ManualChannel(autoConnect: true);
      final c = controllerOn(server, channel);
      await c.start();
      c.setViewingLive(true);
      await pumpEventQueue();
      final seenBefore = count('POST /widget/seen');

      c
        ..lifecycleChanged(AppLifecycleState.inactive)
        ..lifecycleChanged(AppLifecycleState.hidden)
        ..lifecycleChanged(AppLifecycleState.paused);
      channel.server('message:created', msg('m3', 'agent', 'Any luck?'));
      await pumpEventQueue();
      expect(count('POST /widget/seen'), seenBefore, reason: 'not read: the phone is in a pocket');
      expect(c.totalUnread, 1);

      channel.drop(); // the phone closed the socket meanwhile
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 2};
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Where is my certificate?'),
        msg('m2', 'agent', 'It is in the post today.'),
        msg('m3', 'agent', 'Any luck?'),
        msg('m4', 'agent', 'I have sent another.'),
      ]);
      final connects = channel.connects;
      final fetches = count('GET /widget/conversations/conv-1');
      c.lifecycleChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(channel.connects, connects + 1, reason: 'reconnected');
      expect(c.live.map((m) => m.id), <String>['m1', 'm2', 'm3', 'm4'], reason: 'what came meanwhile, once each');
      expect(count('GET /widget/conversations/conv-1'), fetches + 1, reason: 'one catch-up, though both the resume and the connect asked');
      expect(count('POST /widget/seen'), greaterThan(seenBefore), reason: 'on screen again: read');
      expect(c.totalUnread, 0);
      expect(c.dividerIndex, 2, reason: '"New messages" above what came while away');
      c.dispose();
    });

    test('"Active now" never while it is not connected', () async {
      final channel = ManualChannel(autoConnect: true);
      final c = controllerOn(server, channel);
      await c.start();
      channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 2});
      expect(presenceLines(c.agentsOnline, null).header, 'Active now');
      channel.drop();
      expect(c.link, LinkState.reconnecting);
      expect(presenceLines(c.agentsOnline, null).header, isNot('Active now'));
      c.dispose();
    });
  });

  group('a push tapped', () {
    test('a push names its conversation; anything else is not ours', () {
      expect(GLSupportChatScreen.fromPush(<String, dynamic>{'type': 'message', 'conversationId': 'conv-9', 'screen': 'messages'})!.conversationId, 'conv-9');
      expect(GLSupportChatScreen.fromPush(<String, dynamic>{'type': 'message'}), same(GLSupportChatScreen.messages));
      expect(GLSupportChatScreen.fromPush(<String, dynamic>{'type': 'order_shipped'}), isNull);
      expect(webStart(GLSupportChatScreen.conversation('conv-9')), 'messages', reason: 'the web messenger opens on the list');
    });

    testWidgets('Messages from a push, with what it had read before: it checks first, then opens the conversation with the reply', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final c = controllerFor(server, FakeChannel());
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c)));
      await settle(tester);
      await tester.pumpWidget(const SizedBox()); // closed

      // The team replied while it was closed; the customer taps the push.
      server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1, body: 'Here is the tracking number.')];
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 1};
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Where is my certificate?'),
        msg('m2', 'agent', 'It is in the post today.'),
        msg('m3', 'agent', 'Here is the tracking number.'),
      ]);
      server.hold(GatedServer.opening);
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.messages)));
      await tester.pump();
      expect(find.text('It is in the post today.'), findsOneWidget, reason: 'the list it had, at once');
      expect(c.viewingLive, isFalse, reason: 'what it had says nothing is unread: it waits for the check');

      server.release();
      await settle(tester);
      expect(c.viewingLive, isTrue);
      expect(find.text('Here is the tracking number.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('GLSupportChat', () {
    late ManualChannel channel;
    const ayesha = GLSupportChatIdentity(id: 'A', name: 'Ayesha Khan', hash: 'ha');

    setUp(() async {
      GLSupportChat.debugReset();
      channel = ManualChannel(autoConnect: true);
      GLSupportChat.debugOverride(
        client: server.client(),
        store: MemorySessionStore(),
        realtime: ({required String apiUrl, required String Function() token}) => channel,
      );
      await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'product-1');
      await GLSupportChat.logout();
    });

    Future<BuildContext> app(WidgetTester tester) async {
      late BuildContext context;
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        context = c;
        return const Scaffold(body: Text('The app'));
      })));
      return context;
    }

    Future<void> close(WidgetTester tester, BuildContext app) async {
      Navigator.of(app, rootNavigator: true).popUntil((r) => r.isFirst);
      await settle(tester);
    }

    testWidgets('closed and opened again: the same customer sees their messages at once; a sign-out drops them at once', (tester) async {
      final host = await app(tester);
      expect(await GLSupportChat.login(ayesha), isTrue);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      expect(find.text('It is in the post today.'), findsOneWidget);
      final kept = GLSupportChat.debugMessenger!;
      kept.composerChanged('My licence number is');
      await close(tester, host);
      expect(GLSupportChat.debugMessenger, same(kept), reason: 'kept for the next open');

      // Opened again with the server slow to answer: what it had, at once.
      server.hold(GatedServer.opening);
      final answered = server.finished.length;
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Connecting to support…'), findsNothing);
      expect(find.text('It is in the post today.'), findsOneWidget);
      expect(server.finished.length, answered, reason: 'before any request has completed');
      expect(kept.draft, 'My licence number is');
      server.release();
      await settle(tester);
      await close(tester, host);

      // The same customer again (fresh details before present): still theirs.
      await GLSupportChat.login(const GLSupportChatIdentity(id: 'A', name: 'Ayesha K', hash: 'hb'));
      expect(GLSupportChat.debugMessenger, same(kept));

      // Signed out: gone now, not at the next open.
      final out = GLSupportChat.logout();
      expect(GLSupportChat.debugMessenger, isNull);
      await out;
      server.hold(GatedServer.opening);
      unawaited(GLSupportChat.present(host));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('It is in the post today.'), findsNothing, reason: 'nothing of the customer before');
      expect(find.text('Connecting to support…'), findsOneWidget);
      expect(GLSupportChat.debugMessenger!.draft, isEmpty);
      server.release();
      await settle(tester);
      await close(tester, host);
    });

    testWidgets('a login as someone else drops it at once', (tester) async {
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      await close(tester, host);
      expect(GLSupportChat.debugMessenger, isNotNull);
      final bilal = GLSupportChat.login(const GLSupportChatIdentity(id: 'B', name: 'Bilal Ahmed', hash: 'hb'));
      expect(GLSupportChat.debugMessenger, isNull);
      await bilal;
    });

    testWidgets('signed out while it is open: what was on screen goes at once, the conversation too', (tester) async {
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      expect(find.text('Where is my certificate?'), findsOneWidget);

      server.hold(GatedServer.opening);
      final out = GLSupportChat.logout();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Where is my certificate?', skipOffstage: false), findsNothing);
      expect(find.text('Connecting to support…'), findsOneWidget);
      await out;
      server.release();
      await settle(tester);
      await close(tester, host);
    });

    testWidgets('a push tapped while it is open goes to its conversation — no second messenger on top', (tester) async {
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      expect(find.text('Hi Ayesha 👋'), findsOneWidget);

      var closed = false;
      unawaited(GLSupportChat.present(host, screen: GLSupportChatScreen.fromPush(<String, dynamic>{'type': 'message', 'conversationId': 'conv-1'})!)
          .then((_) => closed = true));
      await settle(tester);
      expect(find.byType(GLSupportChatPage, skipOffstage: false), findsOneWidget, reason: 'the one already up');
      expect(GLSupportChat.debugMessenger!.viewingLive, isTrue);
      expect(find.text('Where is my certificate?'), findsOneWidget);
      expect(closed, isFalse);
      await close(tester, host);
      expect(closed, isTrue, reason: "the second present's future is the messenger's: done when it closes");
    });

    testWidgets('the app rebuilt its navigator under the open messenger: the next present opens a new one', (tester) async {
      var host = await app(tester);
      await GLSupportChat.login(ayesha);
      var gone = false;
      unawaited(GLSupportChat.present(host).then((_) => gone = true));
      await settle(tester);
      await tester.pumpWidget(const SizedBox()); // the app's MaterialApp goes, the messenger with it, never closed
      await tester.pump();
      expect(gone, isTrue, reason: "present's future completes even so");

      host = await app(tester);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      expect(find.text('Hi Ayesha 👋'), findsOneWidget);
      expect(find.text('It is in the post today.'), findsOneWidget, reason: 'what it had, still');
      await close(tester, host);
    });

    testWidgets('a push tapped while the customer reads an old conversation: back out of it, into the one with the reply', (tester) async {
      server.conversations = <Map<String, dynamic>>[
        row('conv-1', body: 'It is in the post today.'),
        row('old', open: false, body: 'Your refund has gone through.', at: '2026-09-21T10:00:00.000Z'),
      ];
      server.details['old'] = detail('old', <Map<String, dynamic>>[
        msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old'),
        msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old'),
      ], open: false);
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      await tester.tap(find.text('Messages'));
      await settle(tester);
      await tester.tap(find.text('Your refund has gone through.'));
      await settle(tester);
      expect(find.text('Can I have a refund?'), findsOneWidget);

      unawaited(GLSupportChat.present(host, screen: GLSupportChatScreen.conversation('conv-1')));
      await settle(tester);
      expect(find.text('Can I have a refund?', skipOffstage: false), findsNothing, reason: 'the old one closed');
      expect(find.text('Where is my certificate?'), findsOneWidget);
      expect(GLSupportChat.debugMessenger!.viewingLive, isTrue);
      await close(tester, host);
    });

    testWidgets('a push while login() is still signing in, with what it had read before: it waits for the check, then opens the reply', (tester) async {
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      await close(tester, host);

      server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1, body: 'Here is the tracking number.')];
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 1};
      server.hold(GatedServer.opening);
      // The app refreshes the identity before present, as the README says —
      // without waiting for it: there is no token while it signs in.
      final relogin = GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host, screen: GLSupportChatScreen.messages));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(GLSupportChat.debugMessenger!.viewingLive, isFalse, reason: 'what it had says nothing is unread');
      expect(find.text('Connecting to support…'), findsNothing);
      server.release();
      await settle(tester);
      expect(await relogin, isTrue);
      expect(GLSupportChat.debugMessenger!.viewingLive, isTrue);
      await close(tester, host);
    });

    testWidgets('a push tapped while it is still loading opens the conversation once it has loaded', (tester) async {
      final host = await app(tester);
      server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1, body: 'It is in the post today.')];
      server.hold(<String>['/widget/auth']);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      expect(find.text('Connecting to support…'), findsOneWidget);

      unawaited(GLSupportChat.present(host, screen: GLSupportChatScreen.messages));
      await tester.pump();
      server.release();
      await settle(tester);
      expect(GLSupportChat.debugMessenger!.viewingLive, isTrue);
      expect(find.text('Where is my certificate?'), findsOneWidget);
      await close(tester, host);
    });

    testWidgets("the app's lifecycle reaches the open messenger: nothing read in the background, all of it on return", (tester) async {
      final host = await app(tester);
      await GLSupportChat.login(ayesha);
      unawaited(GLSupportChat.present(host));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
      final seen = count('POST /widget/seen');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      channel.server('message:created', msg('m3', 'agent', 'Any luck?'));
      await tester.pump();
      expect(count('POST /widget/seen'), seen);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(count('POST /widget/seen'), greaterThan(seen));
      expect(GLSupportChat.debugMessenger!.totalUnread, 0);
      await close(tester, host);
      // The badge polling restarted on resume, inside this test's pretend
      // time: away again stops it, and back to the foreground after the test.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    });
  });

  testWidgets('an AI answer typing out redraws about 13 times a second, not 40; a burst of events between frames is one redraw', (tester) async {
    final channel = FakeChannel();
    final c = controllerFor(server, channel);
    await c.start();
    var redraws = 0;
    c.addListener(() => redraws++);

    channel.server('ai:stream_start', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'authorName': 'GL Assistant', 'createdAt': '2026-10-06T10:00:00.000Z'});
    channel.server('ai:stream_chunk', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'delta': 'All of this is the answer. ' * 20});
    await tester.pump();
    redraws = 0;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16)); // a second at 60 frames a second
    }
    expect(redraws, inInclusiveRange(10, 14), reason: 'one redraw per typewriter step, every 75 ms');
    expect(c.live.last.body, isNotEmpty);

    redraws = 0;
    for (var i = 0; i < 10; i++) {
      channel.server('presence:update', <String, dynamic>{'agentsOnline': i % 2});
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent'});
      channel.server('message:created', msg('b$i', 'agent', 'Line $i'));
    }
    await tester.pump();
    expect(redraws, 1, reason: 'thirty events between two frames: one redraw');

    redraws = 0;
    channel.server('presence:update', <String, dynamic>{'agentsOnline': 1});
    channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent'});
    await tester.pump();
    redraws = 0;
    for (var i = 0; i < 5; i++) {
      channel.server('presence:update', <String, dynamic>{'agentsOnline': 1});
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent'});
      await tester.pump();
    }
    expect(redraws, 0, reason: 'the same presence, the agent still typing: nothing new to draw');
    c.dispose();
  });
}
