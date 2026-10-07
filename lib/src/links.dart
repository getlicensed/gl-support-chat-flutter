import 'dart:convert';

/// base64url(UTF-8 JSON), unpadded — what the messenger reads from `#identity=`.
String encodeIdentity(Map<String, dynamic> json) =>
    base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');

/// The hosted messenger. The identity goes in the URL FRAGMENT: a fragment
/// is never sent to a server, so it cannot end up in nginx or load-balancer
/// access logs, and the page removes it from the address bar once read.
String buildMessengerUrl({
  required String apiUrl,
  required String productId,
  required String start,
  Map<String, dynamic>? identity,
}) {
  final base = Uri.parse('$apiUrl/m/$productId').replace(queryParameters: <String, String>{'start': start});
  if (identity == null) return base.toString();
  return '$base#identity=${encodeIdentity(identity)}';
}

/// Android `intent://…` links (what wa.me gives a browser): the web page they
/// name as their fallback, if any.
Uri? intentFallback(Uri uri) {
  if (uri.scheme.toLowerCase() != 'intent') return null;
  final raw = uri.toString();
  const key = 'S.browser_fallback_url=';
  final at = raw.indexOf(key);
  if (at < 0) return null;
  var value = raw.substring(at + key.length);
  final end = value.indexOf(';');
  if (end >= 0) value = value.substring(0, end);
  Uri? target;
  try {
    target = Uri.tryParse(Uri.decodeComponent(value));
  } catch (_) {
    target = null; // a malformed %-escape
  }
  if (target == null) return null;
  return target.scheme == 'https' || target.scheme == 'http' ? target : null;
}

/// `whatsapp://send?phone=…` when WhatsApp is not installed → the same chat on wa.me.
Uri? whatsappWebFallback(Uri uri) {
  if (uri.scheme.toLowerCase() != 'whatsapp') return null;
  final phone = (uri.queryParameters['phone'] ?? '').replaceAll(RegExp(r'\D'), '');
  final text = uri.queryParameters['text'];
  return Uri.https('wa.me', phone.isEmpty ? '/' : '/$phone', text == null ? null : <String, String>{'text': text});
}

/// wa.me link for a WhatsApp number (any format; at least 8 digits).
Uri? whatsappLink(String? number) {
  final digits = (number ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length < 8) return null;
  return Uri.https('wa.me', '/$digits');
}

/// `tel:` link (keeps a leading +; at least 6 digits).
Uri? telLink(String? number) {
  final cleaned = (number ?? '').replaceAll(RegExp(r'[^\d+]'), '');
  if (cleaned.replaceAll('+', '').length < 6) return null;
  return Uri(scheme: 'tel', path: cleaned);
}

/// `mailto:` link, with an optional subject.
Uri? mailtoLink(String? email, {String? subject}) {
  final address = (email ?? '').trim();
  if (!address.contains('@')) return null;
  return Uri(
    scheme: 'mailto',
    path: address,
    query: subject == null || subject.isEmpty ? null : 'subject=${Uri.encodeComponent(subject)}',
  );
}

/// How long to leave `/widget/auth` alone after [failures] in a row:
/// 30 s, 1 min, 2 min, 4 min, 8 min, then 10 min at most.
Duration authBackoff(int failures) {
  if (failures <= 0) return Duration.zero;
  final shift = failures - 1 > 5 ? 5 : failures - 1;
  final seconds = 30 * (1 << shift);
  return Duration(seconds: seconds > 600 ? 600 : seconds);
}
