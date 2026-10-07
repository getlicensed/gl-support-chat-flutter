import 'dart:async';
import 'dart:convert';

import 'package:gl_support_chat/src/api/client.dart';
import 'package:gl_support_chat/src/api/realtime.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A pretend server: the messenger's REST routes, answered from fields a test
/// sets, with every request recorded.
class FakeServer {
  final requests = <http.Request>[];

  Map<String, dynamic> session = <String, dynamic>{
    'token': 'tok-1',
    'visitorId': 'visitor-1',
    'productName': 'GuardPass',
    'orgName': 'Get Licensed',
    'brandColor': '#1F6FEB',
    'identified': <String, dynamic>{'name': 'Ayesha Khan', 'type': 'learner'},
    'officeHours': <String, dynamic>{'open': true, 'opensLabel': null, 'awayMessage': 'We are away right now.'},
    'team': <Object?>[
      <String, dynamic>{'name': 'Levi John', 'initials': 'LJ', 'avatarUrl': null},
    ],
    'helpBaseUrl': 'https://help.test',
    'whatsappNumber': '447700900123',
    'suggestedQuestions': <Object?>[
      <String, dynamic>{'text': 'How do I renew my licence?', 'articleSlug': null, 'action': 'message'},
    ],
  };
  Map<String, dynamic> openInfo = <String, dynamic>{'conversationId': null, 'unreadCount': 0, 'csat': null};
  List<Map<String, dynamic>> conversations = <Map<String, dynamic>>[];
  final Map<String, Map<String, dynamic>> details = <String, Map<String, dynamic>>{};
  Map<String, dynamic>? workflow;
  List<Map<String, dynamic>> articles = <Map<String, dynamic>>[];
  Map<String, dynamic>? article;
  int authStatus = 200;
  int uploads = 0;

  Iterable<String> get paths => requests.map((r) => '${r.method} ${r.url.path}');

  http.Client client() => MockClient((req) async {
        requests.add(req);
        final path = req.url.path;
        http.Response json(Object body, [int status = 200]) =>
            http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});
        if (path == '/widget/auth') {
          return authStatus == 200 ? json(session) : json(<String, dynamic>{'error': 'nope'}, authStatus);
        }
        if (path == '/widget/messages') return json(openInfo);
        if (path == '/widget/conversations') return json(<String, dynamic>{'conversations': conversations});
        if (path.startsWith('/widget/conversations/')) {
          final d = details[path.split('/').last];
          return d == null ? json(<String, dynamic>{'error': 'not_found'}, 404) : json(d);
        }
        if (path == '/widget/workflow') return json(<String, dynamic>{'workflow': workflow});
        if (path == '/widget/seen') return json(<String, dynamic>{'ok': true});
        if (path == '/widget/email') return json(<String, dynamic>{'ok': true});
        if (path == '/widget/unread') return json(<String, dynamic>{'unreadCount': 0});
        if (path == '/widget/uploads') {
          uploads++;
          return json(<String, dynamic>{
            'id': '11111111-2222-3333-4444-55555555555$uploads',
            'name': req.headers['x-file-name'] ?? 'f',
            'contentType': req.headers['content-type'],
            'bytes': req.bodyBytes.length,
            'url': 'upload://x',
          }, 201);
        }
        if (path == '/api/help/articles') return json(<String, dynamic>{'articles': articles, 'helpUrl': 'https://help.test/help'});
        if (path.startsWith('/api/help/articles/')) {
          final a = article;
          return a == null ? json(<String, dynamic>{'error': 'not found'}, 404) : json(a);
        }
        return json(<String, dynamic>{'error': 'no route $path'}, 404);
      });

  MessengerApi api() => MessengerApi(apiUrl: 'https://api.test', productId: 'product-1', client: client(), retryDelays: const <Duration>[]);
}

/// A pretend Socket.IO connection: what the client sent, and a way for the
/// test to say things as the server.
class FakeChannel implements RealtimeChannel {
  final _events = StreamController<RealtimeEvent>.broadcast(sync: true);
  final requests = <(String, Map<String, dynamic>)>[];
  final emitted = <(String, Map<String, dynamic>)>[];
  int connects = 0;
  bool _connected = false;

  /// How the server answers each acknowledged event; `{ok: true}` by default.
  final answers = <String, Map<String, dynamic> Function(Map<String, dynamic> data)>{};

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  bool get connected => _connected;

  @override
  void connect() {
    connects++;
    _connected = true;
    _events.add(const RealtimeEvent('connect'));
  }

  void drop([String reason = 'transport close']) {
    _connected = false;
    _events.add(RealtimeEvent('disconnect', reason));
  }

  void server(String name, Object? data) => _events.add(RealtimeEvent(name, data));

  @override
  void emit(String event, Map<String, dynamic> data) => emitted.add((event, data));

  @override
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 20)}) async {
    requests.add((event, data));
    return answers[event]?.call(data) ?? <String, dynamic>{'ok': true};
  }

  @override
  void dispose() {}
}

/// A controller wired to [server] and [channel].
MessengerController controllerFor(FakeServer server, FakeChannel channel, {List<int>? unread}) {
  final api = server.api();
  api.reauthenticate = () async => (await api.authenticate()).token;
  return MessengerController(
    api: api,
    signIn: () => api.authenticate(visitorId: 'visitor-1'),
    realtimeFactory: ({required String apiUrl, required String Function() token}) => channel,
    onUnreadChanged: unread?.add,
  );
}

Map<String, dynamic> msg(String id, String authorType, String body, {String conversationId = 'conv-1', Map<String, dynamic>? meta, String? authorName, String? at, List<Object?>? attachments}) =>
    <String, dynamic>{
      'id': id,
      'conversationId': conversationId,
      'body': body,
      'authorType': authorType,
      'authorId': authorType == 'agent' ? '9b1c3a5e-0000-4000-8000-000000000001' : null,
      'authorName': authorName ?? (authorType == 'agent' ? 'Levi John' : null),
      'createdAt': at ?? '2026-10-06T10:00:00.000Z',
      if (meta != null) 'meta': meta,
      if (attachments != null) 'attachments': attachments,
    };

Map<String, dynamic> detail(String id, List<Map<String, dynamic>> messages, {bool open = true, Map<String, dynamic>? csat, String? agentLastSeenAt}) =>
    <String, dynamic>{
      'conversation': <String, dynamic>{
        'id': id,
        'status': open ? 'open' : 'closed',
        'agentLastSeenAt': agentLastSeenAt,
        'csat': csat,
      },
      'messages': messages,
    };

Map<String, dynamic> row(String id, {bool open = true, int unread = 0, String body = 'Hello', String authorType = 'agent', String at = '2026-10-06T10:00:00.000Z'}) =>
    <String, dynamic>{
      'id': id,
      'status': open ? 'open' : 'closed',
      'lastMessageAt': at,
      'unreadCount': unread,
      'agent': <String, dynamic>{'id': '9b1c3a5e-0000-4000-8000-000000000001', 'name': 'Levi John', 'avatarUrl': null},
      'lastMessage': <String, dynamic>{'body': body, 'authorType': authorType, 'authorName': 'Levi John', 'createdAt': at},
    };
