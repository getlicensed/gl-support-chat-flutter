import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';

import 'fakes.dart';
import 'gated.dart';
import 'phone.dart';

// The live conversation on a phone, frame by frame: what the tests of the
// thread's look and motion share (0.4.8, from the measurements of 15 Oct).

/// A frame of a 60 Hz phone.
const frame = Duration(milliseconds: 16);

/// Levi's user id: his replies and his typing name him.
const levi = '9b1c3a5e-0000-4000-8000-000000000001';

/// A time [minutesAgo] minutes before now, as the server writes it.
String ago(int minutesAgo) => DateTime.now().subtract(Duration(minutes: minutesAgo)).toUtc().toIso8601String();

/// Now, as the server writes it.
String now() => DateTime.now().toUtc().toIso8601String();

/// A conversation with [long] older messages, then five that end with Levi's.
GatedServer threadServer({int long = 0}) {
  final s = GatedServer();
  s.openInfo = <String, dynamic>{'conversationId': 'conv-1'};
  s.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Anything else?', at: ago(25))];
  s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    for (var i = 0; i < long; i++)
      msg('l$i', (i ~/ 2).isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.', at: ago(200 - i)),
    msg('m1', 'visitor', 'Hi, my licence card has not arrived yet.', at: ago(30)),
    msg('m2', 'agent', 'Sorry to hear that. Let me check with the SIA.', at: ago(28)),
    msg('m3', 'agent', 'It was posted on 2 October, so it should be with you this week.', at: ago(27)),
    msg('m4', 'visitor', 'Thank you!', at: ago(26)),
    msg('m5', 'agent', 'You are welcome. Anything else I can help with?', at: ago(25)),
  ], agentLastSeenAt: ago(26));
  return s;
}

/// The live conversation open on [phone], connected, someone online.
Future<(MessengerController, ManualChannel)> openThread(
  WidgetTester tester,
  FakeServer server, {
  TargetPlatform platform = TargetPlatform.iOS,
  Phone phone = Phone.iphone13,
  double keyboard = 0,
}) async {
  usePhone(tester, phone, keyboard: keyboard);
  final channel = ManualChannel(autoConnect: true);
  final c = controllerOn(server, channel);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(platform: platform),
    home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1')),
  ));
  await settle(tester, frames: 16);
  channel.server('presence:update', <String, dynamic>{'agentsOnline': 1});
  await settle(tester, frames: 6);
  return (c, channel);
}

/// Who is typing, as the server says it: Levi.
Map<String, dynamic> leviTyping() => <String, dynamic>{'conversationId': 'conv-1', 'authorType': 'agent', 'authorId': levi, 'authorName': 'Levi John'};

Finder page() => find.byType(ConversationPage);
Finder threadList() => find.descendant(of: page(), matching: find.byType(ListView));
Finder composer() => find.descendant(of: page(), matching: find.byType(TextField)).last;

/// [text] in the thread, plain or with links.
Finder inThread(String text) => find.descendant(of: threadList(), matching: find.textContaining(text, findRichText: true));

double topOf(WidgetTester tester, Finder f) => tester.getRect(f.first).top;

/// The thread's scroll offset (0 at the latest).
double scrollOf(WidgetTester tester) => tester.widget<ListView>(threadList()).controller!.offset;

/// How visible [f] is: every fade and opacity above it, multiplied.
double opacityOf(WidgetTester tester, Finder f) {
  if (f.evaluate().isEmpty) return 0;
  var o = 1.0;
  for (final e in find.ancestor(of: f.first, matching: find.byType(FadeTransition)).evaluate()) {
    o *= (e.widget as FadeTransition).opacity.value;
  }
  for (final e in find.ancestor(of: f.first, matching: find.byType(Opacity)).evaluate()) {
    o *= (e.widget as Opacity).opacity;
  }
  return o;
}

/// Counts the builds of widgets by type name — every time Flutter runs one's
/// build, whether it was marked dirty (a setState, an inherited widget it
/// depends on) or its parent built it again with a new widget.
class BuildCounts {
  final counts = <String, int>{};

  int operator [](String type) => counts[type] ?? 0;

  /// The sum over [types].
  int of(Iterable<String> types) => types.fold(0, (sum, t) => sum + this[t]);

  /// Counts the builds while [body] runs.
  static Future<BuildCounts> during(Future<void> Function() body) async {
    final b = BuildCounts();
    widgets.debugOnRebuildDirtyWidget = (element, _) {
      final type = element.widget.runtimeType.toString();
      b.counts[type] = (b.counts[type] ?? 0) + 1;
    };
    try {
      await body();
    } finally {
      widgets.debugOnRebuildDirtyWidget = null;
    }
    return b;
  }

  @override
  String toString() => (counts.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join(' ');
}

/// [n] frames.
Future<void> frames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(frame);
  }
}
