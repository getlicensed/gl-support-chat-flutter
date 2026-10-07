import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

/// The server said no in words the customer can be shown (`{error}`), with
/// the HTTP status. Network failures and timeouts are `status: 0`.
class ApiException implements Exception {
  const ApiException(this.status, this.message, {this.code});

  final int status;
  final String message;
  final String? code;

  @override
  String toString() => 'ApiException($status${code == null ? '' : ' $code'}): $message';
}

/// REST calls of the messenger: the server's /widget routes on [apiUrl],
/// and the public help centre on the session's `helpBaseUrl`.
///
/// Every call has a timeout. A 401 on a signed-in call asks [reauthenticate]
/// for a fresh token once and tries again — the visitor token lasts 24 hours
/// and an app stays open longer than that.
class MessengerApi {
  MessengerApi({
    required String apiUrl,
    required this.productId,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.uploadTimeout = const Duration(seconds: 90),
    this.retryDelays = const <Duration>[Duration(milliseconds: 1500), Duration(seconds: 4)],
  })  : apiUrl = apiUrl.trim().replaceFirst(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  final String apiUrl;
  final String productId;
  final Duration timeout;
  final Duration uploadTimeout;

  /// Waits between sign-in attempts (the web messenger's: 1.5 s, then 4 s).
  final List<Duration> retryDelays;
  final http.Client _http;

  /// The visitor token from the last sign-in.
  String? token;

  /// Called on a 401: sign in again and return the new token (or null).
  Future<String?> Function()? reauthenticate;

  /// Where the help-centre API lives (from the session).
  String? helpBaseUrl;

  Uri _api(String path) => Uri.parse('$apiUrl$path');

  // ------------------------------------------------------------------
  // Sign-in
  // ------------------------------------------------------------------

  /// POST /widget/auth. Retries what is worth retrying — no network, 429,
  /// 502, 503, 504 (honouring Retry-After up to 10 s) — at most three tries.
  /// A refused identity (401) is reported to [onIdentityRejected] and the
  /// customer is signed in anonymously instead, as on the website.
  Future<MessengerSession> authenticate({
    String? visitorId,
    Map<String, dynamic>? identity,
    Map<String, String>? device,
    Map<String, String>? attributes,
    void Function(String code, String message)? onIdentityRejected,
  }) async {
    var res = await _postAuth(visitorId: visitorId, identity: identity, device: device, attributes: attributes);
    if (res.statusCode == 401 && identity != null) {
      final body = _decode(res.body);
      onIdentityRejected?.call('${body['code'] ?? 'identity_rejected'}', '${body['error'] ?? ''}');
      res = await _postAuth(visitorId: visitorId, device: device, attributes: attributes);
    }
    if (res.statusCode != 200) {
      final body = _decode(res.body);
      throw ApiException(res.statusCode, '${body['error'] ?? 'Sign-in failed'}', code: body['code'] as String?);
    }
    final session = MessengerSession.fromJson(_decode(res.body));
    if (session.token.isEmpty) throw const ApiException(200, 'No token in the sign-in response');
    token = session.token;
    helpBaseUrl = session.helpBaseUrl;
    return session;
  }

  Future<http.Response> _postAuth({
    String? visitorId,
    Map<String, dynamic>? identity,
    Map<String, String>? device,
    Map<String, String>? attributes,
  }) async {
    final body = jsonEncode(<String, dynamic>{
      'productId': productId,
      if (visitorId != null && visitorId.isNotEmpty) 'visitorId': visitorId,
      if (identity != null) 'identity': identity,
      if (device != null && device.isNotEmpty) 'device': device,
      if (attributes != null && attributes.isNotEmpty) 'attributes': attributes,
    });
    for (var attempt = 0;; attempt++) {
      final last = attempt >= retryDelays.length;
      try {
        final res = await _http
            .post(_api('/widget/auth'), headers: const <String, String>{'content-type': 'application/json'}, body: body)
            .timeout(timeout);
        const retryable = <int>{429, 502, 503, 504};
        if (!retryable.contains(res.statusCode) || last) return res;
        await Future<void>.delayed(_retryAfter(res) ?? retryDelays[attempt]);
      } catch (e) {
        if (last) throw ApiException(0, 'No connection: $e');
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  static Duration? _retryAfter(http.Response res) {
    final seconds = double.tryParse(res.headers['retry-after'] ?? '');
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    final ms = (seconds * 1000).round();
    return Duration(milliseconds: ms > 10000 ? 10000 : ms);
  }

  // ------------------------------------------------------------------
  // Conversations
  // ------------------------------------------------------------------

  /// GET /widget/messages — which conversation is open, its unread, a pending CSAT.
  Future<OpenConversationInfo> openConversation() async =>
      OpenConversationInfo.fromJson(await _json('GET', '/widget/messages'));

  /// GET /widget/conversations — every conversation, newest first.
  Future<List<ConversationSummary>> conversations() async {
    final j = await _json('GET', '/widget/conversations');
    final rows = j['conversations'];
    if (rows is! List) return <ConversationSummary>[];
    return rows.whereType<Map>().map((r) => ConversationSummary.fromJson(Map<String, dynamic>.from(r))).toList();
  }

  /// GET /widget/conversations/:id
  Future<ConversationDetail> conversation(String id) async =>
      ConversationDetail.fromJson(await _json('GET', '/widget/conversations/${Uri.encodeComponent(id)}'));

  /// GET /widget/workflow — the opening menu, or null.
  Future<WorkflowPreview?> workflow() async => WorkflowPreview.fromJson((await _json('GET', '/widget/workflow'))['workflow']);

  /// GET /widget/unread — the badge.
  Future<int> unread() async {
    final n = (await _json('GET', '/widget/unread'))['unreadCount'];
    return n is num ? n.toInt() : 0;
  }

  /// POST /widget/seen — this conversation (or the open one) has been read.
  Future<void> seen([String? conversationId]) async {
    await _json('POST', '/widget/seen', body: <String, dynamic>{if (conversationId != null) 'conversationId': conversationId});
  }

  /// POST /widget/email — the customer's address for a reply by email.
  Future<void> leaveEmail(String email) async {
    await _json('POST', '/widget/email', body: <String, dynamic>{'email': email});
  }

  Future<void> registerPushToken(String pushToken, {required String platform, String? appId}) async {
    await _json('POST', '/widget/push-token', body: <String, dynamic>{
      'token': pushToken,
      'platform': platform,
      if (appId != null) 'appId': appId,
    });
  }

  Future<void> unregisterPushToken(String pushToken) async {
    await _json('DELETE', '/widget/push-token', body: <String, dynamic>{'token': pushToken});
  }

  // ------------------------------------------------------------------
  // Files
  // ------------------------------------------------------------------

  /// POST /widget/uploads — a photo, before the message that carries it.
  Future<UploadedFile> upload(Uint8List bytes, {required String name, required String contentType}) async {
    Future<http.Response> send(String bearer) => _http
        .post(
          _api('/widget/uploads'),
          headers: <String, String>{
            'authorization': 'Bearer $bearer',
            'content-type': contentType,
            'x-file-name': Uri.encodeComponent(name),
          },
          body: bytes,
        )
        .timeout(uploadTimeout);
    final res = await _withToken(send);
    final body = _decode(res.body);
    if (res.statusCode != 201) throw ApiException(res.statusCode, '${body['error'] ?? 'The file could not be sent.'}');
    return UploadedFile.fromJson(body);
  }

  /// GET /widget/files/:id — the customer's own file, to draw it.
  Future<Uint8List> file(String id) async {
    final res = await _withToken(
      (bearer) => _http.get(_api('/widget/files/${Uri.encodeComponent(id)}'), headers: <String, String>{'authorization': 'Bearer $bearer'}).timeout(timeout),
    );
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'The file could not be opened.');
    return res.bodyBytes;
  }

  // ------------------------------------------------------------------
  // Help centre (public, on the web app)
  // ------------------------------------------------------------------

  /// The chatbot's articles; with [query] (2+ characters) a full-text search.
  Future<({List<ArticleSummary> articles, String? helpUrl})> articles({String? query, int limit = 100}) async {
    final base = helpBaseUrl;
    if (base == null) return (articles: <ArticleSummary>[], helpUrl: null);
    final uri = Uri.parse('$base/api/help/articles').replace(queryParameters: <String, String>{
      'productId': productId,
      'limit': '$limit',
      if (query != null && query.trim().length >= 2) 'q': query.trim(),
    });
    final res = await _plain(() => _http.get(uri).timeout(timeout));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'Help articles could not be loaded.');
    final j = _decode(res.body);
    final rows = j['articles'] is List ? (j['articles'] as List) : const <Object?>[];
    return (
      articles: rows.whereType<Map>().map((r) => ArticleSummary.fromJson(Map<String, dynamic>.from(r))).where((a) => a.slug.isNotEmpty).toList(),
      helpUrl: j['helpUrl'] as String?,
    );
  }

  Future<Article> article(String slug) async {
    final base = helpBaseUrl;
    if (base == null) throw const ApiException(0, 'Help articles are not available right now.');
    final uri = Uri.parse('$base/api/help/articles/${Uri.encodeComponent(slug)}').replace(queryParameters: <String, String>{'productId': productId});
    final res = await _plain(() => _http.get(uri).timeout(timeout));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'This article could not be loaded.');
    return Article.fromJson(_decode(res.body));
  }

  // ------------------------------------------------------------------

  Future<Map<String, dynamic>> _json(String method, String path, {Map<String, dynamic>? body}) async {
    Future<http.Response> send(String bearer) {
      final headers = <String, String>{'authorization': 'Bearer $bearer', 'content-type': 'application/json'};
      final uri = _api(path);
      final encoded = body == null ? null : jsonEncode(body);
      switch (method) {
        case 'GET':
          return _http.get(uri, headers: headers).timeout(timeout);
        case 'DELETE':
          return _http.delete(uri, headers: headers, body: encoded).timeout(timeout);
        default:
          return _http.post(uri, headers: headers, body: encoded ?? '{}').timeout(timeout);
      }
    }

    final res = await _withToken(send);
    final decoded = _decode(res.body);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, '${decoded['error'] ?? 'Request failed'}', code: decoded['code'] as String?);
    }
    return decoded;
  }

  /// Sends with the current token; on a 401, signs in again once and resends.
  Future<http.Response> _withToken(Future<http.Response> Function(String bearer) send) async {
    var bearer = token;
    if (bearer == null) {
      bearer = await reauthenticate?.call();
      if (bearer == null) throw const ApiException(401, 'Not signed in');
    }
    var res = await _plain(() => send(bearer!));
    if (res.statusCode == 401 && reauthenticate != null) {
      final fresh = await reauthenticate!.call();
      if (fresh != null) res = await _plain(() => send(fresh));
    }
    return res;
  }

  static Future<http.Response> _plain(Future<http.Response> Function() call) async {
    try {
      return await call();
    } on TimeoutException {
      throw const ApiException(0, 'The connection timed out.');
    } catch (e) {
      if (e is ApiException) rethrow;
      throw ApiException(0, 'No connection: $e');
    }
  }

  static Map<String, dynamic> _decode(String body) {
    if (body.isEmpty) return <String, dynamic>{};
    try {
      final v = jsonDecode(body);
      return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  void close() => _http.close();
}
