import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api/client.dart';
import 'api/models.dart';
import 'api/realtime.dart';
import 'core/controller.dart';
import 'core/look.dart';
import 'core/session_store.dart';
import 'device.dart';
import 'fallback.dart';
import 'links.dart';
import 'messenger_page.dart';

/// Something worth recording happened. Forward it to Crashlytics, Sentry or
/// your logs, so "support did not open" is a number you can see rather than
/// a complaint you hear about.
///
/// Events and their detail:
/// - `messenger_ready`   `{ms}` — signed in and on screen, from opening the messenger (`cached: true` when it opened on what it had — a reopen, or Home fetched ahead after [GLSupportChat.login] — once it has refreshed)
/// - `messenger_failed`  `{reason, detail}` — `network` or `http_<status>`; the customer saw the fallback screen
/// - `auth_failed`       `{status, detail, failures}` — the badge / push calls, not the messenger itself
/// - `identity_rejected` `{code}` — the backend's signature was refused; the customer is anonymous until fixed
typedef GLSupportChatDiagnostics = void Function(String event, Map<String, Object?> detail);

/// The signed identity your backend returns for the signed-in user — the
/// same object the website passes as `data-identity`. Never build the hash
/// in the app: the secret must stay on the server.
///
/// An identity is **verified** when it has a [hash] your backend made: the
/// server can check it. Without a [hash] it is **unverified**: it is still
/// sent, as the same `identity` object without a `hash`, and it is up to the
/// server whether to show it as unverified or ignore it. GL Support Chat
/// refuses it: the chat opens anonymously and [GLSupportChat.login] returns
/// false.
class GLSupportChatIdentity {
  const GLSupportChatIdentity({
    required this.id,
    this.hash,
    this.email,
    this.phone,
    this.name,
    this.type,
    this.extra = const <String, String>{},
  });

  /// GL Admin id of the customer.
  final String id;
  final String? email;
  final String? phone;
  final String? name;

  /// `learner` · `employer` · `trainer_partner`
  final String? type;

  /// HMAC-SHA256 hex over `id|email|phone|type|name` with the chatbot's
  /// identity secret (see "The identity" in the README). `null` for an
  /// unverified identity.
  final String? hash;

  /// Any other details that came with the identity (for example
  /// `booking_first_name` or `model`): what an app sent Intercom as custom
  /// attributes. Sent inside the `identity` object next to the six known
  /// fields. They are never part of the signature, so the server cannot
  /// trust them. Add your own with [withExtra].
  final Map<String, String> extra;

  /// True when your backend signed it.
  bool get isVerified => hash != null && hash!.isNotEmpty;

  /// Accepts what a Laravel backend really sends: a numeric `id`, and `null`
  /// or "" for fields it does not have. A missing or empty `hash` makes an
  /// unverified identity. Keys other than the six known ones are kept in
  /// [extra], by the rules of [withExtra]. Throws [FormatException] when
  /// there is no id — use [tryParse] to get `null` instead.
  factory GLSupportChatIdentity.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final hash = json['hash'];
    final idText = id == null ? '' : '$id'.trim();
    if (idText.isEmpty) {
      throw const FormatException('an identity needs an id');
    }
    // Not trimmed: the six are signed exactly as the backend sent them.
    String? text(Object? v) {
      if (v == null) return null;
      final s = v is String ? v : '$v';
      return s.isEmpty ? null : s;
    }

