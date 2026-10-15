import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../api/realtime.dart';
import 'format.dart';
import 'look.dart';

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

  /// Failed for want of an answer, after it was handed over: it may have
  /// arrived all the same (see [MessengerController]'s `_arrivedAfterAll`).
  bool _noAnswer = false;

  /// Waiting for the connection: it goes by itself, in the order it was
  /// written, as soon as the messenger is connected. False while it is
  /// being sent, and once it has failed.
  bool queued = false;
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

/// A message waiting its turn to be sent, and whoever is waiting on it.
class _Send {
  _Send(this.out);
  final OutgoingMessage out;
  final done = Completer<bool>();
}

/// Everything the messenger screens show and do, in one place.
///
/// It follows the website messenger rule for rule,
/// with the fixes that spec called for: a refused message says why, a
/// reconnect fetches what was missed, and an expired visitor token is renewed
/// instead of leaving the chat on "Reconnecting…" for good.
///
/// One controller lives for as long as the same customer is signed in, so
/// the messenger opens at once from what it already holds and refreshes
/// behind it. The screens [attach] while they show it and [detach] when they
/// close; a sign-out, or someone else signing in, calls [reset] or disposes it.
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

  /// How the chatbot looked last time, drawn while it signs in (Home's
  /// skeleton). Until there is a session it gives the brand colour too.
  MessengerLook? get look => _look;
  MessengerLook? _look;
  set look(MessengerLook? value) {
    _look = value;
    if (session == null && value != null) brand = BrandColors(value.brandColor);
  }

  /// The customer's first name as the app gave it in a signed identity, for
  /// the skeleton's greeting; the server's word replaces it.
  String? lookName;

  /// A screen has shown this controller and closed: the next open is a
  /// reopen.
  bool wasOpened = false;

  /// True while the open conversation and the Messages list are being
  /// fetched. On a reopen the screens already show what was there; this says
  /// it may be about to change.
  bool refreshing = false;

  /// The open conversation (or the opening menu) has been fetched for this
  /// customer. The first open shows Home before it is; until then the
  /// conversation screen shows a spinner, not the opening chips.
  bool liveLoaded = false;

  /// Moves on at every [reset]: the screens close whatever they had opened
  /// for the customer before.
  int resets = 0;

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

  /// Who is typing a reply: a teammate (named by a server since 12 Oct, so
  /// their face shows) or the workflow. Null while nobody is.
  TypingAuthor? typingAuthor;
  bool get agentTyping => typingAuthor != null;
  String? sendError;
  bool viewingLive = false;

  /// Messages that came in live — over the connection, or sent by the
  /// customer just now — and are not drawn yet: the thread lets them in with
  /// a short fade. What a fetch brings (history, a reopen, a catch-up) is
  /// never here, so it is simply there. The screen settles them once drawn.
  final Set<Object> _arriving = Set<Object>.identity();

  /// [message] (a [ChatMessage] or an [OutgoingMessage]) came in live and
  /// has not been drawn yet.
  bool isArriving(Object message) => _arriving.contains(message);

  /// The messages arriving now, to settle once they are drawn.
  List<Object> get arriving => List<Object>.of(_arriving);

  /// Drawn, or never to be: no longer arriving. Without [these], all.
  void settleArrivals([Iterable<Object>? these]) {
    if (these == null) {
      _arriving.clear();
    } else {
      _arriving.removeAll(these);
    }
  }

  /// What the customer has typed and not sent ([composerChanged] keeps it),
  /// there again at the next open; dropped with everything else when
  /// someone else signs in.
  String draft = '';

  // ---- realtime ----------------------------------------------------------
  RealtimeChannel? _channel;
  StreamSubscription<RealtimeEvent>? _events;
  LinkState link = LinkState.connecting;

  /// Teammates connected right now; null while not known — before the
  /// connection says, and whenever it is not connected.
  int? agentsOnline;

  /// The last count the server sent, kept through a reconnect and a reopen.
  /// Only for the "leave your email" form: without it the form went at every
  /// drop and reopen and came back when the count did, moving the thread.
  int? _lastOnline;
  Timer? _reauthTimer;
  int _reauthFailures = 0;

  /// The live connection is up. Sending does not wait on the screens for
  /// it: [send] queues until it is.
  bool get connected => link == LinkState.connected;

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

  // ---- whose it is, and who is looking ---------------------------------------

  /// Moves on at every [reset]. Whatever was on its way for the customer
  /// before (a sign-in, a load, a message) compares it when it lands, and is
  /// dropped if it moved.
  int _epoch = 0;
  Future<void>? _startRun;
  Future<void>? _loadRun;
  Future<void>? _prefetchRun;

  /// The Messages list's part of the loads that are out: the first open
  /// shows Home once it is in.
  Future<void>? _listLoad;
  int _attached = 0;

  /// The screens have closed: the connection goes once nothing is left to send.
  bool _suspended = false;
  Timer? _idleTimer;

  /// The app is in front. While it is not, nothing counts as read.
  bool _appActive = true;
  bool _backgrounded = false;

  // ---- sending in order ------------------------------------------------------
  final List<_Send> _queue = <_Send>[];
  bool _delivering = false;
  final List<Completer<void>> _linkWaiters = <Completer<void>>[];

  // ---- redraws ---------------------------------------------------------------
  int? _frameCallback;
  bool _afterFrame = false;

  // ======================================================================
  // Start
  // ======================================================================

  /// A messenger screen shows this controller: bring it up to date.
  void attach() {
    _attached++;
    unawaited(start());
  }

  /// A messenger screen closed. When none is left the connection closes —
  /// once the messages still waiting to go have gone — and everything shown
  /// is kept for the next open.
  void detach() {
    wasOpened = true;
    if (_attached > 0) _attached--;
    if (_attached == 0) _suspend();
  }

  /// Sign in, load the conversations and the open thread, and go live.
  ///
  /// The first time, [phase] is loading until the sign-in and the Messages
  /// list are in (what Home shows); the open conversation follows behind
  /// ([liveLoaded]). A failed sign-in leaves it failed with a reason, and
  /// [start] again retries. Once it has been ready (a reopen), the screens
  /// keep showing what is there while it refreshes behind them, and a
  /// failure leaves it as it was.
  Future<void> start() {
    _suspended = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    final running = _startRun;
    if (running != null) {
      // Closed and opened again while it was still out: the connection may
      // have been closed meanwhile.
      if (session != null && api.token != null) _ensureChannel();
      return running;
    }
    final run = _start();
    _startRun = run;
    return run.whenComplete(() {
      if (identical(_startRun, run)) _startRun = null;
    });
  }

  Future<void> _start() async {
    // Fetching ahead (see [prefetch]): its sign-in and list are this open's own.
    final ahead = _prefetchRun;
    if (ahead != null) await ahead;
    final epoch = _epoch;
    final cached = phase == MessengerPhase.ready;
    final opened = _now();
    _lastUnread = -1; // the badge may have moved while it was closed: say the count again
    Future<void>? loads;
    if (cached) {
      // What is on screen may be about to change — from the moment it opens,
      // so a push's "which conversation" waits for the answer.
      refreshing = true;
      _notify();
      if (api.token != null) {
        // The same customer, with the token from last time: catch up and go
        // live straight away, while the sign-in refreshes the session alongside.
        loads = _loads(epoch);
        _ensureChannel();
      }
    } else {
      phase = MessengerPhase.loading;
      failure = null;
      _notify();
    }
    try {
      final s = await signIn();
      if (epoch != _epoch) return;
      _took(s);
    } catch (e) {
      if (epoch != _epoch) return;
      if (!cached) {
        phase = MessengerPhase.failed;
        failure = e is ApiException ? e.message : '$e';
        _diag('messenger_failed', <String, Object?>{
          'reason': e is ApiException && e.status == 0 ? 'network' : 'http_${e is ApiException ? e.status : 0}',
          'detail': failure,
        });
        _notify();
        return;
      }
      // Keep what is on screen. The connection keeps trying, renewing the
      // token itself, and its connect catches up.
      _ensureChannel();
      if (loads != null) await loads;
      if (epoch != _epoch) return;
      refreshing = _loadRun != null; // a connect may have started a catch-up meanwhile
      _notify();
      if (_suspended) _closeWhenIdle();
      return;
    }
    unawaited(loadArticles());
    // The loads and the connection side by side, not one after the other.
    loads ??= _loads(epoch);
    _ensureChannel();
    if (!cached) {
      // Home shows the Messages list, never the open conversation: it is up
      // once the list is in, a round trip sooner, and the conversation comes
      // in behind it (a push waits for it on [refreshing]).
      await (_listLoad ?? loads);
      if (epoch != _epoch) return;
      phase = MessengerPhase.ready;
      _diag('messenger_ready', <String, Object?>{'ms': _now().difference(opened).inMilliseconds});
      _notify();
    }
    await loads;
    if (epoch != _epoch) return;
    if (cached) _diag('messenger_ready', <String, Object?>{'ms': _now().difference(opened).inMilliseconds, 'cached': true});
    _notify();
    if (_suspended) _closeWhenIdle();
  }

  /// Before the messenger is first opened (just after the app's `login`):
  /// sign in and fetch what Home shows — the Messages list and the top
  /// articles — without going live, so the open shows Home at once rather
  /// than a skeleton. The open conversation waits for the open. Never
  /// throws; one that fails leaves the open to sign in as it always did.
  Future<void> prefetch() {
    if (_disposed || _attached > 0 || _startRun != null || phase != MessengerPhase.loading) return Future<void>.value();
    final running = _prefetchRun;
    if (running != null) return running;
    final run = _prefetch();
    _prefetchRun = run;
    return run.whenComplete(() {
      if (identical(_prefetchRun, run)) _prefetchRun = null;
    });
  }

  Future<void> _prefetch() async {
    final epoch = _epoch;
    try {
      final s = await signIn();
      if (epoch != _epoch || phase != MessengerPhase.loading) return;
      _took(s);
      unawaited(loadArticles());
      await refreshConversations();
      if (epoch != _epoch || phase != MessengerPhase.loading) return;
      phase = MessengerPhase.ready;
      _notify();
    } catch (_) {
      // the open signs in again, and shows why if it cannot
    }
  }

  /// A sign-in came back: what it says is what Home shows. Its pictures are
  /// fetched now, so Home draws them at once rather than popping them in.
  void _took(MessengerSession s) {
    session = s;
    brand = BrandColors(s.brandColor);
    visitorEmail = s.email;
    final urls = <String>[
      if (s.logoUrl != null) s.logoUrl!,
      if (s.avatarUrl != null) s.avatarUrl!,
      for (final t in s.team)
        if ((t.avatarPath ?? '').isNotEmpty) '${api.apiUrl}${t.avatarPath}',
    ];
    for (final url in urls) {
      precacheNetworkImage(url);
    }
  }

  /// Fetch what changed — the open conversation and the Messages list — and
  /// merge it into what is shown, without duplicates. One at a time: a call
  /// while one is out shares it.
  Future<void> refresh() => session == null ? Future<void>.value() : _loads(_epoch);

  Future<void> _loads(int epoch) {
    final running = _loadRun;
    if (running != null) return running;
    refreshing = true;
    _notify();
    final run = _runLoads(epoch);
    _loadRun = run;
    return run;
  }

  Future<void> _runLoads(int epoch) async {
    try {
      // Each catches its own failure: one that fails never blanks the other.
      final open = _loadOpen(epoch);
      final list = _listLoad = refreshConversations();
      await Future.wait<void>(<Future<void>>[open, list]);
    } finally {
      if (epoch == _epoch) {
        _loadRun = null;
        _listLoad = null;
        refreshing = false;
        liveLoaded = true;
        _notify();
      }
    }
  }

  /// Which conversation is open, and its messages; or the opening menu.
  Future<void> _loadOpen(int epoch) async {
    final before = liveId;
    OpenConversationInfo open;
    try {
      open = await api.openConversation();
    } catch (_) {
      if (epoch != _epoch) return;
      // Not known right now: keep what is shown; with nothing shown, the
      // opening menu as before. The next catch-up asks again.
      if (liveId == null && live.isEmpty) await _loadPreview(epoch);
      return;
    }
    if (epoch != _epoch) return;
    pendingCsatRatingId = open.pendingCsatRatingId;
    final id = open.conversationId;
    if (id == null) {
      // A conversation started meanwhile (the customer wrote): that is the one.
      if (liveId != before) return;
      // The one shown has been closed since: start afresh — unless the
      // customer is reading it right now; it stays until they leave.
      if (liveId != null && !viewingLive) {
        liveId = null;
        live.clear();
        agentSeenAt = null;
        dividerIndex = -1;
      }
      if (liveId == null && live.isEmpty) await _loadPreview(epoch);
      _notify();
      return;
    }
    liveId = id;
    try {
      final d = await api.conversation(id);
      if (epoch != _epoch || liveId != id) return;
      _mergeLive(d, unread: open.unreadCount);
      preview = null;
      if (_seeing && open.unreadCount > 0) unawaited(_markSeen());
    } catch (_) {
      // Keep what is shown; the next catch-up tries again.
    }
    _notify();
  }

  /// The server's copy of the open conversation, plus what arrived over the
  /// connection after it was read (and an AI answer still typing out).
  void _mergeLive(ConversationDetail d, {int unread = 0}) {
    final fetched = d.messages.where((m) => !m.isSystem).toList();
    final ids = fetched.map((m) => m.id).toSet();
    final had = live.map((m) => m.id).toSet();
    final since = live.where((m) => m.conversationId == d.id && !ids.contains(m.id)).toList();
    live
      ..clear()
      ..addAll(fetched)
      ..addAll(since);
    for (final m in fetched) {
      if (!had.contains(m.id)) _arrivedAfterAll(m);
    }
    agentSeenAt = d.agentLastSeenAt ?? agentSeenAt;
    _seedCsat(d.csat);
    if (unread > 0) {
      dividerIndex = (live.length - unread).clamp(0, live.length);
    } else if (!viewingLive) {
      dividerIndex = -1;
    }
  }

  Future<void> _loadPreview(int epoch) async {
    try {
      final p = await api.workflow();
      if (epoch != _epoch || liveId != null || live.isNotEmpty) return;
      if (previewShownAt == null || p?.workflowId != preview?.workflowId) previewShownAt = _now();
      preview = p;
    } catch (_) {
      if (epoch != _epoch) return;
      preview = null; // no opening menu, the customer can still type
    }
  }

  /// Reload the Messages list (newest first).
  Future<void> refreshConversations() async {
    final epoch = _epoch;
    try {
      final rows = await api.conversations();
      if (epoch != _epoch) return;
      conversations = rows;
      conversationsLoaded = true;
      if (_seeing) _zeroUnread(liveId);
      _emitUnread();
      _notify();
    } catch (_) {
      if (epoch != _epoch) return;
      conversationsLoaded = true; // keep what was there; an empty list is not an error
      _notify();
    }
  }

  /// Forget everything this customer's messenger holds — conversations,
  /// messages, the draft, messages still waiting to go — at once: someone
  /// else is signed in now, or nobody. Whatever was still on its way for them
  /// is dropped when it lands. [start] then begins afresh.
  void reset() {
    _epoch++;
    resets++;
    _closeChannel();
    _idleTimer?.cancel();
    _idleTimer = null;
    _agentTypingTimer?.cancel();
    _visitorTypingTimer?.cancel();
    _visitorTyping = false;
    _drip?.cancel();
    _streamId = null;
    _streamBuffer = '';
    _streamFinalId = null;
    _emailThanks?.cancel();
    _releaseWaiting();
    _startRun = null;
    _loadRun = null;
    _listLoad = null;
    _prefetchRun = null;
    _delivering = false;
    phase = MessengerPhase.loading;
    failure = null;
    session = null;
    visitorEmail = null;
    refreshing = false;
    liveLoaded = false;
    conversations = <ConversationSummary>[];
    conversationsLoaded = false;
    liveId = null;
    live.clear();
    outgoing.clear();
    agentSeenAt = null;
    dividerIndex = -1;
    preview = null;
    previewShownAt = null;
    pendingCsatRatingId = null;
    settledPrompts.clear();
    flowBusy = false;
    flowNotice = null;
    collectError = null;
    typingAuthor = null;
    _arriving.clear();
    sendError = null;
    // The screen that showed the customer before goes in a moment; until
    // then nothing that arrives for the next one counts as read.
    viewingLive = false;
    draft = '';
    link = LinkState.connecting;
    agentsOnline = null;
    _lastOnline = null;
    _reauthFailures = 0;
    csat.clear();
    articles = <ArticleSummary>[];
    articlesLoaded = false;
    helpUrl = null;
    _files.clear();
    emailSavedFor = null;
    _lastUnread = -1;
    _notify();
  }

  // ======================================================================
  // While it is closed, and while the app is away
  // ======================================================================

  void _suspend() {
    _suspended = true;
    _stopVisitorTyping();
    _agentTypingTimer?.cancel();
    typingAuthor = null;
    _arriving.clear(); // the next open shows them as they are
    _settleStream();
    _closeWhenIdle();
  }

  /// Close the connection — unless messages are still waiting to go: they
  /// get a minute to, then they wait for the next open.
  void _closeWhenIdle() {
    if (!_suspended || _disposed) return;
    if (_queue.isNotEmpty) {
      _idleTimer ??= Timer(const Duration(seconds: 60), () {
        _idleTimer = null;
        if (_suspended) _hangUp();
      });
      return;
    }
    _hangUp();
  }

  void _hangUp() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _closeChannel();
    link = LinkState.connecting;
    agentsOnline = null; // stale by the next open
    // Closed, and kept until sign-out: only the photos the open conversation
    // shows stay in memory (to draw at once at the next open), not every
    // one sent or looked at since the app started. The rest are fetched
    // again if looked at.
    final shown = <String?>{
      for (final m in live)
        for (final a in m.attachments) a.uploadId,
      for (final o in outgoing) o.uploadId,
    };
    _files.removeWhere((id, _) => !shown.contains(id));
    _notify();
  }

  /// An AI answer half typed out when the messenger closes: finished at once
  /// if its end has arrived, else dropped — the next open fetches it whole.
  void _settleStream() {
    final id = _streamId;
    if (id == null) return;
    final m = _liveById(id);
    final finalId = _streamFinalId;
    _drip?.cancel();
    _streamId = null;
    _streamFinalId = null;
    if (m != null && finalId != null) {
      m.body += _streamBuffer;
      _finishStream(m, finalId);
    } else {
      live.removeWhere((x) => x.id == id);
    }
    _streamBuffer = '';
  }

  /// The app went to the background or came back (the package's one
  /// lifecycle observer passes it on). Away, nothing counts as read; back,
  /// it reconnects if it has to and fetches what arrived meanwhile.
  void lifecycleChanged(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _appActive = false;
      if (state != AppLifecycleState.inactive) _backgrounded = true;
      _stopVisitorTyping();
      return;
    }
    if (_appActive) return;
    _appActive = true;
    final wasAway = _backgrounded;
    _backgrounded = false;
    if (_suspended || session == null || _disposed) return;
    final ch = _channel;
    if (ch == null) {
      _ensureChannel();
    } else if (!ch.connected) {
      ch.connect();
    }
    // What came while it was away is on the customer's screen now: read.
    if (_seeing && conversations.any((c) => c.id == liveId && c.unreadCount > 0)) unawaited(_markSeen());
    // Back from the background (not just a glance at the control centre):
    // what came without the connection too.
    if (wasAway) unawaited(refresh());
  }

  /// The customer is looking at the live conversation, in an app in front.
  bool get _seeing => viewingLive && _appActive;

  // ======================================================================
  // Realtime
  // ======================================================================

  /// The connection: made if there is none, nudged if it has dropped.
  void _ensureChannel() {
    final ch = _channel;
    if (ch == null) {
      _connect();
    } else if (!ch.connected) {
      ch.connect();
    }
  }

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
        _reauthFailures = 0;
        link = LinkState.connected;
        _notify();
        for (final w in List<Completer<void>>.of(_linkWaiters)) {
          if (!w.isCompleted) w.complete();
        }
        // What arrived while it was not connected. While the loads are out
        // they cover it; after them, a connect may follow a gap.
        if (_loadRun == null) unawaited(refresh());
        unawaited(_pump());
      case 'disconnect':
        link = LinkState.reconnecting;
        agentsOnline = null;
        typingAuthor = null;
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
        final online = n is num ? n.toInt() : null;
        if (online != null) _lastOnline = online;
        if (online == agentsOnline) return; // the same again: nothing to redraw
        agentsOnline = online;
        _notify();
      case 'conversation:seen':
        if (data['seenBy'] == 'agent' && _inLive(data)) {
          final at = DateTime.tryParse('${data['seenAt']}')?.toLocal() ?? agentSeenAt;
          if (at == agentSeenAt) return;
          agentSeenAt = at;
          _notify();
        }
      case 'typing:start':
      case 'typing:stop':
        final who = TypingAuthor.fromJson(data);
        if (who == null || !_inLive(data)) return;
        _agentTypingTimer?.cancel();
        final typing = e.name == 'typing:start';
        if (typing) {
          _agentTypingTimer = Timer(const Duration(seconds: 5), () {
            typingAuthor = null;
            _notify();
          });
        }
        // An agent typing says so again and again: the dots are already
        // there, only their timer moves.
        final author = typing ? who : null;
        if (author == typingAuthor) return;
        typingAuthor = author;
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
    final epoch = _epoch;
    _reauthTimer = Timer(wait, () async {
      final token = await api.reauthenticate?.call();
      if (_disposed || epoch != _epoch) return;
      if (token == null) {
        _reauthFailures++;
        _renewTokenAndReconnect();
        return;
      }
      _channel?.connect();
    });
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
    // Already here (a catch-up brought it first): counted once, drawn once.
    if (msg.conversationId == liveId && _liveById(msg.id) != null) return;
    _touchList(msg);
    liveId ??= msg.conversationId;
    if (msg.conversationId != liveId) {
      _notify();
      return;
    }
    preview = null;
    if (!msg.fromVisitor) {
      typingAuthor = null;
      _agentTypingTimer?.cancel();
      if (_seeing) {
        unawaited(_markSeen());
      } else if (dividerIndex < 0) {
        dividerIndex = live.length;
      }
    }
    // It comes in with a fade — unless it is the server's copy of a bubble
    // already on screen, which simply takes that bubble's place.
    if (!msg.fromVisitor || !outgoing.any((o) => _isCopyOf(msg, o))) _arriving.add(msg);
    live.add(msg);
    _arrivedAfterAll(msg);
    _notify();
  }

  /// One of the customer's messages has reached the thread from the server.
  /// A send that gave up waiting for its answer on the same words (the
  /// connection went, or the phone slept, after it was handed over) was this
  /// one: it arrived after all. Its failed bubble goes, rather than show the
  /// message twice and offer Try again, which would send a second copy.
  void _arrivedAfterAll(ChatMessage m) {
    for (final out in outgoing) {
      if (!out._noAnswer || !out.failed || !_isCopyOf(m, out)) continue;
      outgoing.remove(out);
      if (!outgoing.any((o) => o.failed)) sendError = null;
      return;
    }
  }

  /// [m] is the server's copy of [out]: the customer's, with the same words
  /// and photo, and not an older message that happens to say the same.
  static bool _isCopyOf(ChatMessage m, OutgoingMessage out) {
    if (!m.fromVisitor || bodyBesideFiles(m).trim() != out.text) return false;
    final uploads = m.attachments.map((a) => a.uploadId).whereType<String>();
    if (out.image != null ? !uploads.contains(out.uploadId) : m.attachments.isNotEmpty) return false;
    // The phone's clock and the server's differ a little: a wide margin.
    return !m.createdAt.isBefore(out.createdAt.subtract(const Duration(minutes: 10)));
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
    final onScreen = _seeing && msg.conversationId == liveId;
    if (!msg.fromVisitor && !onScreen) row.unreadCount += 1;
    conversations.sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
    _emitUnread();
  }

  // ---- AI answers, typed out as they stream ---------------------------------

  /// The typewriter's pace: a step every 75 ms, releasing three of
  /// [dripStep]'s 25 ms steps at once. Every step redraws the thread, so 13
  /// a second rather than 40 keeps the phone cool while the AI types, at the
  /// same reading speed.
  static const _dripEvery = Duration(milliseconds: 75);

  void _onStreamStart(Map<String, dynamic> data) {
    if (!_inLive(data)) return;
    final id = data['streamId'];
    if (id is! String || _liveById(id) != null) return;
    typingAuthor = null;
    _agentTypingTimer?.cancel();
    liveId ??= data['conversationId'] as String?;
    final answer = ChatMessage(
      id: id,
      conversationId: liveId ?? '',
      body: '',
      authorType: 'ai',
      authorName: (data['authorName'] as String?) ?? 'AI',
      createdAt: DateTime.tryParse('${data['createdAt']}')?.toLocal() ?? _now(),
    );
    live.add(answer);
    _arriving.add(answer);
    _streamId = id;
    _streamBuffer = '';
    _streamFinalId = null;
    if (!_seeing && dividerIndex < 0) dividerIndex = live.length - 1;
    _notify();
  }

  void _ensureDrip() {
    if (_drip?.isActive ?? false) return;
    _drip = Timer.periodic(_dripEvery, (_) => _dripTick());
  }

  void _dripTick() {
    final id = _streamId;
    final m = id == null ? null : _liveById(id);
    if (m == null) {
      _drip?.cancel();
      return;
    }
    if (_streamBuffer.isNotEmpty) {
      final steps = _dripEvery.inMilliseconds ~/ 25;
      final n = (dripStep(_streamBuffer.length) * steps).clamp(1, _streamBuffer.length);
      m.body += _streamBuffer.substring(0, n);
      _streamBuffer = _streamBuffer.substring(n);
      _notify();
      return;
    }
    final finalId = _streamFinalId;
    if (finalId != null) {
      _streamId = null;
      _streamFinalId = null;
      _drip?.cancel();
      _finishStream(m, finalId);
      _notify();
      return;
    }
    _drip?.cancel();
  }

  /// The typed-out answer takes its real id — or goes, if a catch-up has
  /// already brought the real message.
  void _finishStream(ChatMessage m, String finalId) {
    final real = _liveById(finalId);
    if (real != null && !identical(real, m)) {
      live.remove(m);
      return;
    }
    m.id = finalId;
    _touchList(m);
    if (_seeing) unawaited(_markSeen());
  }

  // ======================================================================
  // What the customer does
  // ======================================================================

  /// The screen showing the live conversation came or went: while it is up,
  /// replies count as read the moment they arrive.
  void setViewingLive(bool viewing) {
    viewingLive = viewing;
    if (viewing) {
      if (_appActive) unawaited(_markSeen());
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

  /// The conversation a tap on "an agent replied" means: the newest one with
  /// replies not yet read (the open one, when only its own count is known),
  /// or null when everything has been read.
  String? get unreadConversationId {
    for (final c in conversations) {
      if (c.unreadCount > 0) return c.id;
    }
    return liveId != null && dividerIndex >= 0 && !viewingLive ? liveId : null;
  }

  int _lastUnread = -1;

  void _emitUnread() {
    if (_disposed) return; // never a count for the customer before on the badge
    final n = totalUnread;
    if (n == _lastUnread) return;
    _lastUnread = n;
    onUnreadChanged?.call(n);
  }

  /// Send what they typed, and/or a photo — at any time, connected or not.
  /// The bubble shows at once; while the connection is not up it waits
  /// ([OutgoingMessage.queued]) and goes as soon as it is, in the order
  /// written, never twice. If the server refuses it, the bubble says so and
  /// [retry] sends it again. Completes with whether it was delivered.
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
    _arriving.add(out);
    return _enqueue(out);
  }

  Future<bool> retry(OutgoingMessage out) {
    if (!outgoing.contains(out)) return Future<bool>.value(false);
    for (final job in _queue) {
      if (identical(job.out, out)) return job.done.future; // already on its way
    }
    return _enqueue(out);
  }

  void discard(OutgoingMessage out) {
    outgoing.remove(out);
    // Still waiting its turn: it never goes. One already handed over cannot
    // be taken back; it shows as sent when the server confirms it.
    final sending = _delivering && _queue.isNotEmpty ? _queue.first : null;
    final waiting = _queue.where((j) => identical(j.out, out) && !identical(j, sending)).toList();
    for (final job in waiting) {
      _queue.remove(job);
      if (!job.done.isCompleted) job.done.complete(false);
    }
    _notify();
  }

  Future<bool> _enqueue(OutgoingMessage out) {
    final job = _Send(out);
    out
      ..error = null
      ..queued = true;
    sendError = null;
    _queue.add(job);
    _notify();
    unawaited(_pump());
    return job.done.future;
  }

  /// Send what is waiting, first written first, one at a time, while the
  /// connection is up. A message is handed to the connection only while it
  /// is connected: Socket.IO would otherwise hold it and send it on the next
  /// connect, after the customer had been told it failed — a second copy on
  /// Try again.
  Future<void> _pump() async {
    if (_delivering) return;
    final epoch = _epoch;
    _delivering = true;
    try {
      while (_queue.isNotEmpty && connected && _channel != null && !_disposed && epoch == _epoch) {
        final job = _queue.first;
        final delivered = await _deliver(job.out, epoch);
        if (epoch != _epoch || _disposed) return; // a reset settled every job
        if (delivered == null) break; // the connection went first: it stays first in line
        _queue.remove(job);
        if (!job.done.isCompleted) job.done.complete(delivered);
      }
    } finally {
      if (epoch == _epoch) _delivering = false;
    }
    if (epoch == _epoch) _closeWhenIdle();
  }

  /// True when the server took it, false when it refused (the bubble says
  /// why), null when the connection went before it could be handed over.
  Future<bool?> _deliver(OutgoingMessage out, int epoch) async {
    out
      ..queued = false
      ..error = null
      .._noAnswer = false;
    sendError = null;
    _notify();
    try {
      final image = out.image;
      if (image != null && out.uploadId == null) {
        final up = await api.upload(image, name: out.imageName ?? 'photo.jpg', contentType: out.imageType ?? 'image/jpeg');
        if (epoch != _epoch) return false;
        out.uploadId = up.id;
        _files[up.id] = Future<Uint8List>.value(image); // no need to download what we just sent
      }
      final ch = _channel;
      if (ch == null || !connected) {
        out.queued = true;
        _notify();
        return null;
      }
      final before = live.map((m) => m.id).toSet();
      final ack = await ch.request('visitor:message', <String, dynamic>{
        'body': out.text,
        if (out.uploadId != null) 'attachments': <String>[out.uploadId!],
      });
      if (epoch != _epoch) return false;
      // No answer, but the server's copy came while waiting for one: it went.
      if (ack['error'] == 'timeout' && live.any((m) => !before.contains(m.id) && _isCopyOf(m, out))) {
        outgoing.remove(out);
        _notify();
        return true;
      }
      if (ack['ok'] == true && ack['message'] is Map) {
        final msg = ChatMessage.fromJson(Map<String, dynamic>.from(ack['message'] as Map));
        outgoing.remove(out);
        // The server put it in its open conversation: that is the live one
        // now, even if the one shown had been closed meanwhile.
        if (msg.conversationId.isNotEmpty) liveId = msg.conversationId;
        preview = null;
        if (_liveById(msg.id) == null) {
          live.add(msg);
          _touchList(msg);
        }
        _notify();
        return true;
      }
      out
        ..error = sendFailureText(ack['error'])
        .._noAnswer = ack['error'] == 'timeout';
    } on ApiException catch (e) {
      if (epoch != _epoch) return false;
      out.error = e.status == 0 ? 'No connection — check your signal and try again.' : e.message;
    } catch (_) {
      if (epoch != _epoch) return false;
      out.error = sendFailureText(null); // never a message stuck at the head of the line
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

  /// The customer is typing (for the team's "typing…"). Keeps [draft] too:
  /// the composer empties it when it sends, as only what it sends was the
  /// draft (a chip tapped meanwhile leaves it as typed).
  void composerChanged(String text) {
    draft = text;
    final id = liveId;
    final ch = _channel;
    // Not while connecting: Socket.IO would hold it and say "typing" late.
    if (id == null || ch == null || !connected) return;
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

  /// The connection once it is up — waiting up to [timeout] for it — or null.
  /// So a button tapped while it connects is sent then, rather than dropped,
  /// or held by Socket.IO past the point the customer was told it failed.
  Future<RealtimeChannel?> _whenConnected({Duration timeout = const Duration(seconds: 20)}) async {
    if (connected && _channel != null) return _channel;
    final epoch = _epoch;
    final waiter = Completer<void>();
    _linkWaiters.add(waiter);
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      // not connected in time: the caller says so
    } finally {
      _linkWaiters.remove(waiter);
    }
    if (epoch != _epoch || _disposed || !connected) return null;
    return _channel;
  }

  static const _notConnected = 'No connection — check your signal and try again.';

  void _releaseWaiting() {
    final jobs = List<_Send>.of(_queue);
    _queue.clear();
    for (final job in jobs) {
      if (!job.done.isCompleted) job.done.complete(false);
    }
    final waiters = List<Completer<void>>.of(_linkWaiters);
    _linkWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) w.complete();
    }
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
    // Until the open conversation is in (the first open), nobody knows yet
    // whether the workflow lets the customer type.
    if (!liveLoaded) return 'Loading…';
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
    if (p == null || flowBusy) return;
    final epoch = _epoch;
    flowBusy = true;
    flowNotice = null;
    _notify();
    final ch = await _whenConnected();
    if (epoch != _epoch) return;
    if (ch == null) {
      flowBusy = false;
      flowNotice = _notConnected;
      _notify();
      return;
    }
    final ack = await ch.request('workflow:start', <String, dynamic>{'workflowId': p.workflowId, 'buttonId': button.id});
    if (epoch != _epoch) return;
    flowBusy = false;
    if (ack['ok'] == true) {
      liveId = (ack['conversationId'] as String?) ?? liveId;
      preview = null;
    } else {
      switch (ack['error']) {
        case 'already_in_conversation':
          preview = null;
          await refresh();
        case 'workflow_changed':
        case 'workflow_invalid':
        case 'unknown_button':
          await _loadPreview(epoch);
        default:
          flowNotice = flowFailed(ack['error']);
      }
    }
    _notify();
  }

  /// A button under a bot question in the thread.
  Future<void> choose(ChatMessage prompt, FlowButton button) async {
    final id = liveId;
    if (id == null || flowBusy) return;
    final epoch = _epoch;
    flowBusy = true;
    flowNotice = null;
    _notify();
    final ch = await _whenConnected();
    if (epoch != _epoch) return;
    if (ch == null) {
      flowBusy = false;
      flowNotice = _notConnected;
      _notify();
      return;
    }
    final ack = await ch.request('workflow:choose', <String, dynamic>{'conversationId': id, 'promptId': prompt.id, 'buttonId': button.id});
    if (epoch != _epoch) return;
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
    final id = liveId;
    final v = value.trim();
    if (id == null || flowBusy || v.isEmpty) return false;
    final epoch = _epoch;
    flowBusy = true;
    collectError = null;
    flowNotice = null;
    _notify();
    final ch = await _whenConnected();
    if (epoch != _epoch) return false;
    if (ch == null) {
      flowBusy = false;
      collectError = _notConnected;
      _notify();
      return false;
    }
    final ack = await ch.request('workflow:collect', <String, dynamic>{'conversationId': id, 'promptId': prompt.id, 'value': v});
    if (epoch != _epoch) return false;
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
    final epoch = _epoch;
    final before = csat[ratingId];
    final first = before?.rating == null;
    final answer = before ?? CsatAnswer();
    answer
      ..rating = rating
      ..error = null;
    csat[ratingId] = answer;
    _notify();
    final ch = await _whenConnected();
    if (epoch != _epoch) return;
    final ack = await (ch?.request('csat:rate', <String, dynamic>{'ratingId': ratingId, 'rating': rating}) ??
        Future<Map<String, dynamic>>.value(<String, dynamic>{'ok': false, 'error': 'not_connected'}));
    if (epoch != _epoch) return;
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
    final epoch = _epoch;
    answer!
      ..commentState = 'sending'
      ..error = null;
    _notify();
    final ch = await _whenConnected();
    if (epoch != _epoch) return;
    final ack = await (ch?.request('csat:rate', <String, dynamic>{'ratingId': ratingId, 'rating': answer.rating, 'comment': t}) ??
        Future<Map<String, dynamic>>.value(<String, dynamic>{'ok': false}));
    if (epoch != _epoch) return;
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

  /// From the last count the server sent, while a reconnect or a reopen
  /// waits for the next: the form stays put rather than go and come back.
  /// (The header's line uses only the live count.)
  bool get showEmailBar => (agentsOnline ?? _lastOnline) == 0 && (visitorEmail ?? '').isEmpty || emailSavedFor != null;

  /// Null when saved; otherwise what to tell the customer.
  Future<String?> leaveEmail(String email) async {
    final e = email.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(e)) return 'Enter a valid email address.';
    final epoch = _epoch;
    try {
      await api.leaveEmail(e);
    } on ApiException catch (err) {
      return err.status == 0 ? 'No connection — try again.' : err.message;
    }
    if (epoch != _epoch) return null;
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
    final epoch = _epoch;
    final d = await api.conversation(id);
    // Someone else signed in while it loaded: not theirs to see.
    if (epoch != _epoch) throw const ApiException(401, 'Signed out');
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
    final epoch = _epoch;
    try {
      final r = await api.articles();
      if (epoch != _epoch) return;
      articles = r.articles;
      helpUrl = r.helpUrl;
    } catch (_) {
      if (epoch != _epoch) return;
      if (!articlesLoaded) articles = <ArticleSummary>[]; // a failed refresh keeps the list from before
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

  /// Tell the screens — at most once a frame for what happens between
  /// frames. Each change used to redraw the whole messenger on its own; an
  /// AI answer typing out, a burst of catch-up messages or a run of presence
  /// updates now redraw it once per frame, however many changes came in it.
  void _notify() {
    if (_disposed || !hasListeners) return;
    SchedulerBinding? frames;
    try {
      frames = SchedulerBinding.instance;
    } catch (_) {
      frames = null; // no Flutter binding (a plain unit test): tell them now
    }
    if (frames == null) {
      notifyListeners();
      return;
    }
    switch (frames.schedulerPhase) {
      case SchedulerPhase.idle:
        // A socket event, a timer, a reply: everything until the next frame
        // is one redraw.
        if (_frameCallback != null) return;
        _frameCallback = frames.scheduleFrameCallback((_) {
          _frameCallback = null;
          if (!_disposed) notifyListeners();
        });
      case SchedulerPhase.persistentCallbacks:
        // Mid-build (a screen closing): once this frame is done, as the tree
        // cannot be marked for another build while it is being built.
        if (_afterFrame) return;
        _afterFrame = true;
        frames.addPostFrameCallback((_) {
          _afterFrame = false;
          if (!_disposed) notifyListeners();
        });
      case SchedulerPhase.transientCallbacks:
      case SchedulerPhase.midFrameMicrotasks:
      case SchedulerPhase.postFrameCallbacks:
        notifyListeners(); // a build is still to come, or may be asked for
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++; // whatever is still on its way (a load after a sign-out) lands nowhere
    final pending = _frameCallback;
    if (pending != null) {
      try {
        SchedulerBinding.instance.cancelFrameCallbackWithId(pending);
      } catch (_) {
        // no binding: nothing was scheduled with it
      }
      _frameCallback = null;
    }
    _stopVisitorTyping();
    _closeChannel();
    _idleTimer?.cancel();
    _agentTypingTimer?.cancel();
    _drip?.cancel();
    _emailThanks?.cancel();
    _releaseWaiting();
    super.dispose();
  }
}

/// Fetch a picture into Flutter's image cache, where `Image.network` finds
/// it at once. Quietly: a picture that does not load is drawn as the
/// initial it stands for. Nothing without a Flutter binding (a plain test).
void precacheNetworkImage(String url) {
  try {
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (_, __) => stream.removeListener(listener),
      onError: (_, __) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  } catch (_) {
    // no image cache here: the screens fetch it when they draw it
  }
}
