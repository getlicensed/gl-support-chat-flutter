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

/// Open a file the team sent — a public https address, as the team's files
/// are (`/files/<signed id>`) — inside the app rather than leave it: Safari's
/// own view (SFSafariViewController) on iOS, a Custom Tab on Android, which
/// show a PDF or a picture in place, with Done (iOS) or a close button
/// (Android) to come back to the chat. A phone that cannot (no browser
/// for Custom Tabs, say) opens it as before, outside. Never throws; false
/// only when nothing could open it.
Future<bool> launchInApp(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme.toLowerCase() == 'https') {
    try {
      if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
    } catch (_) {
      // no in-app view on this phone: outside, as before
    }
  }
  return launchExternal(url);
}
