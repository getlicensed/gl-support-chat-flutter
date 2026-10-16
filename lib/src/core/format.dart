// Pure rules the screens follow, kept apart so they are unit-tested. Wording
// and rules are the website messenger's, so the app
// and the website say the same thing.

import 'dart:math' as math;
import 'dart:ui' show Color;

import '../api/models.dart';

/// `Hi Ayesha 👋` for a signed-in customer, the chatbot's own greeting, else `Hi there 👋`.
String greetingFor(MessengerSession s) => greeting(name: s.identifiedName, chatbotGreeting: s.welcomeGreeting);

/// The rule of [greetingFor], from its parts: also what Home's skeleton
/// says, from the look remembered and the name the app signed in with.
String greeting({String? name, String? chatbotGreeting}) {
  final first = (name ?? '').trim().split(RegExp(r'\s+')).first;
  if (first.isNotEmpty) return 'Hi $first 👋';
  final custom = (chatbotGreeting ?? '').trim();
  return custom.isNotEmpty ? custom : 'Hi there 👋';
}

/// The status line under "Send us a message" and in the chat header.
///
/// [agentsOnline] null means not known (before the connection says, while
/// connecting or reconnecting) — that reads as the neutral, positive line,
/// never "away", and never "Active now": nobody may be.
/// Someone online outranks the clock.
({String home, String header, bool away}) presenceLines(int? agentsOnline, OfficeHours? hours) {
  if (agentsOnline == null) return (home: 'We typically reply in a few minutes', header: 'Typically replies in a few minutes', away: false);
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

/// How many characters the AI typewriter releases per 25 ms of typing: one
/// when little is waiting, catching up at up to eight when a lot is. (The
/// controller draws three of these steps at a time, every 75 ms.)
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

/// "Just now", then as [shortAgo]: how long ago, under the thread's bubbles.
String agoLabel(DateTime then, DateTime now) => now.difference(then).inMinutes < 1 ? 'Just now' : shortAgo(then, now);

/// What the Messages list shows for a conversation's last message.
String previewLine(ConversationSummary c) {
  final body = (c.lastBody ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (body.isEmpty) return 'No messages yet';
  return c.lastAuthorType == 'visitor' ? 'You: $body' : body;
}

/// The chatbot's colour and the shades the design derives from it — the
/// website messenger's formulas, so both look the same — and the shades
/// that keep words and icons readable on it and in it (0.4.9): each is the
/// brand colour itself when that already reads, else moved just as far as
/// it must, never further.
///
/// The channels are kept as integers rather than read back from [Color],
/// whose accessors changed between Flutter 3.24 and 3.27.
class BrandColors {
  factory BrandColors(String? hex) {
    final rgb = parseHexRgb(hex) ?? (r: 0x63, g: 0x66, b: 0xF1);
    return BrandColors._(rgb);
  }
  BrandColors._(this._rgb);

  final _Rgb _rgb;

  Color get primary => _color(_rgb);

  /// `#rrggbb`, for the article's CSS.
  String get hex => _hexOf(_rgb);

  /// [ink] as `#rrggbb`, for the article's links.
  String get inkHex => _hexOf(_ink);

  Color get soft => _color(_soft);
  Color get hover => _color(_hover);
  Color get light => _color(_light);
  Color get ring => Color.fromARGB(46, _rgb.r, _rgb.g, _rgb.b); // 0.18

  _Rgb get _soft => _mix(_rgb, _whiteRgb, 0.18);
  _Rgb get _light => _mix(_rgb, _whiteRgb, 0.92);
  _Rgb get _hover {
    const step = 26; // 10% of 255
    int down(int x) => x - step < 0 ? 0 : x - step;
    return (r: down(_rgb.r), g: down(_rgb.g), b: down(_rgb.b));
  }

  /// Words and icons on the brand colour: white or near-black, whichever
  /// reads better on it — by contrast, not by how light it is: a mid teal
  /// read 2.5:1 in white, the old luminance rule's choice, and 7:1 in
  /// near-black.
  late final Color onPrimary = _color(_on);
  late final _Rgb _on = _ratio(_whiteRgb, _rgb) >= _ratio(_nearBlack, _rgb) ? _whiteRgb : _nearBlack;

  /// The brand colour under words and icons — a button, the header, a
  /// face's circle: as it is when [onPrimary] reads on it at 4.5:1, else
  /// moved away from [onPrimary] until it does (the default indigo, 4.47:1
  /// under white, by 1%).
  late final Color surface = _color(_fit(_rgb, 4.5));

  /// The header's and Home's band's lower end: [hover], fitted the same way
  /// (darker reads worse under near-black words).
  late final Color surfaceEnd = _color(_fit(_hover, 4.5));

  /// Home's band at the top: [soft], fitted the same way. On a mid brand
  /// colour it comes back to the colour itself: the greeting is on it.
  late final Color surfaceTop = _color(_fit(_soft, 4.5));

  /// The customer's own bubbles: the brand colour moved until their words
  /// read at 7:1, as every message's do (#1F6FEB by a quarter, darker).
  late final Color bubble = _color(_fit(_rgb, 7));

  /// The brand colour as ink on white — a chip's words, a link, an icon, a
  /// focused field's line: darkened until it reads at 4.5:1 on white, on
  /// [light] (a chip's fill) and on the pale grey of a card in a bubble.
  late final Color ink = _color(_ink);
  late final _Rgb _ink = _darkenUntil(_luminance(_light) < _luminance(_paleGrey) ? _light : _paleGrey, 4.5);

  /// The brand colour darkened until it reads at [goal]:1 on [background]
  /// and on white: a link in a teammate's bubble reads as the words around
  /// it do.
  Color inkOn(Color background, double goal) {
    final bg = background.computeLuminance();
    for (var step = 0; step <= 100; step++) {
      final c = _mix(_rgb, _blackRgb, step / 100);
      if (_ratioL(_luminance(c), bg) >= goal && _ratio(c, _whiteRgb) >= goal) return _color(c);
    }
    return _color(_blackRgb);
  }

  _Rgb _darkenUntil(_Rgb background, double goal) {
    for (var step = 0; step <= 100; step++) {
      final c = _mix(_rgb, _blackRgb, step / 100);
      if (_ratio(c, background) >= goal && _ratio(c, _whiteRgb) >= goal) return c;
    }
    return _blackRgb;
  }

  /// [c] moved away from [onPrimary] — darker under white, lighter under
  /// near-black — in 1% steps, until [onPrimary] reads on it at [goal]:1.
  _Rgb _fit(_Rgb c, double goal) {
    final away = _on == _whiteRgb ? _blackRgb : _whiteRgb;
    for (var step = 0; step <= 100; step++) {
      final shade = _mix(c, away, step / 100);
      if (_ratio(_on, shade) >= goal) return shade;
    }
    return away;
  }
}

typedef _Rgb = ({int r, int g, int b});

const _Rgb _whiteRgb = (r: 255, g: 255, b: 255);
const _Rgb _blackRgb = (r: 0, g: 0, b: 0);
const _Rgb _nearBlack = (r: 0x11, g: 0x18, b: 0x27); // Palette.text
const _Rgb _paleGrey = (r: 0xF9, g: 0xFA, b: 0xFB); // Palette.input

Color _color(_Rgb c) => Color.fromARGB(255, c.r, c.g, c.b);

String _hexOf(_Rgb c) => '#${((c.r << 16) | (c.g << 8) | c.b).toRadixString(16).padLeft(6, '0')}';

/// [a] mixed [t] of the way to [b].
_Rgb _mix(_Rgb a, _Rgb b, double t) {
  int at(int p, int q) => (p + (q - p) * t).round();
  return (r: at(a.r, b.r), g: at(a.g, b.g), b: at(a.b, b.b));
}

/// WCAG 2's relative luminance, from the channels.
double _luminance(_Rgb c) {
  double lin(int v) {
    final x = v / 255;
    return x <= 0.03928 ? x / 12.92 : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

double _ratio(_Rgb a, _Rgb b) => _ratioL(_luminance(a), _luminance(b));

double _ratioL(double x, double y) => x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);

/// WCAG 2 contrast of two opaque colours, 1 to 21.
double wcagContrast(Color a, Color b) => _ratioL(a.computeLuminance(), b.computeLuminance());

({int r, int g, int b})? parseHexRgb(String? hex) {
  final m = RegExp(r'^#?([0-9a-fA-F]{6})$').firstMatch((hex ?? '').trim());
  if (m == null) return null;
  final v = int.parse(m.group(1)!, radix: 16);
  return (r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF);
}