    return GLSupportChatIdentity(
      id: idText,
      hash: hash is String && hash.isNotEmpty ? hash : null,
      email: text(json['email']),
      phone: text(json['phone']),
      name: text(json['name']),
      type: text(json['type']),
      extra: _mergeExtra(const <String, String>{}, json),
    );
  }

  static const Set<String> _knownKeys = <String>{'id', 'hash', 'email', 'phone', 'name', 'type'};

  /// ` email` or `Name` is one of the signed fields, not a detail: never kept
  /// or sent as one.
  static bool _isKnownKey(String key) => _knownKeys.contains(key.trim().toLowerCase());

  /// A copy with [more] added to [extra] (a key already there takes the new
  /// value) — the app's own details, such as the custom attributes it sent
  /// Intercom, added without touching the six signed fields, so the
  /// signature still holds. This identity is left as it was.
  ///
  /// Keys are trimmed; one of the six (in any case) is ignored. Values are
  /// sent as text: a number or a boolean as written, a list or a map as its
  /// JSON. A `null` or blank value is ignored, so the detail keeps what it
  /// had.
  GLSupportChatIdentity withExtra(Map<String, Object?> more) => GLSupportChatIdentity(
        id: id,
        hash: hash,
        email: email,
        phone: phone,
        name: name,
        type: type,
        extra: _mergeExtra(extra, more),
      );

  static Map<String, String> _mergeExtra(Map<String, String> into, Map<String, Object?> more) {
    final out = Map<String, String>.of(into);
    more.forEach((key, value) {
      final k = key.trim();
      if (k.isEmpty || _isKnownKey(k)) return;
      final v = _extraText(value);
      if (v != null) out[k] = v;
    });
    return out;
  }

  static String? _extraText(Object? value) {
    if (value == null) return null;
    String text;
    if (value is String) {
      text = value;
    } else if (value is Map || value is Iterable) {
      try {
        // "{a: 1}" is Dart's, not something the team can read; a set is a list.
        text = jsonEncode(value is Iterable ? value.toList() : value, toEncodable: (o) => o is Iterable ? o.toList() : '$o');
      } catch (_) {
        return null; // a map that contains itself: left out, never a crash
      }
    } else {
      text = '$value';
    }
    return text.trim().isEmpty ? null : text;
  }

  /// [fromJson], or `null` for anything that is not a usable identity — so a
  /// missing or odd `support_identity` can never crash the app's sign-in.
  static GLSupportChatIdentity? tryParse(Object? json) {
    if (json is! Map) return null;
    try {
      return GLSupportChatIdentity.fromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  /// [extra], then the six fields (`hash` only when there is one). An extra
  /// key can never replace one of the six.
  Map<String, dynamic> toJson() => {
        for (final e in extra.entries)
          if (!_isKnownKey(e.key)) e.key: e.value,
        'id': id,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
        if (type != null) 'type': type,
        if (name != null) 'name': name,
        if (hash != null) 'hash': hash,
      };
}

/// Entry point. All members are static: one messenger per app.
///
/// Nothing here throws into the app or blocks it: every network call has a
/// timeout, failures are reported through `onDiagnostic`, and the messenger
/// screen always offers the customer a way to reach the team.
class GLSupportChat {
  GLSupportChat._();

  static MessengerApi? _api;
  static String? _productId;
  static String? _appId;
  static GLSupportChatDevice? _device;
  static GLSupportChatIdentity? _identity;
  static String? _pushToken;
  static String? _pushPlatform;
  static Timer? _pollTimer;
  static Duration _pollInterval = const Duration(seconds: 30);
  static final StreamController<int> _unread = StreamController<int>.broadcast();
  static int _lastUnread = 0;
  static GLSupportChatFallback _fallback = const GLSupportChatFallback();
  static GLSupportChatDiagnostics? _diagnostics;
  static int _authFailures = 0;
  static DateTime? _authPausedUntil;
  static _Lifecycle? _lifecycle;
  static bool _foreground = true;
  static Future<MessengerSession>? _signingIn;

  /// The messenger's state for the customer signed in now, kept between
  /// opens so the next one shows it at once. Dropped — at once — by
  /// [logout] and by a [login] as someone else.
  static MessengerController? _controller;

  /// While the messenger is on screen: done when it closes. A [present]
  /// meanwhile goes to the screen asked for through [_requests].
  static Future<void>? _shown;
  static MessengerRequests? _requests;

  /// Moves on at every [login] and [logout]: whose sign-in is whose. A
  /// sign-in is shared only with callers of the same generation.
  static int _generation = 0;
  static int _signingInFor = 0;

  /// The last sign-in that worked, and for whom: the messenger opened just
  /// after it takes it rather than sign in again ([_messengerSignIn]).
  static ({MessengerApi api, int generation, DateTime at, MessengerSession session})? _lastSignIn;

  static SessionStore _store = const PrefsSessionStore();

  /// How each chatbot looked at its last sign-in, by product id: the
  /// messenger's skeleton is drawn in it while it signs in. Read from the
  /// store at [configure], written there when it changes.
  static final Map<String, MessengerLook> _looks = <String, MessengerLook>{};
  static http.Client? _httpClient;
  static RealtimeFactory _realtime = socketIoChannel;

  /// Unread replies for the badge. Polled every 30 s while the app is in the
  /// foreground and a customer is signed in, and live while the messenger is open.
  static Stream<int> get unreadCount => _unread.stream;

  /// Last value emitted by [unreadCount].
  static int get currentUnread => _lastUnread;

  static bool get isConfigured => _api != null;
  static bool get isLoggedIn => _identity != null;

  /// Call once at startup. [productId] is the chatbot for THIS app (each app
  /// has its own: branding, articles and suggested questions differ).
  ///
  /// [fallback] is what the customer is offered if the chat cannot load —
  /// set the real WhatsApp number and phone once they are known.
  /// [onDiagnostic] receives failures worth logging (see
  /// [GLSupportChatDiagnostics]). [device] — OS, model, app version — is
  /// shown to the team on each conversation (see [GLSupportChatDevice]).
  static Future<void> configure({
    required String apiUrl,
    required String productId,
    String? appId,
    GLSupportChatDevice? device,
    Duration unreadPollInterval = const Duration(seconds: 30),
    GLSupportChatFallback fallback = const GLSupportChatFallback(),
    GLSupportChatDiagnostics? onDiagnostic,
  }) async {
    _api?.close();
    _api = MessengerApi(apiUrl: apiUrl, productId: productId.trim(), client: _httpClient)
      ..reauthenticate = _renewToken;
    _lastSignIn = null;
    // What the messenger held was fetched through the API before (perhaps
    // another chatbot's). On screen, the next present() replaces it.
    final kept = _controller;
    if (kept != null && !_onScreen()) {
      _controller = null;
      kept.dispose();
    }
    _productId = productId.trim();
    _appId = appId;
    _device = device;
    _pollInterval = unreadPollInterval;
    _fallback = fallback;
    _diagnostics = onDiagnostic;
    WidgetsFlutterBinding.ensureInitialized();
    _lifecycle ??= _Lifecycle()..attach();
    _startPolling();
    final product = productId.trim();
    if (!_looks.containsKey(product)) {
      unawaited(_store.look(product).then((j) {
        final look = MessengerLook.fromJson(j);
        if (look != null) _looks.putIfAbsent(product, () => look);
      }).catchError((Object _) {}));
    }
  }

  /// The user signed in: from now on the messenger and the badge are theirs.
  /// Registers the push token too, if one was given before. Their anonymous
  /// chat on this phone, if any, becomes part of their history. What Home
  /// shows (their conversations, the top articles, the team's faces) is
  /// fetched in the background, without going live, so [present] opens on
  /// it at once.
  ///
  /// Every call sends the identity, and the server updates the customer's
  /// contact with it (name, email, phone, and the [GLSupportChatIdentity.extra]
  /// details), as Intercom did at every login. Call it again whenever those
  /// may have changed — at app start, after a profile refresh, before
  /// [present]. The last call wins, even while an earlier sign-in is still out.
  ///
  /// Never throws and never blocks your sign-in for more than a few seconds.
  /// Returns false when the server refused the identity (the messenger then
  /// opens anonymously, and `identity_rejected` says why) or could not be
  /// reached right now (the badge catches up on its own).
  static Future<bool> login(GLSupportChatIdentity identity) async {
    final someoneElse = _identity?.id != identity.id;
    _identity = identity;
    _generation++;
    _lastSignIn = null;
    _api?.token = null;
    // The same customer again (fresh details before present): what the
    // messenger holds is still theirs. Anyone else: it goes now.
    if (someoneElse) _forgetMessenger();
    _authFailures = 0;
    _authPausedUntil = null;
    try {
      final session = await _authenticateInBackground();
      if (session == null) return false;
      // Home's data, fetched now: the messenger opens on it at once.
      _prefetchMessenger();
      final token = _pushToken;
      final platform = _pushPlatform;
      if (token != null && platform != null) await registerPushToken(token, platform: platform);
      await refreshUnread();
      return session.identified;
    } catch (_) {
      return false;
    }
  }

  /// The user signed out: forget the identity, detach the device, and start
  /// the next customer on this phone as a new anonymous visitor. Returns at
  /// once; detaching the push token finishes in the background.
  static Future<void> logout() async {
    final api = _api;
    final push = _pushToken;
    final bearer = api?.token;
    _identity = null;
    _generation++;
    _lastSignIn = null;
    // Their conversations, messages and draft go now, not at the next open.
    _forgetMessenger(restart: false);
    _authFailures = 0;
    _authPausedUntil = null;
    _emitUnread(0);
    if (api != null && push != null && bearer != null) {
      unawaited(api.unregisterPushToken(push).catchError((Object _) {}));
    }
    api?.token = null;
    final product = _productId;
    if (product != null) await _store.forget(product);
    // On screen, it starts again only now: as a new anonymous visitor, not
    // with the visitor id just forgotten.
    final open = _controller;
    if (open != null && open.phase == MessengerPhase.loading && _onScreen()) unawaited(open.start());
  }

  /// Someone else now, or nobody: the messenger's conversations, messages,
  /// draft and unsent messages go at once. On screen it is wiped and, with
  /// [restart], starts again for whoever is signed in; otherwise it is gone.
  static void _forgetMessenger({bool restart = true}) {
    final c = _controller;
    if (c == null) return;
    if (_onScreen()) {
      c.reset();
      if (restart) unawaited(c.start());
      return;
    }
    _controller = null;
    c.dispose();
  }

  /// Register (or refresh) this install's FCM token so agent replies reach
  /// the phone while the messenger is closed. Safe to call before [login];
  /// it is sent as soon as there is a user. Never throws.
  static Future<void> registerPushToken(String token, {required String platform}) async {
    _pushToken = token;
    _pushPlatform = platform;
    final api = _api;
    if (_identity == null || api == null) return;
    final generation = _generation;
    if (api.token == null && await _authenticateInBackground() == null) return;
    // Signed out, or someone else signed in, meanwhile: that login registers it.
    if (generation != _generation) return;
    try {
      await api.registerPushToken(token, platform: platform, appId: _appId);
    } catch (_) {
      // the next login retries
    }
  }

  /// Fetch the badge count now (e.g. on app resume). Never throws.
  static Future<int> refreshUnread() async {
    final api = _api;
    if (api == null || _identity == null) return _lastUnread;
    final open = _controller;
    if (open != null && open.phase == MessengerPhase.ready && _onScreen()) return _lastUnread; // the open messenger counts live
    final generation = _generation;
    try {
      if (api.token == null && await _authenticateInBackground() == null) return _lastUnread;
      // Signed out, or someone else signed in, meanwhile: not their count to show.
      if (generation != _generation) return _lastUnread;
      final n = await api.unread();
      if (generation != _generation) return _lastUnread;
      _emitUnread(n);
      return n;
    } catch (_) {
      return _lastUnread;
    }
  }

  /// Open the messenger full-screen. [screen] picks the first view.
  ///
  /// Always opens something useful: the messenger, or — if it cannot sign
  /// in, or [configure] was never called — a screen with Try again and the
  /// [GLSupportChatFallback] contacts. Opened again for the same customer it
  /// shows at once what it had, and refreshes behind it. Called while it is
  /// already open (a push tapped), it goes to [screen] in the messenger that
  /// is up rather than opening a second one; the future is that one's.
  static Future<void> present(BuildContext context, {GLSupportChatScreen screen = GLSupportChatScreen.home}) async {
    final api = _api;
    final shown = _shown;
    if (api != null && shown != null && _onScreen()) {
      _requests?.go(screen);
      return shown;
    }
    final controller = api == null ? null : _messengerFor(api);
    String? browserUrl;
    if (api != null) {
      try {
        browserUrl = buildMessengerUrl(apiUrl: api.apiUrl, productId: api.productId, start: webStart(screen));
      } catch (_) {
        browserUrl = null; // an unusable apiUrl: no browser option, not a crash
      }
    }
    final requests = MessengerRequests();
    final page = GLSupportChatPage(controller: controller, screen: screen, fallback: _fallback, browserUrl: browserUrl, requests: requests);
    final route = messengerRoute(page, reduceMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false);
    final closed = Completer<void>();
    if (controller != null) {
      _shown = closed.future;
      _requests = requests;
    }
    try {
      // Closed — or gone without being closed, when the app's navigator is
      // torn down under it: then the route's future never completes.
      await Future.any<void>(<Future<void>>[Navigator.of(context, rootNavigator: true).push(route), requests.gone]);
    } finally {
      // The controller stays for the next open; the page lets it go quiet
      // (detach) when it has gone.
      if (identical(_shown, closed.future)) _forgetShown();
      closed.complete();
    }
  }

  /// The messenger kept for the customer signed in now, made if there is
  /// none (or it was made through an API since replaced), in the chatbot's
  /// last look until it has signed in.
  static MessengerController _messengerFor(MessengerApi api) {
    var c = _controller;
    if (c == null || !identical(c.api, api)) {
      c?.dispose();
      c = MessengerController(api: api, signIn: _messengerSignIn, realtimeFactory: _realtime, onDiagnostic: _diag, onUnreadChanged: _emitUnread);
      _controller = c;
    }
    if (c.session == null) {
      c.look = _looks[api.productId] ?? c.look;
      final identity = _identity;
      c.lookName = identity != null && identity.isVerified ? identity.name : null;
    }
    return c;
  }

  /// After a [login]: sign the messenger in and fetch what Home shows, in
  /// the background and without going live, so [present] shows Home at
  /// once. Not while it is on screen: it is live and keeps itself up to date.
  static void _prefetchMessenger() {
    final api = _api;
    if (api == null || _identity == null || _onScreen()) return;
    unawaited(_messengerFor(api).prefetch());
  }

  /// The messenger is up. A navigator can go without closing it (the app
  /// rebuilt its MaterialApp): then its page has gone, and the next [present]
  /// opens a new one rather than talk to a page that is not there.
  static bool _onScreen() => _shown != null && !(_requests?.isGone ?? true);

  static void _forgetShown() {
    _shown = null;
    _requests = null;
  }

  /// Help centre, straight in.
  static Future<void> presentHelp(BuildContext context) => present(context, screen: GLSupportChatScreen.help);

  /// One article, by its slug (the dashboard shows slugs on each article).
  static Future<void> presentArticle(BuildContext context, String slug) =>
      present(context, screen: GLSupportChatScreen.article(slug));

  /// The hosted web messenger for the current user — for opening support in
  /// a browser. The identity travels in the fragment (`#identity=…`), never
  /// the query. Throws [StateError] before [configure].
  static String messengerUrl({GLSupportChatScreen screen = GLSupportChatScreen.home}) {
    final api = _api;
    if (api == null) throw StateError('GLSupportChat.configure() has not been called');
    return buildMessengerUrl(apiUrl: api.apiUrl, productId: api.productId, start: webStart(screen), identity: _identity?.isVerified == true ? _identity!.toJson() : null);
  }

  /// The messenger state kept for the customer signed in now — for tests.
  @visibleForTesting
  static MessengerController? get debugMessenger => _controller;

  /// Forget the customer, the kept messenger and any sign-in still out —
  /// for tests, so one that failed half way leaves nothing for the next.
  @visibleForTesting
  static void debugReset() {
    _identity = null;
    _generation++;
    _signingIn = null;
    _lastSignIn = null;
    _forgetShown();
    _controller?.dispose();
    _controller = null;
    _looks.clear();
    _authFailures = 0;
    _authPausedUntil = null;
  }

  /// Replace the HTTP client, the session store or the live connection —
  /// for tests. Call before [configure].
  @visibleForTesting
  static void debugOverride({http.Client? client, SessionStore? store, RealtimeFactory? realtime}) {
    _httpClient = client;
    if (store != null) _store = store;
    if (realtime != null) _realtime = realtime;
  }

  // ------------------------------------------------------------------

  /// Sign the visitor in: their identity if they are signed in to the app,
  /// and the visitor id this phone has kept for this chatbot. One at a time —
  /// the badge, the push token and the messenger may all ask at once, and
  /// share the sign-in that is out. A [login] or [logout] since it started
  /// does not share it (it carries the customer before): it waits for it to
  /// finish, worked or not, then signs in afresh. In that order the last
  /// sign-in to start is the last to finish, so its token is the one kept.
  static Future<MessengerSession> _signIn() {
    final pending = _signingIn;
    final generation = _generation;
    if (pending != null && _signingInFor == generation) return pending;
    final identity = _identity;
    final run = pending == null
        ? _doSignIn(generation, identity)
        : pending.then<void>((_) {}, onError: (Object _) {}).then((_) => _doSignIn(generation, identity));
    _signingIn = run;
    _signingInFor = generation;
    return run.whenComplete(() {
      if (identical(_signingIn, run)) _signingIn = null;
    });
  }

  static Future<MessengerSession> _doSignIn(int generation, GLSupportChatIdentity? identity) async {
    final api = _api!;
    final product = api.productId;
    final stored = await _store.visitorId(product);
    final device = (_device ?? const GLSupportChatDevice()).toJson(appId: _appId);
    final session = await api.authenticate(
      visitorId: stored,
      identity: identity?.toJson(),
      device: device.isEmpty ? null : device,
      onIdentityRejected: (code, _) => _diag('identity_rejected', <String, Object?>{'code': code}),
    );
    if (generation != _generation) {
      // A login or logout came while this was out: the token is the customer
      // before's, so nothing more goes out with it (the sign-in queued behind
      // this one brings the right one), and the visitor id is not kept —
      // logout() forgot it on purpose.
      api.token = null;
      return session;
    }
    if (session.visitorId.isNotEmpty && session.visitorId != stored) await _store.saveVisitorId(product, session.visitorId);
    final look = MessengerLook.of(session);
    if (!look.same(_looks[product])) {
      _looks[product] = look;
      unawaited(_store.saveLook(product, look.toJson()).catchError((Object _) {}));
    }
    _authFailures = 0;
    _authPausedUntil = null;
    if (generation == _generation) _lastSignIn = (api: api, generation: generation, at: DateTime.now(), session: session);
    return session;
  }

  /// The messenger's sign-in. Opened (or fetching ahead) for the first time
  /// just after a sign-in for the same customer worked — `login` before
  /// `present`, as the README recommends — it takes that session rather
  /// than ask the server again: a round trip less before Home shows. Only
  /// within a minute, as the session carries the office hours; never on a
  /// reopen, which already shows what it has and needs the server's fresh
  /// word (an email left since, say); and never for a token the server
  /// refused, which [_renewToken] renews through [_signIn].
  static Future<MessengerSession> _messengerSignIn() {
    final last = _lastSignIn;
    final api = _api;
    final c = _controller;
    final fresh = c == null || c.session == null || (!c.wasOpened && identical(c.session, last?.session));
    if (last != null &&
        api != null &&
        fresh &&
        identical(last.api, api) &&
        last.generation == _generation &&
        api.token == last.session.token &&
        DateTime.now().difference(last.at) < const Duration(minutes: 1)) {
      return Future<MessengerSession>.value(last.session);
    }
    return _signIn();
  }

  /// A 401 mid-session (the 24-hour token ran out): sign in again. The token
  /// the API holds afterwards, not the session's: if the customer changed
  /// while it was out, there is none yet rather than the one before's.
  static Future<String?> _renewToken() async {
    try {
      await _signIn();
      return _api?.token;
    } catch (_) {
      return null;
    }
  }

  /// Sign-in for the badge and push calls, which run without the customer
  /// looking: the session, or null. Backs off after failures (30 s doubling
  /// to 10 min) so a broken signature or an outage never turns every app on
  /// every phone into a retry loop.
  static Future<MessengerSession?> _authenticateInBackground() async {
    if (_api == null) return null;
    final pausedUntil = _authPausedUntil;
    if (pausedUntil != null && DateTime.now().isBefore(pausedUntil)) return null;
    try {
      return await _signIn();
    } on ApiException catch (e) {
      _authFailed(e.status, e.message);
      return null;
    } catch (e) {
      _authFailed(0, '$e');
      return null;
    }
  }

  static void _authFailed(int status, String detail) {
    _authFailures++;
    _authPausedUntil = DateTime.now().add(authBackoff(_authFailures));
    _diag('auth_failed', <String, Object?>{
      'status': status,
      'detail': detail.length > 200 ? detail.substring(0, 200) : detail,
      'failures': _authFailures,
    });
  }

  static void _onLifecycle(AppLifecycleState state) {
    // The messenger, open or kept: away, nothing counts as read; back, it catches up.
    _controller?.lifecycleChanged(state);
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (foreground) {
      _startPolling();
      unawaited(refreshUnread());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  static void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_foreground || _api == null) return;
    _pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(refreshUnread()));
  }

  static void _emitUnread(int n) {
    if (n == _lastUnread) return;
    _lastUnread = n;
    if (!_unread.isClosed) _unread.add(n);
  }

  static void _diag(String event, Map<String, Object?> detail) {
    final handler = _diagnostics;
    if (handler == null) return;
    try {
      handler(event, detail);
    } catch (_) {
      // a diagnostics hook must never break support
    }
  }
}

/// Stops the badge polling while the app is in the background, and tells the
/// messenger when the app goes and comes back.
class _Lifecycle with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => GLSupportChat._onLifecycle(state);
}
