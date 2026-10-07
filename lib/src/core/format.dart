// Pure rules the screens follow, kept apart so they are unit-tested. Wording
// and rules are the website messenger's, so the app
// and the website say the same thing.

import 'dart:ui' show Color;

import '../api/models.dart';

/// `Hi Ayesha 👋` for a signed-in customer, the chatbot's own greeting, else `Hi there 👋`.
String greetingFor(MessengerSession s) {
  final first = (s.identifiedName ?? '').trim().split(RegExp(r'\s+')).first;
  if (first.isNotEmpty) return 'Hi $first 👋';
  final custom = (s.welcomeGreeting ?? '').trim();
  return custom.isNotEmpty ? custom : 'Hi there 👋';
}

/// The status line under "Send us a message" and in the chat header.
///
/// [agentsOnline] null means not known yet (before the connection, or while
/// reconnecting) — that reads as the neutral, positive line, never "away".
/// Someone online outranks the clock.
({String home, String header, bool away}) presenceLines(int? agentsOnline, OfficeHours? hours) {
  if (agentsOnline == null) return (home: 'We typically reply in a few minutes', header: 'Active now', away: false);
  if (agentsOnline > 0) return (home: "We're online — reply in a few minutes", header: 'Active now', away: false);
  final opens = hours?.opensLabel;
  if (hours != null && !hours.open && opens != null && opens.isNotEmpty) {
    return (home: "We're away — back $opens", header: 'Back $opens', away: true);
  }
  return (home: "We're away — we'll reply by email", header: 'Away — replies by email', away: true);
}

/// The paragraph above the "leave your email" field while nobody is online.
String awayParagraph(OfficeHours? hours) {
  if (hours == null || hours.open) return '';
  final message = (hours.awayMessage ?? '').trim();
  final opens = hours.opensLabel;
  if (opens != null && opens.isNotEmpty) return '$message We are back $opens.'.trim();
  return message;
}

/// wa.me link for a "Book on WhatsApp" chip. In the app `{page}` is
/// "the <chatbot> app" and `{url}` is empty, so the dangling dash goes.
Uri? whatsappChipLink({required String? number, required String? template, required String productLabel}) {
  if (number == null || number.isEmpty) return null;
  final label = productLabel.isEmpty ? 'GL' : productLabel;
  final raw = (template == null || template.trim().isEmpty)
      ? "Hi, I'd like to book a course. I'm looking at {page} — {url}"
      : template;
  final text = raw
      .replaceAll('{page}', 'the $label app')
      .replaceAll('{url}', '')
      .replaceAll('{product}', productLabel)
      .replaceFirst(RegExp(r'\s+[—-]\s*$'), '')
      .trim();
  return Uri.https('wa.me', '/$number', <String, String>{'text': text});
}

/// A run of message text: plain, or a link with what to show for it.
class TextRun {
  const TextRun(this.text, [this.url]);
  final String text;
  final String? url;
  bool get isLink => url != null;
}

final _linkPattern = RegExp(r'''\[([^\]\n]{1,200})\]\((https?://[^\s)]+)\)|(https?://[^\s<>"']+)''');
final _trailing = RegExp(r'[.,;:!?)\]]+$');

/// Links in a message: `[label](https://…)` and bare https URLs, with trailing
/// punctuation left outside the link ("see https://x.com/a." links x.com/a).
/// Everything else stays plain text — a message is never HTML.
List<TextRun> linkify(String text) {
  final runs = <TextRun>[];
  var at = 0;
  for (final m in _linkPattern.allMatches(text)) {
    if (m.start > at) runs.add(TextRun(text.substring(at, m.start)));
    if (m.group(1) != null) {
      runs.add(TextRun(m.group(1)!, m.group(2)));
    } else {
      final raw = m.group(3)!;
      final tail = _trailing.firstMatch(raw)?.group(0) ?? '';
      final url = raw.substring(0, raw.length - tail.length);
      runs.add(TextRun(url, url));
      if (tail.isNotEmpty) runs.add(TextRun(tail));
    }
    at = m.end;
  }
  if (at < text.length) runs.add(TextRun(text.substring(at)));
  return runs;
}

/// The AI's hand-over marker, which the customer never sees.
String stripEscalationMarker(String text) {
  if (!text.contains('[[NEEDS_HUMAN]]')) return text;
  return text.replaceAll('[[NEEDS_HUMAN]]', '').replaceFirst(RegExp(r'[\s.!?,:;-]+$'), '');
}

/// A message with a photo is stored as "[Photo]" or "[Photo] what they typed",
/// for the inbox — the customer's, and the team's files in a chat (6 Oct).
/// Under the file itself only the words are shown.
String bodyBesideFiles(ChatMessage m) {
  if (m.attachments.isEmpty) return m.body;
  return m.body.replaceFirst(RegExp(r'^\[(Photo|Document)\]\s?'), '');
}

/// How many characters the AI typewriter releases per 25 ms tick: one when
/// little is waiting, catching up at up to eight when a lot is.
int dripStep(int buffered) {
  final n = buffered ~/ 20;
  return n < 1 ? 1 : (n > 8 ? 8 : n);
}

/// "now", "5m", "2h", "3d", then "5 Oct" — the Messages list's times.
String shortAgo(DateTime then, DateTime now) {
  final d = now.difference(then);
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  const months = <String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final day = '${then.day} ${months[then.month - 1]}';
  return then.year == now.year ? day : '$day ${then.year}';
}

/// What the Messages list shows for a conversation's last message.
String previewLine(ConversationSummary c) {
  final body = (c.lastBody ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (body.isEmpty) return 'No messages yet';
  return c.lastAuthorType == 'visitor' ? 'You: $body' : body;
}

/// The chatbot's colour and the shades the design derives from it — the
/// website messenger's formulas, so both look the same.
///
/// The channels are kept as integers rather than read back from [Color],
/// whose accessors changed between Flutter 3.24 and 3.27.
class BrandColors {
  factory BrandColors(String? hex) {
    final rgb = parseHexRgb(hex) ?? (r: 0x63, g: 0x66, b: 0xF1);
    return BrandColors._(rgb.r, rgb.g, rgb.b);
  }
  BrandColors._(this._r, this._g, this._b);

  final int _r;
  final int _g;
  final int _b;

  Color get primary => Color.fromARGB(255, _r, _g, _b);

  /// `#rrggbb`, for the article's CSS.
  String get hex => '#${((_r << 16) | (_g << 8) | _b).toRadixString(16).padLeft(6, '0')}';
  Color get soft => _lighten(0.18);
  Color get hover => _darken(0.10);
  Color get light => _lighten(0.92);
  Color get ring => Color.fromARGB(46, _r, _g, _b); // 0.18

  /// White on the brand colour unless the brand colour is very light.
  Color get onPrimary => primary.computeLuminance() > 0.6 ? const Color(0xFF111827) : const Color(0xFFFFFFFF);

  Color _lighten(double amount) {
    int up(int x) => x + ((255 - x) * amount).round();
    return Color.fromARGB(255, up(_r), up(_g), up(_b));
  }

  Color _darken(double amount) {
    final step = (255 * amount).round();
    int down(int x) => x - step < 0 ? 0 : x - step;
    return Color.fromARGB(255, down(_r), down(_g), down(_b));
  }
}

({int r, int g, int b})? parseHexRgb(String? hex) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch((hex ?? '').trim());
  if (m == null) return null;
  final v = int.parse(m.group(1)!, radix: 16);
  return (r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF);
}
