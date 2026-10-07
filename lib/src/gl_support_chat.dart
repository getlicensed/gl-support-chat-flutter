import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'api/client.dart';
import 'api/models.dart';
import 'api/realtime.dart';
import 'core/controller.dart';
import 'core/session_store.dart';
import 'device.dart';
import 'fallback.dart';
import 'links.dart';
import 'messenger_page.dart';
import 'ui/common.dart';

/// Something worth recording happened. Forward it to Crashlytics, Sentry or
/// your logs, so "support did not open" is a number you can see rather than
/// a complaint you hear about.
///
/// Events and their detail:
/// - `messenger_ready`   `{ms}` — signed in and loaded, from opening the messenger
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
/// server whether to show it as unverified or ignore it.
class GLSupportChatIdentity {
  const GLSupportChatIdentity({
    required this.id,
    this.hash,
    this.email,
    this.phone,
    this.name,
    this.type,
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

  /// True when your backend signed it.
  bool get isVerified => hash != null && hash!.isNotEmpty;

  /// Accepts what a Laravel backend really sends: a numeric `id`, and `null`
  /// or "" for fields it does not have. A missing or empty `hash` makes an
  /// unverified identity. Keys other than the six known ones are ignored.
  /// Throws [FormatException] when there is no id — use [tryParse] to get
  /// `null` instead.
  factory GLSupportChatIdentity.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final hash = json['hash'];
    final idText = id == null ? '' : '$id'.trim();
    if (idText.isEmpty) {
      throw const FormatException('an identity needs an id');
    }
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
    );
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

  /// The six fields; `hash` only when there is one.
  Map<String, dynamic> toJson() => {
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
  static MessengerController? _open;
  static Future<MessengerSession>? _signingIn;

  static SessionStore _store = const PrefsSessionStore();
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
    _productId = productId.trim();
    _appId = appId;
    _device = device;
    _pollInterval = unreadPollInterval;
    _fallback = fallback;
    _diagnostics = onDiagnostic;
    WidgetsFlutterBinding.ensureInitialized();
    _lifecycle ??= _Lifecycle()..attach();
    _startPolling();
  }

  /// The user signed in: from now on the messenger and the badge are theirs.
  /// Registers the push token too, if one was given before. Their anonymous
  /// chat on this phone, if any, becomes part of their history.
  ///
  /// Never throws and never blocks your sign-in for more than a few seconds.
  /// Returns false when the identity could not be confirmed with the server
  /// right now — the messenger still opens (anonymously, if the signature
  /// itself was refused) and the badge catches up on its own.
  static Future<bool> login(GLSupportChatIdentity identity) async {
    _identity = identity;
    _api?.token = null;
    _authFailures = 0;
    _authPausedUntil = null;
    try {
      if (!await _authenticateInBackground()) return false;
      final token = _pushToken;
      final platform = _pushPlatform;
      if (token != null && platform != null) await registerPushToken(token, platform: platform);
      await refreshUnread();
      return true;
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
    _authFailures = 0;
    _authPausedUntil = null;
    _emitUnread(0);
    if (api != null && push != null && bearer != null) {
      unawaited(api.unregisterPushToken(push).catchError((Object _) {}));
    }
    api?.token = null;
    final product = _productId;
    if (product != null) await _store.forget(product);
  }

  /// Register (or refresh) this install's FCM token so agent replies reach
  /// the phone while the messenger is closed. Safe to call before [login];
  /// it is sent as soon as there is a user. Never throws.
  static Future<void> registerPushToken(String token, {required String platform}) async {
    _pushToken = token;
    _pushPlatform = platform;
    final api = _api;
    if (_identity == null || api == null) return;
    if (api.token == null && !await _authenticateInBackground()) return;
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
    final open = _open;
    if (open != null && open.phase == MessengerPhase.ready) return _lastUnread; // the open messenger counts live
    try {
      if (api.token == null && !await _authenticateInBackground()) return _lastUnread;
      final n = await api.unread();
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
  /// [GLSupportChatFallback] contacts.
  static Future<void> present(BuildContext context, {GLSupportChatScreen screen = GLSupportChatScreen.home}) async {
    final api = _api;
    _open?.dispose();
    final controller = api == null
        ? null
        : MessengerController(api: api, signIn: _signIn, realtimeFactory: _realtime, onDiagnostic: _diag, onUnreadChanged: _emitUnread);
    _open = controller;
    String? browserUrl;
    if (api != null) {
      try {
        browserUrl = buildMessengerUrl(apiUrl: api.apiUrl, productId: api.productId, start: screen.value);
      } catch (_) {
        browserUrl = null; // an unusable apiUrl: no browser option, not a crash
      }
    }
    final page = GLSupportChatPage(controller: controller, screen: screen, fallback: _fallback, browserUrl: browserUrl);
    try {
      await Navigator.of(context, rootNavigator: true).push(
        PageRouteBuilder<void>(
          settings: const RouteSettings(name: messengerRoutePrefix),
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (_, animation, __, child) => SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
            child: child,
          ),
        ),
      );
    } finally {
      if (identical(_open, controller)) _open = null;
      controller?.dispose();
    }
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
    return buildMessengerUrl(apiUrl: api.apiUrl, productId: api.productId, start: screen.value, identity: _identity?.isVerified == true ? _identity!.toJson() : null);
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
  /// the badge, the push token and the messenger may all ask at once.
  static Future<MessengerSession> _signIn() {
    final pending = _signingIn;
    if (pending != null) return pending;
    final run = _doSignIn();
    _signingIn = run;
    return run.whenComplete(() => _signingIn = null);
  }

  static Future<MessengerSession> _doSignIn() async {
    final api = _api!;
    final product = api.productId;
    final stored = await _store.visitorId(product);
    final device = (_device ?? const GLSupportChatDevice()).toJson(appId: _appId);
    final session = await api.authenticate(
      visitorId: stored,
      identity: _identity?.toJson(),
      device: device.isEmpty ? null : device,
      onIdentityRejected: (code, _) => _diag('identity_rejected', <String, Object?>{'code': code}),
    );
    if (session.visitorId.isNotEmpty && session.visitorId != stored) await _store.saveVisitorId(product, session.visitorId);
    _authFailures = 0;
    _authPausedUntil = null;
    return session;
  }

  /// A 401 mid-session (the 24-hour token ran out): sign in again.
  static Future<String?> _renewToken() async {
    try {
      return (await _signIn()).token;
    } catch (_) {
      return null;
    }
  }

  /// Sign-in for the badge and push calls, which run without the customer
  /// looking. Backs off after failures (30 s doubling to 10 min) so a broken
  /// signature or an outage never turns every app on every phone into a
  /// retry loop.
  static Future<bool> _authenticateInBackground() async {
    if (_api == null) return false;
    final pausedUntil = _authPausedUntil;
    if (pausedUntil != null && DateTime.now().isBefore(pausedUntil)) return false;
    try {
      await _signIn();
      return true;
    } on ApiException catch (e) {
      _authFailed(e.status, e.message);
      return false;
    } catch (e) {
      _authFailed(0, '$e');
      return false;
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

/// Stops the badge polling while the app is in the background.
class _Lifecycle with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => GLSupportChat._onLifecycle(state);
}
