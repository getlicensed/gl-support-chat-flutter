import 'package:url_launcher/url_launcher.dart';

import 'links.dart';

/// Hand a URL to the phone — WhatsApp, the browser, the mail or phone app.
///
/// Tries the link itself, then what it falls back to: an Android `intent://`
/// link's own web page, and wa.me for `whatsapp://` when WhatsApp is not
/// installed. Never throws; false only when nothing on the phone could open it.
Future<bool> launchExternal(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  final viaIntent = intentFallback(uri);
  final viaWeb = whatsappWebFallback(uri);
  final candidates = <Uri>[
    if (uri.scheme.toLowerCase() != 'intent') uri,
    if (viaIntent != null) viaIntent,
    if (viaWeb != null) viaWeb,
  ];
  for (final candidate in candidates) {
    try {
      if (await launchUrl(candidate, mode: LaunchMode.externalApplication)) return true;
    } catch (_) {
      // no app for this one — try the next
    }
  }
  return false;
}
