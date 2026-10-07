import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

/// Something the server said, or the connection changing.
///
/// `name` is the Socket.IO event (`message:created`, `typing:start`, …) or one
/// of `connect`, `disconnect`, `connect_error`. `data` is its payload as sent.
class RealtimeEvent {
  const RealtimeEvent(this.name, [this.data]);
  final String name;
  final Object? data;
}

/// The live connection the messenger talks over. An interface so the
/// controller can be tested without a server.
abstract class RealtimeChannel {
  Stream<RealtimeEvent> get events;
  bool get connected;
  void connect();

  /// Fire and forget (typing).
  void emit(String event, Map<String, dynamic> data);

  /// An event the server acknowledges: `{ok, error?, …}`. A missing answer
  /// within [timeout] is `{ok: false, error: 'timeout'}`, never an exception.
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout});

  void dispose();
}

typedef RealtimeFactory = RealtimeChannel Function({required String apiUrl, required String Function() token});

/// Socket.IO 4, as the web messenger connects: WebSocket first, long-polling
/// when a proxy refuses the upgrade, reconnecting forever (1 s doubling to
/// 5 s). The token is asked for on every (re)connect, so a token refreshed
/// after 24 hours is the one the next connection uses.
class SocketIoChannel implements RealtimeChannel {
  SocketIoChannel({required String apiUrl, required String Function() token}) {
    _socket = io.io(
      apiUrl,
      io.OptionBuilder()
          .setTransports(<String>['websocket', 'polling'])
          .setAuthFn((callback) => callback(<String, dynamic>{'token': token()}))
          .enableReconnection()
          .setReconnectionDelay(1000)
          .setReconnectionDelayMax(5000)
          .setTimeout(20000)
          .enableForceNew()
          .disableAutoConnect()
          .build(),
    );
    _socket.onConnect((_) => _add(const RealtimeEvent('connect')));
    _socket.onDisconnect((reason) => _add(RealtimeEvent('disconnect', reason)));
    _socket.onConnectError((err) => _add(RealtimeEvent('connect_error', err)));
    for (final name in _serverEvents) {
      _socket.on(name, (data) => _add(RealtimeEvent(name, data)));
    }
  }

  static const _serverEvents = <String>[
    'message:created',
    'presence:update',
    'conversation:seen',
    'typing:start',
    'typing:stop',
    'ai:stream_start',
    'ai:stream_chunk',
    'ai:stream_end',
    'ai:stream_aborted',
  ];

  late final io.Socket _socket;
  final _events = StreamController<RealtimeEvent>.broadcast();

  void _add(RealtimeEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Stream<RealtimeEvent> get events => _events.stream;

  @override
  bool get connected => _socket.connected;

  @override
  void connect() => _socket.connect();

  @override
  void emit(String event, Map<String, dynamic> data) => _socket.emit(event, data);

  @override
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 20)}) {
    final done = Completer<Map<String, dynamic>>();
    _socket.emitWithAck(event, data, ack: (dynamic answer) {
      if (done.isCompleted) return;
      done.complete(answer is Map ? Map<String, dynamic>.from(answer) : <String, dynamic>{'ok': false, 'error': 'server_error'});
    });
    return done.future.timeout(timeout, onTimeout: () => <String, dynamic>{'ok': false, 'error': 'timeout'});
  }

  @override
  void dispose() {
    _socket.dispose();
    _events.close();
  }
}

/// The default [RealtimeFactory].
RealtimeChannel socketIoChannel({required String apiUrl, required String Function() token}) =>
    SocketIoChannel(apiUrl: apiUrl, token: token);
