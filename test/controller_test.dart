import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';
import 'package:gl_support_chat/src/core/controller.dart';

import 'support/fakes.dart';

// The messenger's behaviour against a pretend server and socket: what it
// loads, what it sends, how it counts unread, and the three fixes over the
// website messenger — a refused message says why, a reconnect fetches what
// was missed, an expired token is renewed.
void main() {
  late FakeServer server;
  late FakeChannel channel;

  setUp(() {
    server = FakeServer();
    channel = FakeChannel();
  });

  group('start', () {
    test('signs in, lists conversations, loads the open one and goes live', () async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 1};
      server.conversations = <Map<String, dynamic>>[row('conv-1', unread: 1), row('old', open: false)];
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Where is my certificate?'),
        msg('s1', 'system', 'Visitor left their email'),
        msg('m2', 'agent', 'It is in the post.'),
      ]);
      final unread = <int>[];
      final c = controllerFor(server, channel, unread: unread);
      await c.start();
      expect(c.phase, MessengerPhase.ready);
      expect(c.session!.productLabel, 'GuardPass');
      expect(c.liveId, 'conv-1');
      expect(c.live.map((m) => m.id), <String>['m1', 'm2'], reason: 'system rows are never drawn, so never kept');
      expect(c.dividerIndex, 1, reason: '"New messages" before the one unread reply');
      expect(c.conversations.length, 2);
      expect(unread.last, 1);
      expect(channel.connects, 1);
      expect(c.link, LinkState.connected);
      expect(server.paths, isNot(contains('GET /widget/workflow')), reason: 'no opening menu while a conversation is open');
    });

    test('no open conversation: the opening menu', () async {
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
              'lockComposer': true,
            },
          },
        ],
      };
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.preview, isNotNull);
      expect(c.composerLock, 'Choose an option above');
      channel.answers['workflow:start'] = (_) => <String, dynamic>{'ok': true, 'conversationId': 'new-conv'};
      await c.startWorkflow(c.preview!.messages.first.meta!.buttons.first);
      expect(channel.requests.last.$1, 'workflow:start');
      expect(channel.requests.last.$2, <String, dynamic>{'workflowId': 'wf-1', 'buttonId': 'b1'});
      expect(c.liveId, 'new-conv');
      expect(c.preview, isNull);
    });

    test('a failed sign-in leaves the fallback screen, and start() again retries', () async {
      server.authStatus = 503;
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.phase, MessengerPhase.failed);
      expect(channel.connects, 0);
      server.authStatus = 200;
      await c.start();
      expect(c.phase, MessengerPhase.ready);
    });
  });

  group('live messages', () {
    Future<MessengerController> started() async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
      server.conversations = <Map<String, dynamic>>[row('conv-1')];
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[msg('m1', 'visitor', 'Hi')]);
      final c = controllerFor(server, channel);
      await c.start();
      return c;
    }

    test('a reply while the conversation is not on screen counts as unread', () async {
      final c = await started();
      channel.server('message:created', msg('m2', 'agent', 'Hello Ayesha'));
      expect(c.live.last.body, 'Hello Ayesha');
      expect(c.totalUnread, 1);
      expect(c.dividerIndex, 1);
      expect(c.conversations.first.lastBody, 'Hello Ayesha');
      channel.server('message:created', msg('m2', 'agent', 'Hello Ayesha'));
      expect(c.live.length, 2, reason: 'the same message twice is kept once');
    });

    test('on screen, it is read at once', () async {
      final c = await started();
      c.setViewingLive(true);
      await Future<void>.delayed(Duration.zero);
      final seenBefore = server.paths.where((p) => p == 'POST /widget/seen').length;
      channel.server('message:created', msg('m2', 'agent', 'Hello'));
      await Future<void>.delayed(Duration.zero);
      expect(c.totalUnread, 0);
      expect(server.paths.where((p) => p == 'POST /widget/seen').length, seenBefore + 1);
      expect(server.requests.last.body, contains('conv-1'), reason: 'seen names the conversation');
    });

    test('typing dots come and go; the customer’s own typing is ignored', () async {
      final c = await started();
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent'});
      expect(c.agentTyping, isTrue);
      channel.server('message:created', msg('m2', 'agent', 'Done'));
      expect(c.agentTyping, isFalse, reason: 'a reply ends the dots');
      channel.server('typing:start', <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'visitor'});
      expect(c.agentTyping, isFalse);
    });

    test('ticks: seen once the team has read it', () async {
      final c = await started();
      channel.server('conversation:seen', <String, dynamic>{'conversationId': 'conv-1', 'seenBy': 'agent', 'seenAt': '2026-10-06T11:00:00.000Z'});
      expect(c.agentSeenAt, DateTime.parse('2026-10-06T11:00:00.000Z').toLocal());
    });

    test('a reconnect fetches what was missed', () async {
      final c = await started();
      channel.drop();
      expect(c.link, LinkState.reconnecting);
      expect(c.agentsOnline, isNull, reason: 'not known while disconnected');
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', 'Hi'),
        msg('m2', 'agent', 'Sent while you were away', at: '2026-10-06T10:05:00.000Z'),
      ]);
      channel.connect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.live.map((m) => m.id), <String>['m1', 'm2']);
      expect(c.link, LinkState.connected);
    });

    test('an expired token is renewed and the connection tried again', () async {
      final c = await started();
      final authsBefore = server.paths.where((p) => p == 'POST /widget/auth').length;
      final connectsBefore = channel.connects;
      channel.server('connect_error', <String, dynamic>{'message': 'invalid_token'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(server.paths.where((p) => p == 'POST /widget/auth').length, authsBefore + 1);
      expect(channel.connects, connectsBefore + 1);
      expect(c.link, LinkState.connected);
    });
  });

  group('sending', () {
    Future<MessengerController> started() async {
      final c = controllerFor(server, channel);
      await c.start();
      return c;
    }

    test('the bubble shows at once and becomes the real message', () async {
      final c = await started();
      channel.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m9', 'visitor', data['body'] as String, conversationId: 'conv-9')};
      final sending = c.send('  Hello  ');
      expect(c.outgoing.single.text, 'Hello', reason: 'trimmed, and on screen before the server answers');
      expect(await sending, isTrue);
      expect(c.outgoing, isEmpty);
      expect(c.live.single.id, 'm9');
      expect(c.liveId, 'conv-9', reason: 'the first message starts the conversation');
      expect(c.conversations.first.id, 'conv-9', reason: 'and it joins the Messages list');
    });

    test('a refused message says why and can be sent again', () async {
      final c = await started();
      channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': "You're sending messages very quickly — wait 12s and try again."};
      expect(await c.send('Hello'), isFalse);
      final out = c.outgoing.single;
      expect(out.error, "You're sending messages very quickly — wait 12s and try again.", reason: 'the server’s sentence, shown as it is');
      channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': 'server_error'};
      await c.retry(out);
      expect(out.error, 'Something went wrong — please try again.', reason: 'codes become words');
      channel.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('m1', 'visitor', 'Hello')};
      expect(await c.retry(out), isTrue);
      expect(c.outgoing, isEmpty);
    });

    test('a photo is uploaded once, even when the message has to be retried', () async {
      final c = await started();
      channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': 'server_error'};
      await c.send('', image: Uint8List.fromList(<int>[1, 2, 3]), imageName: 'licence.jpg', imageType: 'image/jpeg');
      expect(server.uploads, 1);
      final sent = channel.requests.last.$2;
      expect(sent['body'], '');
      expect((sent['attachments'] as List).single, startsWith('11111111'));
      channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': true, 'message': msg('m1', 'visitor', '[Photo]')};
      await c.retry(c.outgoing.single);
      expect(server.uploads, 1, reason: 'the stored photo is reused');
      final upload = server.requests.firstWhere((r) => r.url.path == '/widget/uploads');
      expect(upload.headers['x-file-name'], 'licence.jpg');
      expect(upload.headers['authorization'], 'Bearer tok-1');
    });

    test('typing is told to the team once, and stops', () async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[]);
      final c = await started();
      c.composerChanged('H');
      c.composerChanged('He');
      expect(channel.emitted.where((e) => e.$1 == 'typing:start').length, 1);
      c.composerChanged('');
      expect(channel.emitted.last.$1, 'typing:stop');
    });
  });

  group('workflow prompts', () {
    test('buttons lock the composer; a stale prompt settles silently', () async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('p1', 'bot', 'Which course?', meta: <String, dynamic>{
          'buttons': <Object?>[
            <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'}
          ],
          'lockComposer': true,
        }),
      ]);
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.livePrompt?.id, 'p1');
      expect(c.composerLock, 'Choose an option above');
      channel.answers['workflow:choose'] = (_) => <String, dynamic>{'ok': false, 'error': 'stale'};
      await c.choose(c.livePrompt!, const FlowButton('b1', 'Door Supervisor'));
      expect(c.livePrompt, isNull);
      expect(c.composerLock, isNull);
      expect(c.flowNotice, isNull);
    });

    test('a detail request: the server’s reason under the box', () async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
      server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('p1', 'bot', 'Your email?', meta: <String, dynamic>{
          'collect': <String, dynamic>{'field': 'email', 'label': 'Email', 'inputType': 'email'},
          'lockComposer': true,
        }),
      ]);
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.composerLock, 'Answer the question above');
      channel.answers['workflow:collect'] = (_) => <String, dynamic>{'ok': false, 'error': "That doesn't look like an email address"};
      expect(await c.collect(c.livePrompt!, 'nope'), isFalse);
      expect(c.collectError, "That doesn't look like an email address");
    });
  });

  group('CSAT', () {
    test('a face, then a comment; a failed first rating is taken back with a reason', () async {
      final c = controllerFor(server, channel);
      await c.start();
      channel.answers['csat:rate'] = (_) => <String, dynamic>{'ok': false, 'error': 'server_error'};
      await c.rate('r1', 5);
      expect(c.csat['r1']!.rating, isNull);
      expect(c.csat['r1']!.error, 'That did not save — please try again.');
      channel.answers['csat:rate'] = (_) => <String, dynamic>{'ok': true};
      await c.rate('r1', 5);
      expect(c.csat['r1']!.rating, 5);
      await c.comment('r1', ' Very helpful ');
      expect(channel.requests.last.$2, <String, dynamic>{'ratingId': 'r1', 'rating': 5, 'comment': 'Very helpful'});
      expect(c.csat['r1']!.commentState, 'sent');
    });

    test('an answered question from history shows as answered', () async {
      server.conversations = <Map<String, dynamic>>[row('old', open: false)];
      server.details['old'] = detail('old', <Map<String, dynamic>>[], open: false, csat: <String, dynamic>{'ratingId': 'r9', 'rating': 4, 'comment': null});
      final c = controllerFor(server, channel);
      await c.start();
      await c.loadConversation('old');
      expect(c.csat['r9']!.rating, 4);
    });
  });

  group('leave an email while away', () {
    test('shown only when nobody is online and there is no address', () async {
      server.session = <String, dynamic>{...server.session, 'email': null};
      final c = controllerFor(server, channel);
      await c.start();
      expect(c.showEmailBar, isFalse, reason: 'not known yet');
      channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 0});
      expect(c.showEmailBar, isTrue);
      expect(await c.leaveEmail('not-an-email'), 'Enter a valid email address.');
      expect(await c.leaveEmail('ayesha@example.com'), isNull);
      expect(c.emailSavedFor, 'ayesha@example.com');
      expect(c.visitorEmail, 'ayesha@example.com');
    });
  });

  testWidgets('an AI answer types out, without the hand-over marker, and takes its real id', (tester) async {
    final c = controllerFor(server, channel);
    await c.start(); // in the test's clock, so the typewriter's timer is too
    channel.server('ai:stream_start', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'authorName': 'GL Assistant', 'createdAt': '2026-10-06T10:00:00.000Z'});
    expect(c.live.single.body, '');
    channel.server('ai:stream_chunk', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'delta': 'Hello there. [[NEEDS_HUMAN]]'});
    channel.server('ai:stream_end', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'messageId': 'real-1'});
    await tester.pump(const Duration(milliseconds: 25 * 40));
    expect(c.live.single.body, 'Hello there');
    expect(c.live.single.id, 'real-1');
    expect(c.live.single.authorName, 'GL Assistant');
    c.dispose();
  });
}
