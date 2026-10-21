import 'dart:convert';
import 'dart:io';

/// A pretend Socket.IO 4 server on this machine, for the package's own
/// connection (`SocketIoChannel`) to talk to over a real WebSocket: the
/// Engine.IO handshake, the Socket.IO connect with the visitor's token,
/// events both ways and acknowledgements — the wire as the GL Support Chat
/// server speaks it.
///
/// `FakeChannel` (fakes.dart) stands in for the connection itself, so it
/// cannot see what the connection drops: Socket.IO passes on only the events
/// it was told to listen for (0.4.10's `flow:update` never reached the
/// controller in an app). Through this server the real one is tested.
///
/// A test that uses it must not start the widget binding: the binding answers
/// every HTTP request, the WebSocket's handshake included, with a 400.
class PretendSocketServer {
  PretendSocketServer._(this._http);

  static Future<PretendSocketServer> start() async {
    final server = PretendSocketServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    server._http.listen(server._onRequest);
    return server;
  }

  final HttpServer _http;
  final _sockets = <WebSocket>[];

  /// The address to give the connection.
  String get url => 'http://127.0.0.1:${_http.port}';

  /// The token each connection signed in with, in turn.
  final tokens = <String?>[];

  /// What the client sent, in order: `(event, data)`.
  final received = <(String, Object?)>[];

  /// How each event sent for an answer is answered; `{ok: true}` by default.
  /// What a handler says with [emit] goes out before its answer, as the
  /// server's own handlers do.
  final answers = <String, Map<String, dynamic> Function(Map<String, dynamic> data)>{};

  /// Say [event] to every connected visitor, as `io.to(room).emit` does.
  void emit(String event, Object? data) {
    final frame = '42${jsonEncode(<Object?>[event, data])}';
    for (final ws in _sockets) {
      ws.add(frame);
    }
  }

  Future<void> close() async {
    for (final ws in List<WebSocket>.of(_sockets)) {
      await ws.close();
    }
    await _http.close(force: true);
  }

  Future<void> _onRequest(HttpRequest req) async {
    if (req.uri.path != '/socket.io/' || req.uri.queryParameters['transport'] != 'websocket' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = HttpStatus.badRequest;
      await req.response.close();
      return;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    // Engine.IO's open: nothing to upgrade to, and pings too far apart to
    // come up in a test.
    ws.add('0${jsonEncode(<String, Object?>{'sid': 'e${tokens.length}', 'upgrades': <String>[], 'pingInterval': 60000, 'pingTimeout': 60000, 'maxPayload': 1000000})}');
    ws.listen((frame) => _onFrame(ws, frame), onDone: () => _sockets.remove(ws), onError: (Object _) => _sockets.remove(ws));
  }

  /// Engine.IO's `4` (a message) carries a Socket.IO packet: `0` the connect
  /// with its auth, `1` a disconnect, `2` an event — `2<id>[…]` when it waits
  /// for an answer, which goes back as `3<id>[…]`. Pings and pongs are left.
  void _onFrame(WebSocket ws, Object? frame) {
    if (frame is! String || frame.length < 2 || frame[0] != '4') return;
    final packet = frame.substring(1);
    switch (packet[0]) {
      case '0':
        final auth = packet.length > 1 ? jsonDecode(packet.substring(1)) : null;
        tokens.add(auth is Map ? auth['token'] as String? : null);
        _sockets.add(ws);
        ws.add('40${jsonEncode(<String, String>{'sid': 's${tokens.length}'})}');
      case '1':
        _sockets.remove(ws);
      case '2':
        final m = RegExp(r'^2(\d*)(\[[\s\S]*\])$').firstMatch(packet);
        if (m == null) return;
        final args = jsonDecode(m[2]!) as List<dynamic>;
        final event = '${args.first}';
        final data = args.length > 1 ? args[1] : null;
        received.add((event, data));
        if (m[1]!.isEmpty) return;
        final answer = answers[event]?.call(data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{}) ?? <String, dynamic>{'ok': true};
        ws.add('43${m[1]}${jsonEncode(<Object?>[answer])}');
    }
  }
}
