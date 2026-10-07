import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/realtime.dart';
import 'format.dart';

typedef MessengerDiagnostics = void Function(String event, Map<String, Object?> detail);

enum MessengerPhase { loading, ready, failed }

/// The live connection, as the screens show it.
enum LinkState { connecting, connected, reconnecting }

/// A message on its way: drawn at once, replaced by the real one when the
/// server confirms it, or marked failed with a way to try again.
class OutgoingMessage {
  OutgoingMessage({required this.localId, required this.text, required this.createdAt, this.image, this.imageName, this.imageType});

  final String localId;
  final String text;
  final DateTime createdAt;
  final Uint8List? image;
  final String? imageName;
  final String? imageType;

  /// Set once the photo is stored, so a retry does not upload it twice.
  String? uploadId;
  String? error;
  bool get failed => error != null;
}

/// The customer's answer to a CSAT question (the five faces, then a comment).
class CsatAnswer {
  CsatAnswer({this.rating, this.commentState = 'open', this.comment = '', this.error});

  int? rating;

  /// `open` · `sending` · `sent`
  String commentState;
  String comment;
  String? error;
}

/// Everything the messenger screens show and do, in one place.
///
/// It follows the website messenger rule for rule,
/// with the fixes that spec called for: a refused message says why, a
/// reconnect fetches what was missed, and an expired visitor token is renewed
/// instead of leaving the chat on "Reconnecting…" for good.
class MessengerController extends ChangeNotifier {
  MessengerController({
    required this.api,
    required this.signIn,
    this.realtimeFactory = socketIoChannel,
    this.onDiagnostic,
    this.onUnreadChanged,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final MessengerApi api;

  /// Signs the visitor in (identity, stored visitor id) and returns the session.
  final Future<MessengerSession> Function() signIn;
  final RealtimeFactory realtimeFactory;
  final MessengerDiagnostics? onDiagnostic;

  /// The total of unread replies across conversations, whenever it changes.
  final void Function(int total)? onUnreadChanged;
  final DateTime Function() _now;

  // ---- start-up --------------------------------------------------------
  MessengerPhase phase = MessengerPhase.loading;
  String? failure;
  MessengerSession? session;
  BrandColors brand = BrandColors(null);
  String? visitorEmail;

  // ---- the Messages list ----------------------------------------------
  List<ConversationSummary> conversations = <ConversationSummary>[];
  bool conversationsLoaded = false;

  // ---- the live thread: the open conversation, or the one about to start
  String? liveId;
  final List<ChatMessage> live = <ChatMessage>[];
  final List<OutgoingMessage> outgoing = <OutgoingMessage>[];
  DateTime? agentSeenAt;
  int dividerIndex = -1;
  WorkflowPreview? preview;
  DateTime? previewShownAt;
  String? pendingCsatRatingId;
  final Set<String> settledPrompts = <String>{};
  bool flowBusy = false;
  String? flowNotice;
  String? collectError;
  bool agentTyping = false;
  String? sendError;
  bool viewingLive = false;

  // ---- realtime ----------------------------------------------------------
  RealtimeChannel? _channel;
  StreamSubscription<RealtimeEvent>? _events;
  LinkState link = LinkState.connecting;

  /// Teammates connected right now; null while not known.
  int? agentsOnline;
  bool _everConnected = false;
  Timer? _reauthTimer;
  int _reauthFailures = 0;

  // ---- CSAT, help, files ---------------------------------------------------
  final Map<String, CsatAnswer> csat = <String, CsatAnswer>{};
  List<ArticleSummary> articles = <ArticleSummary>[];
  bool articlesLoaded = false;
  String? helpUrl;
  final Map<String, Future<Uint8List>> _files = <String, Future<Uint8List>>{};

  // ---- timers ---------------------------------------------------------------
  Timer? _agentTypingTimer;
  Timer? _visitorTypingTimer;
  bool _visitorTyping = false;
  Timer? _drip;
  String? _streamId;
  String _streamBuffer = '';
  String? _streamFinalId;
  Timer? _emailThanks;
  String? emailSavedFor;
  int _seq = 0;
  bool _disposed = false;

  // ======================================================================
  // Start
  // ======================================================================

  /// Sign in, load the conversations and the open thread, then go live.
  /// A failure leaves [phase] failed with a reason; [start] again retries.
  Future<void> start() async {
    _closeChannel();
    phase = MessengerPhase.loading;
    failure = null;
    _notify();
    final started = _now();
    try {
      final s = await signIn();
      session = s;
      brand = BrandColors(s.brandColor);
      visitorEmail = s.email;
      unawaited(loadArticles());

      OpenConversationInfo open;
      try {
        open = await api.openConversation();
      } catch (_) {
        open = const OpenConversationInfo(); // the catch-up on connect tries again
      }
      pendingCsatRatingId = open.pendingCsatRatingId;
      liveId = open.conversationId;
      await refreshConversations();
      if (liveId != null) {
        await _loadLive(unread: open.unreadCount);
      } else {
        await _loadPreview();
      }
      phase = MessengerPhase.ready;
      _diag('messenger_ready', <String, Object?>{'ms': _now().difference(started).inMilliseconds});
      _notify();
      _connect();
    } catch (e) {
      phase = MessengerPhase.failed;
      failure = e is ApiException ? e.message : '$e';
      _diag('messenger_failed', <String, Object?>{
        'reason': e is ApiException && e.status == 0 ? 'network' : 'http_${e is ApiException ? e.status : 0}',
        'detail': failure,
      });
      _notify();
    }
  }

  Future<void> _loadLive({int unread = 0}) async {
    final id = liveId;
    if (id == null) return;
    final d = await api.conversation(id);
    live
      ..clear()
      ..addAll(d.messages.where((m) => !m.isSystem));
    agentSeenAt = d.agentLastSeenAt;
    _seedCsat(d.csat);
    preview = null;
    dividerIndex = unread > 0 ? (live.length - unread).clamp(0, live.length) : -1;
  }

  Future<void> _loadPreview() async {
    try {
      preview = await api.workflow();
      previewShownAt = _now();
    } catch (_) {
      preview = null; // no opening menu, the customer can still type
    }
  }

  /// Reload the Messages list (newest first).
  Future<void> refreshConversations() async {
    try {
      conversations = await api.conversations();
      conversationsLoaded = true;
      if (viewingLive) _zeroUnread(liveId);
      _emitUnread();
      _notify();
    } catch (_) {
      conversationsLoaded = true; // keep what was there; an empty list is not an error
      _notify();
    }
  }

  // ======================================================================
  // Realtime
  // ======================================================================

  void _connect() {
    _closeChannel();
    final ch = realtimeFactory(apiUrl: api.apiUrl, token: () => api.token ?? '');
    _channel = ch;
    _events = ch.events.listen(_onEvent);
    link = LinkState.connecting;
    ch.connect();
  }

  void _closeChannel() {
    _events?.cancel();
    _events = null;
    _channel?.dispose();
    _channel = null;
    _reauthTimer?.cancel();
  }

  void _onEvent(RealtimeEvent e) {
    final data = e.data is Map ? Map<String, dynamic>.from(e.data! as Map) : <String, dynamic>{};
    switch (e.name) {
      case 'connect':
        final again = _everConnected;
        _everConnected = true;
        _reauthFailures = 0;
        link = LinkState.connected;
        _notify();
        if (again) unawaited(_catchUp());
      case 'disconnect':
        link = LinkState.reconnecting;
        agentsOnline = null;
        agentTyping = false;
        _notify();
        // The server dropped us on purpose (not a network blip): Socket.IO
        // does not come back by itself from that one.
        if ('${e.data}' == 'io server disconnect') _channel?.connect();
      case 'connect_error':
        link = LinkState.reconnecting;
        agentsOnline = null;
        _notify();
        final why = '${e.data}';
        if (why.contains('invalid_token') || why.contains('authentication_required')) _renewTokenAndReconnect();
      case 'message:created':
        _onMessage(data);
      case 'presence:update':
        final n = data['agentsOnline'];
        agentsOnline = n is num ? n.toInt() : null;
        _notify();
      case 'conversation:seen':
        if (data['seenBy'] == 'agent' && _inLive(data)) {
          agentSeenAt = DateTime.tryParse('${data['seenAt']}')?.toLocal() ?? agentSeenAt;
          _notify();
        }
      case 'typing:start':
      case 'typing:stop':
        if (data['authorType'] == 'visitor' || !_inLive(data)) return;
        _agentTypingTimer?.cancel();
        agentTyping = e.name == 'typing:start';
        if (agentTyping) {
          _agentTypingTimer = Timer(const Duration(seconds: 5), () {
            agentTyping = false;
            _notify();
          });
        }
        _notify();
      case 'ai:stream_start':
        _onStreamStart(data);
      case 'ai:stream_chunk':
        if (_inLive(data) && data['streamId'] == _streamId) {
          _streamBuffer += '${data['delta'] ?? ''}';
          _ensureDrip();
        }
      case 'ai:stream_end':
        if (_inLive(data) && data['streamId'] == _streamId) {
          _streamBuffer = stripEscalationMarker(_streamBuffer);
          final m = _liveById(_streamId!);
          if (m != null) m.body = stripEscalationMarker(m.body);
          _streamFinalId = data['messageId'] as String?;
          _ensureDrip();
        }
      case 'ai:stream_aborted':
        if (!_inLive(data)) return;
        live.removeWhere((m) => m.id == data['streamId']);
        if (data['streamId'] == _streamId) {
          _streamId = null;
          _streamBuffer = '';
          _drip?.cancel();
        }
        _notify();
    }
  }

  /// The visitor token is 24 hours old (or was refused): sign in again and
  /// reconnect, backing off if sign-in itself keeps failing.
  void _renewTokenAndReconnect() {
    if (_reauthTimer?.isActive ?? false) return;
    final wait = _reauthFailures == 0 ? Duration.zero : Duration(seconds: (5 << (_reauthFailures - 1)).clamp(5, 60));
    _reauthTimer = Timer(wait, () async {
      final token = await api.reauthenticate?.call();
      if (_disposed) return;
      if (token == null) {
        _reauthFailures++;
        _renewTokenAndReconnect();
        return;
      }
      _channel?.connect();
    });
  }

  /// After a reconnect: what arrived while we were away.
  Future<void> _catchUp() async {
    try {
      if (liveId == null) {
        final open = await api.openConversation();
        if (open.conversationId == null) return;
        liveId = open.conversationId;
      }
      final d = await api.conversation(liveId!);
      final known = live.map((m) => m.id).toSet();
      final missed = d.messages.where((m) => !m.isSystem && !known.contains(m.id)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (missed.isNotEmpty) {
        preview = null;
        live.addAll(missed);
      }
      agentSeenAt = d.agentLastSeenAt ?? agentSeenAt;
      _seedCsat(d.csat);
      await refreshConversations();
      if (viewingLive && missed.any((m) => !m.fromVisitor)) unawaited(_markSeen());
      _notify();
    } catch (_) {
      // the next reconnect tries again
    }
  }

  bool _inLive(Map<String, dynamic> data) {
    final id = data['conversationId'];
    return id == null || liveId == null || id == liveId;
  }

  ChatMessage? _liveById(String id) {
    for (final m in live) {
      if (m.id == id) return m;
    }
    return null;
  }

  void _onMessage(Map<String, dynamic> data) {
    final msg = ChatMessage.fromJson(data);
    if (msg.id.isEmpty || msg.isSystem) return;
    _touchList(msg);
    liveId ??= msg.conversationId;
    if (msg.conversationId != liveId) {
      _notify();
      return;
    }
    if (_liveById(msg.id) != null) return;
    preview = null;
    if (!msg.fromVisitor) {
      agentTyping = false;
      _agentTypingTimer?.cancel();
      if (viewingLive) {
        unawaited(_markSeen());
      } else if (dividerIndex < 0) {
        dividerIndex = live.length;
      }
    }
    live.add(msg);
    _notify();
  }

  /// Keep the Messages list in step with a message: its preview, its time,
  /// its unread count — or a new row for a conversation that just started.
  void _touchList(ChatMessage msg) {
    ConversationSummary? row;
    for (final c in conversations) {
      if (c.id == msg.conversationId) row = c;
    }
    if (row == null) {
      row = ConversationSummary(id: msg.conversationId, open: true, lastMessageAt: msg.createdAt);
      conversations.insert(0, row);
    }
    row
      ..lastBody = msg.body
      ..lastAuthorType = msg.authorType
      ..lastAuthorName = msg.authorName
      ..lastMessageAt = msg.createdAt
      ..open = true;
    final onScreen = viewingLive && msg.conversationId == liveId;
    if (!msg.fromVisitor && !onScreen) row.unreadCount += 1;
    conversations.sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    _emitUnread();
  }

  // ---- AI answers, typed out as they stream ---------------------------------

  void _onStreamStart(Map<String, dynamic> data) {
    if (!_inLive(data)) return;
    final id = data['streamId'];
    if (id is! String || _liveById(id) != null) return;
    agentTyping = false;
    _agentTypingTimer?.cancel();
    liveId ??= data['conversationId'] as String?;
    live.add(ChatMessage(
      id: id,
      conversationId: liveId ?? '',
      body: '',
      authorType: 'ai',
      authorName: (data['authorName'] as String?) ?? 'AI',
      createdAt: DateTime.tryParse('${data['createdAt']}')?.toLocal() ?? _now(),
    ));
    _streamId = id;
    _streamBuffer = '';
    _streamFinalId = null;
    if (!viewingLive && dividerIndex < 0) dividerIndex = live.length - 1;
    _notify();
  }

  void _ensureDrip() {
    if (_drip?.isActive ?? false) return;
    _drip = Timer.periodic(const Duration(milliseconds: 25), (_) => _dripTick());
  }

  void _dripTick() {
    final id = _streamId;
    final m = id == null ? null : _liveById(id);
    if (m == null) {
      _drip?.cancel();
      return;
    }
    if (_streamBuffer.isNotEmpty) {
      final n = dripStep(_streamBuffer.length).clamp(1, _streamBuffer.length);
      m.body += _streamBuffer.substring(0, n);
      _streamBuffer = _streamBuffer.substring(n);
      _notify();
      return;
    }
    final finalId = _streamFinalId;
    if (finalId != null) {
      m.id = finalId;
      _streamId = null;
      _streamFinalId = null;
      _drip?.cancel();
      _touchList(m);
      if (viewingLive) unawaited(_markSeen());
      _notify();
      return;
    }
    _drip?.cancel();
  }

  // ======================================================================
  // What the customer does
  // ======================================================================

  /// The screen showing the live conversation came or went: while it is up,
  /// replies count as read the moment they arrive.
  void setViewingLive(bool viewing) {
    viewingLive = viewing;
    if (viewing) {
      unawaited(_markSeen());
    } else {
      dividerIndex = -1;
      _stopVisitorTyping();
    }
    _notify();
  }

  Future<void> _markSeen() async {
    final id = liveId;
    if (id == null) return;
    _zeroUnread(id);
    try {
      await api.seen(id);
    } catch (_) {
      // the next reply or reopen marks it again
    }
  }

  void _zeroUnread(String? id) {
    for (final c in conversations) {
      if (c.id == id && c.unreadCount != 0) {
        c.unreadCount = 0;
        _emitUnread();
      }
    }
  }

  int get totalUnread => conversations.fold(0, (sum, c) => sum + c.unreadCount);
  int _lastUnread = -1;

  void _emitUnread() {
    final n = totalUnread;
    if (n == _lastUnread) return;
    _lastUnread = n;
    onUnreadChanged?.call(n);
  }

  /// Send what they typed, and/or a photo. The bubble shows at once; if the
  /// server refuses it, the bubble says so and [retry] sends it again.
  Future<bool> send(String text, {Uint8List? image, String? imageName, String? imageType}) {
    final body = text.trim();
    if (body.isEmpty && image == null) return Future<bool>.value(false);
    _stopVisitorTyping();
    final out = OutgoingMessage(
      localId: 'local-${++_seq}',
      text: body,
      createdAt: _now(),
      image: image,
      imageName: imageName,
      imageType: imageType,
    );
    outgoing.add(out);
    return _deliver(out);
  }

  Future<bool> retry(OutgoingMessage out) {
    if (!outgoing.contains(out)) return Future<bool>.value(false);
    return _deliver(out);
  }

  void discard(OutgoingMessage out) {
    outgoing.remove(out);
    _notify();
  }

  Future<bool> _deliver(OutgoingMessage out) async {
    out.error = null;
    sendError = null;
    _notify();
    try {
      final image = out.image;
      if (image != null && out.uploadId == null) {
        final up = await api.upload(image, name: out.imageName ?? 'photo.jpg', contentType: out.imageType ?? 'image/jpeg');
        out.uploadId = up.id;
        _files[up.id] = Future<Uint8List>.value(image); // no need to download what we just sent
      }
      final ch = _channel;
      if (ch == null) throw const ApiException(0, 'Not connected yet — try again in a moment.');
      final ack = await ch.request('visitor:message', <String, dynamic>{
        'body': out.text,
        if (out.uploadId != null) 'attachments': <String>[out.uploadId!],
      });
      if (ack['ok'] == true && ack['message'] is Map) {
        final msg = ChatMessage.fromJson(Map<String, dynamic>.from(ack['message'] as Map));
        outgoing.remove(out);
        liveId ??= msg.conversationId;
        preview = null;
        if (_liveById(msg.id) == null) {
          live.add(msg);
          _touchList(msg);
        }
        _notify();
        return true;
      }
      out.error = sendFailureText(ack['error']);
    } on ApiException catch (e) {
      out.error = e.status == 0 ? 'No connection — check your signal and try again.' : e.message;
    }
    sendError = out.error;
    _notify();
    return false;
  }

  /// What a refused message tells the customer. The server's own sentences
  /// (rate limit, too long) are shown as they are; codes become words.
  static String sendFailureText(Object? error) {
    final e = error is String ? error : '';
    if (e.isEmpty || e == 'server_error' || e == 'invalid_input' || e == 'failed_to_create_message') {
      return 'Something went wrong — please try again.';
    }
    if (e == 'timeout') return 'No answer from the server — check your connection and try again.';
    return e;
  }

  /// The customer is typing (for the team's "typing…").
  void composerChanged(String text) {
    final id = liveId;
    final ch = _channel;
    if (id == null || ch == null) return;
    if (text.trim().isEmpty) {
      _stopVisitorTyping();
      return;
    }
    if (!_visitorTyping) {
      _visitorTyping = true;
      ch.emit('typing:start', <String, dynamic>{'conversationId': id});
    }
    _visitorTypingTimer?.cancel();
    _visitorTypingTimer = Timer(const Duration(seconds: 3), _stopVisitorTyping);
  }

  void _stopVisitorTyping() {
    _visitorTypingTimer?.cancel();
    if (!_visitorTyping) return;
    _visitorTyping = false;
    final id = liveId;
    if (id != null) _channel?.emit('typing:stop', <String, dynamic>{'conversationId': id});
  }

  // ---- workflows --------------------------------------------------------------

  /// The last message, if it is a bot question still waiting for an answer.
  ChatMessage? get livePrompt {
    if (live.isEmpty) return null;
    final last = live.last;
    if (last.authorType != 'bot' || settledPrompts.contains(last.id)) return null;
    return (last.meta?.isPrompt ?? false) ? last : null;
  }

  /// Null when the customer may type; otherwise the hint to show instead.
  String? get composerLock {
    final p = preview;
    if (live.isEmpty && p != null && !p.letCustomerType) return 'Choose an option above';
    final prompt = livePrompt;
    if (prompt != null && prompt.meta!.lockComposer) {
      return prompt.meta!.collect != null ? 'Answer the question above' : 'Choose an option above';
    }
    return null;
  }

  static const _settled = <String>{'stale', 'not_in_flow', 'workflow_gone', 'unknown_button'};

  static String flowFailed(Object? error) {
    final e = error is String ? error : '';
    if (e.isEmpty || e == 'server_error' || e == 'invalid_input' || e == 'timeout') return 'Something went wrong — please try again.';
    return e;
  }

  /// A button on the opening menu: the conversation starts here.
  Future<void> startWorkflow(FlowButton button) async {
    final p = preview;
    final ch = _channel;
    if (p == null || ch == null || flowBusy) return;
    flowBusy = true;
    flowNotice = null;
    _notify();
    final ack = await ch.request('workflow:start', <String, dynamic>{'workflowId': p.workflowId, 'buttonId': button.id});
    flowBusy = false;
    if (ack['ok'] == true) {
      liveId = (ack['conversationId'] as String?) ?? liveId;
      preview = null;
    } else {
      switch (ack['error']) {
        case 'already_in_conversation':
          preview = null;
          await _catchUp();
        case 'workflow_changed':
        case 'workflow_invalid':
        case 'unknown_button':
          await _loadPreview();
        default:
          flowNotice = flowFailed(ack['error']);
      }
    }
    _notify();
  }

  /// A button under a bot question in the thread.
  Future<void> choose(ChatMessage prompt, FlowButton button) async {
    final ch = _channel;
    final id = liveId;
    if (ch == null || id == null || flowBusy) return;
    flowBusy = true;
    flowNotice = null;
    _notify();
    final ack = await ch.request('workflow:choose', <String, dynamic>{'conversationId': id, 'promptId': prompt.id, 'buttonId': button.id});
    flowBusy = false;
    if (ack['ok'] != true) {
      if (_settled.contains(ack['error'])) {
        settledPrompts.add(prompt.id);
      } else {
        flowNotice = flowFailed(ack['error']);
      }
    }
    _notify();
  }

  /// A detail the bot asked for (email, phone, …). True when it was taken.
  Future<bool> collect(ChatMessage prompt, String value) async {
    final ch = _channel;
    final id = liveId;
    final v = value.trim();
    if (ch == null || id == null || flowBusy || v.isEmpty) return false;
    flowBusy = true;
    collectError = null;
    flowNotice = null;
    _notify();
    final ack = await ch.request('workflow:collect', <String, dynamic>{'conversationId': id, 'promptId': prompt.id, 'value': v});
    flowBusy = false;
    var ok = ack['ok'] == true;
    if (!ok && _settled.contains(ack['error'])) {
      settledPrompts.add(prompt.id);
      ok = true;
    } else if (!ok) {
      collectError = flowFailed(ack['error']);
    }
    _notify();
    return ok;
  }

  // ---- CSAT -----------------------------------------------------------------

  void _seedCsat(CsatState? s) {
    if (s == null || s.rating == null || csat.containsKey(s.ratingId)) return;
    csat[s.ratingId] = CsatAnswer(rating: s.rating, commentState: 'sent', comment: s.comment ?? '');
  }

  /// A face tapped. Shown at once; taken back (with a reason) if it did not save.
  Future<void> rate(String ratingId, int rating) async {
    final before = csat[ratingId];
    final first = before?.rating == null;
    final answer = before ?? CsatAnswer();
    answer
      ..rating = rating
      ..error = null;
    csat[ratingId] = answer;
    _notify();
    final ack = await (_channel?.request('csat:rate', <String, dynamic>{'ratingId': ratingId, 'rating': rating}) ??
        Future<Map<String, dynamic>>.value(<String, dynamic>{'ok': false, 'error': 'not_connected'}));
    if (ack['ok'] != true) {
      final error = ack['error'];
      if (error == 'expired' || error == 'not_found') {
        answer.error = 'This question has closed — thank you all the same.';
      } else {
        if (first) answer.rating = null;
        answer.error = 'That did not save — please try again.';
      }
      _notify();
    }
  }

  Future<void> comment(String ratingId, String text) async {
    final answer = csat[ratingId];
    final t = text.trim();
    if (answer?.rating == null || t.isEmpty) return;
    answer!
      ..commentState = 'sending'
      ..error = null;
    _notify();
    final ack = await (_channel?.request('csat:rate', <String, dynamic>{'ratingId': ratingId, 'rating': answer.rating, 'comment': t}) ??
        Future<Map<String, dynamic>>.value(<String, dynamic>{'ok': false}));
    if (ack['ok'] == true) {
      answer
        ..commentState = 'sent'
        ..comment = t;
    } else {
      answer
        ..commentState = 'open'
        ..error = 'That did not save — please try again.';
    }
    _notify();
  }

  // ---- "leave your email" while nobody is online --------------------------------

  bool get showEmailBar => agentsOnline == 0 && (visitorEmail ?? '').isEmpty || emailSavedFor != null;

  /// Null when saved; otherwise what to tell the customer.
  Future<String?> leaveEmail(String email) async {
    final e = email.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e)) return 'Enter a valid email address.';
    try {
      await api.leaveEmail(e);
    } on ApiException catch (err) {
      return err.status == 0 ? 'No connection — try again.' : err.message;
    }
    visitorEmail = e;
    emailSavedFor = e;
    _emailThanks?.cancel();
    _emailThanks = Timer(const Duration(seconds: 4), () {
      emailSavedFor = null;
      _notify();
    });
    _notify();
    return null;
  }

  // ---- other conversations, files, help ---------------------------------------------

  /// One of the customer's conversations, in full (the closed ones too).
  Future<ConversationDetail> loadConversation(String id) async {
    final d = await api.conversation(id);
    _seedCsat(d.csat);
    _zeroUnread(id);
    unawaited(api.seen(id).catchError((Object _) {}));
    _notify();
    return d;
  }

  /// The bytes of the customer's own photo, fetched once.
  Future<Uint8List> fileBytes(String uploadId) {
    return _files.putIfAbsent(uploadId, () {
      final f = api.file(uploadId);
      f.catchError((Object _) {
        _files.remove(uploadId); // let a later look try again
        return Uint8List(0);
      });
      return f;
    });
  }

  /// The chips under an empty thread: the chatbot's own, else its top articles.
  List<SuggestedQuestion> get chips {
    final own = session?.suggestedQuestions ?? const <SuggestedQuestion>[];
    if (own.isNotEmpty) return own;
    return articles.take(3).map((a) => SuggestedQuestion(text: a.title, articleSlug: a.slug, action: 'article')).toList();
  }

  Future<void> loadArticles() async {
    try {
      final r = await api.articles();
      articles = r.articles;
      helpUrl = r.helpUrl;
    } catch (_) {
      articles = <ArticleSummary>[];
    }
    articlesLoaded = true;
    _notify();
  }

  /// Title and description matches, at once, while the server search runs.
  List<ArticleSummary> localSearch(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return articles;
    return articles
        .where((a) => a.title.toLowerCase().contains(q) || (a.description ?? '').toLowerCase().contains(q))
        .toList();
  }

  /// The server's search (bodies too); null when it failed.
  Future<List<ArticleSummary>?> searchArticles(String query) async {
    try {
      return (await api.articles(query: query, limit: 20)).articles;
    } catch (_) {
      return null;
    }
  }

  Future<Article> article(String slug) => api.article(slug);

  // ======================================================================

  void _diag(String event, Map<String, Object?> detail) {
    try {
      onDiagnostic?.call(event, detail);
    } catch (_) {
      // a diagnostics hook must never break support
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopVisitorTyping();
    _closeChannel();
    _agentTypingTimer?.cancel();
    _drip?.cancel();
    _emailThanks?.cancel();
    super.dispose();
  }
}
