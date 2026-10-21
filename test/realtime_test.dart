import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/realtime.dart';
import 'package:gl_support_chat/src/core/controller.dart';

import 'support/fakes.dart';
import 'support/socket_server.dart';

// 0.4.11. 0.4.10's composer lock follows the workflow as the server says it —
// GET /widget/messages `flow` and the `flow:update` event — and the package's
// real connection never listened for `flow:update`. Socket.IO drops an event
// nobody listens for, and every test spoke through FakeChannel, which passes
// everything on. In an app the lock heard the workflow only when the
// messenger opened, reconnected or came back: in a new chat no buttons came
// after the first tap, and a workflow that ended with the messenger open
// left the box locked and its buttons gone.
//
// Here the controller talks through the real connection (SocketIoChannel) to
// a pretend Socket.IO server on this machine, which says what the server
// says, in the order it says it (apps/api: workflows/engine.ts, socket.ts,
// routes/internal.ts, automations/run.ts). No widget binding in this file: it
// answers every HTTP request, the WebSocket's handshake included, with a 400.

/// The server's events MessengerController acts on: the `case '…':` labels
/// of its `_onEvent`, read from the source — so an event handled there and
/// not listened for fails here, whoever adds it.
Set<String> eventsTheControllerHandles() {
  final source = File('lib/src/core/controller.dart').readAsStringSync();
  final start = source.indexOf('void _onEvent(RealtimeEvent e) {');
  final end = start < 0 ? -1 : source.indexOf('\n  }\n', start);
  if (end < 0) fail('MessengerController._onEvent not found in lib/src/core/controller.dart: this test reads its cases');
  return RegExp(r"case '([a-z_]+:[a-z_]+)':").allMatches(source.substring(start, end)).map((m) => m[1]!).toSet();
}

Future<void> until(bool Function() ok, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Everything the server said before now has come through [ch]: the answer
/// to a request comes over the same socket, after it.
Future<void> heardAll(RealtimeChannel ch) async {
  final answer = await ch.request('test:roundtrip', <String, dynamic>{}, timeout: const Duration(seconds: 10));
  expect(answer['ok'], isTrue, reason: 'the round trip to the pretend server');
  await Future<void>.delayed(Duration.zero);
}

String at(int minute) => DateTime.utc(2026, 10, 21, 10, minute).toIso8601String();

Map<String, dynamic> choice() => <String, dynamic>{'awaiting': 'choice', 'letCustomerType': false, 'workingUntil': null};
Map<String, dynamic> working() =>
    <String, dynamic>{'awaiting': null, 'letCustomerType': false, 'workingUntil': DateTime.now().add(const Duration(seconds: 20)).toUtc().toIso8601String()};

/// The server's `flow:update` for conv-1.
Map<String, dynamic> update(Map<String, dynamic>? flow) => <String, dynamic>{'conversationId': 'conv-1', 'flow': flow};

/// The workflow's typing dots.
const botTyping = <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'bot'};

/// A workflow question with its buttons, on a path that does not let the customer type.
Map<String, dynamic> buttons(String id, String body, List<String> labels, {int minute = 1}) => msg(id, 'bot', body, at: at(minute), meta: <String, dynamic>{
      'buttons': <Object?>[
        for (final (i, label) in labels.indexed) <String, dynamic>{'id': 'b${i + 1}', 'label': label},
      ],
      'lockComposer': true,
      'workflowId': 'wf-1',
    });

