import 'dart:async';
import 'dart:convert';

import 'package:gl_support_chat/src/api/realtime.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

/// The pretend server, with a hand on the tap: a test can hold the answers
/// to some routes until it lets them go, or make one fail — to see what the
/// messenger shows before anything has come back, and that the loads go out
/// side by side.
class GatedServer extends FakeServer {
  final _gates = <String, Completer<void>>{};

  /// Routes answered with this status instead (a load that fails).
  final failing = <String, int>{};

  /// `METHOD /path` of each request as it reached the server, and as it was answered.
  final started = <String>[];
  final finished = <String>[];

  void hold(Iterable<String> paths) {
    for (final p in paths) {
      _gates[p] ??= Completer<void>();
    }
  }

  void release([Iterable<String>? paths]) {
    for (final p in (paths ?? _gates.keys).toList()) {
      final gate = _gates.remove(p);
      if (gate != null && !gate.isCompleted) gate.complete();
    }
  }

  /// Every route the messenger calls when it opens.
  static const opening = <String>['/widget/auth', '/widget/messages', '/widget/conversations', '/widget/conversations/conv-1', '/widget/workflow'];

  @override
  http.Client client() {
    final inner = super.client();
    return MockClient((req) async {
      final what = '${req.method} ${req.url.path}';
      started.add(what);
      final gate = _gates[req.url.path];
      if (gate != null) await gate.future;
      final status = failing[req.url.path];
      if (status != null) {
        requests.add(req);
        finished.add(what);
        return http.Response(jsonEncode(<String, dynamic>{'error': 'failed'}), status, headers: <String, String>{'content-type': 'application/json'});
      }
      // MockClient hands over a finalised request: send the pretend server a copy.
      final copy = http.Request(req.method, req.url)
        ..headers.addAll(req.headers)
        ..bodyBytes = req.bodyBytes;
      final res = await http.Response.fromStream(await inner.send(copy));
      finished.add(what);
      return res;
    });
  }
}

/// A pretend Socket.IO connection that connects only when the test says
/// ([open]) — the phone on a slow network — and can hold the server's
/// acknowledgements back.
class ManualChannel implements RealtimeChannel {
  ManualChannel({this.autoConnect = false});

  /// Connect as soon as asked, like [FakeChannel].
  bool autoConnect;
  final _events = StreamController<RealtimeEvent>.broadcast(sync: true);
  final requests = <(String, Map<String, dynamic>)>[];
  final emitted = <(String, Map<String, dynamic>)>[];
  int connects = 0;
  bool _connected = false;

  /// While set, acknowledgements wait for it.
  Completer<void>? holdAcks;

  /// How the server answers each acknowledged event; `{ok: true}` by default.
  final answers = <String, Map<String, dynamic> Function(Map<String, dynamic> data)>{};

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  bool get connected => _connected;

  @override
  void connect() {
    connects++;
    if (autoConnect) open();
  }

  /// The connection comes up.
  void open() {
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
    final hold = holdAcks;
    if (hold != null) await hold.future;
    return answers[event]?.call(data) ?? <String, dynamic>{'ok': true};
  }

  /// Bodies of the messages sent, in order.
  List<String> get sent => requests.where((r) => r.$1 == 'visitor:message').map((r) => r.$2['body'] as String).toList();

  @override
  void dispose() {}
}

/// A controller on [server] and any pretend connection.
MessengerController controllerOn(FakeServer server, RealtimeChannel channel, {List<int>? unread}) {
  final api = server.api();
  api.reauthenticate = () async => (await api.authenticate()).token;
  return MessengerController(
    api: api,
    signIn: () => api.authenticate(visitorId: 'visitor-1'),
    realtimeFactory: ({required String apiUrl, required String Function() token}) => channel,
    onUnreadChanged: unread?.add,
  );
}

/// The server answers a message with itself, in conversation conv-1.
Map<String, dynamic> Function(Map<String, dynamic>) echo(List<String> ids) => (data) {
      final id = 'sent-${ids.length + 1}';
      ids.add(id);
      return <String, dynamic>{'ok': true, 'message': msg(id, 'visitor', data['body'] as String)};
    };