void main() {
  late PretendSocketServer socket;
  late FakeServer server;
  MessengerController? opened;
  SocketIoChannel? channel;

  setUp(() async {
    socket = await PretendSocketServer.start();
    server = FakeServer();
    opened = null;
    channel = null;
  });

  tearDown(() async {
    opened?.dispose();
    await socket.close();
  });

  /// The messenger on [server]'s routes and the package's own connection to
  /// [socket]: opened, connected, and caught up as its connect asks.
  Future<MessengerController> open() async {
    final api = server.api();
    api.reauthenticate = () async => (await api.authenticate()).token;
    final c = opened = MessengerController(
      api: api,
      signIn: () => api.authenticate(visitorId: 'visitor-1'),
      realtimeFactory: ({required String apiUrl, required String Function() token}) => channel = SocketIoChannel(apiUrl: socket.url, token: token),
    );
    await c.start();
    await until(() => c.link == LinkState.connected && !c.refreshing, 'the connection, and the catch-up its connect starts');
    expect(socket.tokens.last, 'tok-1', reason: 'it connects with the visitor token');
    return c;
  }

  test('every server event the controller handles comes through the real connection', () async {
    final handled = eventsTheControllerHandles();
    expect(handled, containsAll(<String>['message:created', 'typing:start', 'flow:update', 'ai:stream_chunk']), reason: "MessengerController._onEvent's cases");
    final ch = SocketIoChannel(apiUrl: socket.url, token: () => 'tok-1');
    addTearDown(ch.dispose);
    final heard = <String>[];
    ch.events.listen((e) => heard.add(e.name));
    ch.connect();
    await until(() => heard.contains('connect'), 'the connection');
    for (final name in handled) {
      socket.emit(name, <String, dynamic>{'conversationId': 'conv-1'});
    }
    await heardAll(ch);
    expect(handled.where((name) => !heard.contains(name)).toList(), isEmpty,
        reason: 'the controller handles these, but the connection does not listen for them, so Socket.IO drops them');
  });

  test('a new chat: after the first tap the next buttons come, the box locked under them', () async {
    server.openInfo = <String, dynamic>{'conversationId': null, 'unreadCount': 0, 'csat': null, 'flow': null};
    server.workflow = <String, dynamic>{
      'workflowId': 'wf-1',
      'letCustomerType': false,
      'messages': <Object?>[
        <String, dynamic>{
          'body': 'What can we help with?',
          'meta': <String, dynamic>{
            'buttons': <Object?>[
              <String, dynamic>{'id': 'b1', 'label': 'Book a course'},
            ],
            'lockComposer': true,
          },
        },
      ],
    };
    final c = await open();
    expect(c.preview, isNotNull, reason: 'the opening menu');
    expect(c.flowKnown, isTrue, reason: 'GET /widget/messages said `flow: null`: no workflow runs yet');
    expect(c.composerLock, 'Choose an option above');

    // engine.ts startFromPreview: the conversation is made and the socket put
    // in its room; locked from the click; what they were shown, then their
    // answer; then the answer to the tap.
    socket.answers['workflow:start'] = (_) {
      socket.emit('flow:update', update(working()));
      socket.emit('message:created', buttons('p0', 'What can we help with?', <String>['Book a course']));
      socket.emit('message:created', msg('v1', 'visitor', 'Book a course', at: at(2), meta: <String, dynamic>{'choice': 'b1', 'answered': 'p0'}));
      return <String, dynamic>{'ok': true, 'conversationId': 'conv-1'};
    };
    await c.startWorkflow(c.preview!.messages.first.meta!.buttons.first);
    await heardAll(channel!);
    expect(socket.received.where((r) => r.$1 == 'workflow:start').single.$2, <String, dynamic>{'workflowId': 'wf-1', 'buttonId': 'b1'});
    expect(c.liveId, 'conv-1');
    expect(c.live.map((m) => m.id), <String>['p0', 'v1']);
    expect(c.composerLock, 'One moment…', reason: 'between the tap and the next question: locked');

    // …then the path it opens, in the background: the dots, the next
    // question with its buttons, and the flow waiting on them.
    socket.emit('typing:start', botTyping);
    socket.emit('message:created', buttons('p1', 'Which course is it about?', <String>['Door Supervisor', 'CCTV'], minute: 3));
    socket.emit('typing:stop', botTyping);
    socket.emit('flow:update', update(choice()));
    await heardAll(channel!);
    expect(c.livePrompt?.id, 'p1', reason: 'the next buttons show');
    expect(c.composerLock, 'Choose an option above', reason: 'and the box is locked under them');
  });

  group('the workflow ends with the messenger open: the box opens and the buttons go —', () {
    /// conv-1 open, its workflow waiting on Which course?'s buttons.
    void serve() {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0, 'flow': choice()};
      server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Which course is it about?', authorType: 'bot')];
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m0', 'visitor', 'Hi', at: at(0)),
        buttons('p1', 'Which course is it about?', <String>['Door Supervisor', 'CCTV']),
      ]);
    }

    // Each as the server says it, in its order.
    final endings = <String, Future<void> Function(MessengerController c)>{
      // routes/internal.ts /emit/message: the reply, then tellIfFlowOver.
      'a teammate replies': (c) async {
        socket.emit('message:created', msg('a1', 'agent', 'Levi here, I can help with that.', at: at(5)));
        socket.emit('flow:update', update(null));
      },
      // automations/run.ts say(): the workflow ends before the rule speaks.
      'an automation nudges the quiet chat': (c) async {
        socket.emit('flow:update', update(null));
        socket.emit('message:created', msg('n1', 'bot', 'Are you still there?', at: at(11), authorName: 'Idle nudge', meta: <String, dynamic>{'workflowId': 'rule-1'}));
      },
      // The inbox's close (tellIfFlowOver) or an automation's (endWorkflowIn):
      // the word alone, nothing in the thread.
      'the chat is closed': (c) async {
        socket.emit('flow:update', update(null));
      },
      // engine.ts choose(): working from the tap, their answer, the ack; then
      // the path's last words and endFlow.
      'the path ends after a tap': (c) async {
        socket.answers['workflow:choose'] = (_) {
          socket.emit('flow:update', update(working()));
          socket.emit('message:created', msg('v1', 'visitor', 'CCTV', at: at(2), meta: <String, dynamic>{'choice': 'b2', 'answered': 'p1'}));
          return <String, dynamic>{'ok': true, 'conversationId': 'conv-1'};
        };
        await c.choose(c.livePrompt!, c.livePrompt!.meta!.buttons[1]);
        socket.emit('typing:start', botTyping);
        socket.emit('message:created', msg('e1', 'bot', 'Thanks, a teammate will be with you shortly.', at: at(3), meta: <String, dynamic>{'workflowId': 'wf-1'}));
        socket.emit('typing:stop', botTyping);
        socket.emit('flow:update', update(null));
      },
    };

    for (final MapEntry(key: what, value: end) in endings.entries) {
      test(what, () async {
        serve();
        final c = await open();
        expect(c.composerLock, 'Choose an option above');
        expect(c.livePrompt?.id, 'p1');

        await end(c);
        await heardAll(channel!);
        expect(c.composerLock, isNull, reason: 'the box opens');
        expect(c.livePrompt, isNull, reason: 'the buttons go');
        expect(c.flowKnown, isTrue);
        expect(c.flow, isNull);
      });
    }

    test('and an automation\'s nudge is in the thread', () async {
      serve();
      final c = await open();
      await endings['an automation nudges the quiet chat']!(c);
      await heardAll(channel!);
      expect(c.live.last.body, 'Are you still there?');
      expect(c.composerLock, isNull);
    });
  });
}
