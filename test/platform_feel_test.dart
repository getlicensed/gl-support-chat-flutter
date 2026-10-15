import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';
import 'support/thread.dart';

// How a tap feels on each phone (0.4.8). Measured on 15 Oct, frame by frame
// under a finger: the header's Back showed nothing for 160 ms (two gesture
// recognisers on it waited for each other); a card inside a bubble the same
// (the bubble's long press for copying); the Messages and Help rows, "Search
// for help" and the CSAT faces showed nothing at all — their ink was drawn
// under an opaque box; InkWell's highlight takes 200 ms to come.

/// A conversation with an article card in a bubble, and a rating to give:
/// long enough to scroll.
GatedServer cardServer() {
  final s = threadServer();
  s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    for (var i = 0; i < 20; i++) msg('l$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card.', at: ago(200 - i)),
    msg('m1', 'visitor', 'Hi, my card has not arrived.', at: ago(9)),
    msg('m2', 'bot', 'This may help:', at: ago(8), meta: <String, dynamic>{
      'article': <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?'},
    }),
    msg('m3', 'bot', '', at: ago(7), meta: <String, dynamic>{'csat': <String, dynamic>{'ratingId': 'r1'}}),
  ]);
  return s;
}

/// iOS's highlight over [target] (or what it is in): how much of it shows.
double highlightOf(WidgetTester tester, Finder target) {
  bool painter(Widget w) => w is CustomPaint && w.foregroundPainter is PressHighlight;
  final inside = find.descendant(of: target, matching: find.byWidgetPredicate(painter));
  final paints = inside.evaluate().isNotEmpty ? inside : find.ancestor(of: target, matching: find.byWidgetPredicate(painter));
  return (tester.widget<CustomPaint>(paints.first).foregroundPainter! as PressHighlight).amount.value;
}

/// The highlight's amount at each of [at] (ms after the finger comes down),
/// then let go.
Future<List<double>> press(WidgetTester tester, Finder target, List<int> at) async {
  final gesture = await tester.startGesture(tester.getCenter(target));
  final seen = <double>[];
  var t = 0;
  for (final ms in at) {
    await tester.pump(Duration(milliseconds: ms - t));
    t = ms;
    seen.add(highlightOf(tester, target));
  }
  await gesture.cancel();
  await frames(tester, 20);
  return seen;
}

void main() {
  for (final (platform, factory) in <(TargetPlatform, InteractiveInkFeatureFactory)>[
    (TargetPlatform.android, InkRipple.splashFactory),
    (TargetPlatform.iOS, NoSplash.splashFactory),
  ]) {
    testWidgets('${platform.name}: the ink is ${platform == TargetPlatform.iOS ? 'none (iOS does not ripple)' : "the ripple, not Material 3's sparkle (compiled on the first tap)"}', (tester) async {
      await openThread(tester, threadServer(), platform: platform);
      expect(Theme.of(tester.element(find.byType(ConversationPage))).splashFactory, same(factory));
    });
  }

  testWidgets('iOS: Back shows its highlight from the first frame, whole by 100 ms; let go, it fades out over 200 ms', (tester) async {
    await openThread(tester, cardServer());
    final back = find.byTooltip('Back');
    final down = await press(tester, back, <int>[16, 48, 112]);
    expect(down[0], greaterThan(0), reason: 'the first frame under the finger: $down');
    expect(down[2], 1, reason: 'whole by 100 ms: $down');

    final gesture = await tester.startGesture(tester.getCenter(back));
    await frames(tester, 10);
    await gesture.cancel();
    final out = <double>[];
    for (var i = 0; i < 16; i++) {
      await tester.pump(frame);
      out.add(highlightOf(tester, back));
    }
    expect(out.where((v) => v > 0.02 && v < 0.98).length, greaterThanOrEqualTo(8), reason: 'animated out: $out');
    expect(out.last, 0);
  });

  testWidgets('iOS: in a long thread, a card in a bubble and a CSAT face light up as the list lets the touch through (100 ms), never later', (tester) async {
    await openThread(tester, cardServer());
    for (final target in <Finder>[find.text('Read article'), find.text('Great')]) {
      // A list that scrolls waits 100 ms to tell a drag from a tap, as iOS
      // lists do; nothing else holds the touch back (the copy's long press
      // is on the words alone).
      final seen = await press(tester, target, <int>[16, 64, 128, 240]);
      expect(seen[2], greaterThan(0.1), reason: 'by 100 ms and a frame: $seen');
      expect(seen[3], 1, reason: 'whole 100 ms later: $seen');
    }
  });

  testWidgets('the highlight takes the shape of what is pressed: the chip\'s tight corner, the round Send', (tester) async {
    final server = cardServer();
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('p1', 'bot', 'Which course is it about?', at: ago(6), meta: <String, dynamic>{
        'buttons': <Object?>[<String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'}],
      }),
    ]);
    await openThread(tester, server);
    PressHighlight painterOf(Finder f) => tester.widget<CustomPaint>(find.ancestor(of: f, matching: find.byWidgetPredicate((w) => w is CustomPaint && w.foregroundPainter is PressHighlight)).first).foregroundPainter! as PressHighlight;
    final chip = painterOf(find.text('Door Supervisor'));
    expect((chip.shape as RoundedRectangleBorder).borderRadius, const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16), bottomLeft: Radius.circular(16), bottomRight: Radius.circular(4)));
    final send = painterOf(find.byIcon(Icons.arrow_upward));
    expect(send.shape, const CircleBorder());
    expect(send.inner, const Size(36, 36), reason: 'the circle, not its 44-point target');
  });

  testWidgets('Android: a press ripples on a Material above every opaque box — the Messages rows, "Search for help", the CSAT faces, a card in a bubble, Back, Send', (tester) async {
    final server = cardServer();
    server.articles = <Map<String, dynamic>>[<String, dynamic>{'slug': 'renew', 'title': 'Renewing', 'description': null}];
    server.conversations = <Map<String, dynamic>>[row('conv-1', body: 'Anything else?', at: ago(25)), row('old', open: false, body: 'Your refund has gone through.')];
    usePhone(tester, Phone.android360);
    final c = controllerOn(server, ManualChannel(autoConnect: true));
    await tester.pumpWidget(MaterialApp(theme: ThemeData(platform: TargetPlatform.android), home: GLSupportChatPage(controller: c)));
    await settle(tester, frames: 16);

    /// Nothing that paints a colour between the ink and the Material it is drawn on.
    void inkShows(Finder target, String what) {
      final ink = find.ancestor(of: target, matching: find.byWidgetPredicate((w) => w is InkWell)).first;
      var covered = false;
      tester.element(ink).visitAncestorElements((e) {
        final w = e.widget;
        if (w is Material) return false;
        if (w is ColoredBox || (w is DecoratedBox && (w.decoration as BoxDecoration?)?.color != null)) covered = true;
        return true;
      });
      expect(covered, isFalse, reason: '$what: its ink would be drawn under a box of colour');
    }

    Future<void> ripples(Finder target, String what) async {
      inkShows(target, what);
      final gesture = await tester.startGesture(tester.getCenter(target));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 50));
      // The Material's ink, as Flutter's own tests read it.
      final ink = (Material.of(tester.element(target)) as dynamic).debugInkFeatures as List<InkFeature>?;
      expect(ink?.whereType<InkRipple>(), isNotEmpty, reason: '$what: a ripple');
      await gesture.cancel();
      await frames(tester, 30);
    }

    await ripples(find.text('Search for help'), 'Search for help');
    await tester.tap(find.text('Messages'));
    await settle(tester);
    await ripples(find.text('Your refund has gone through.'), 'a Messages row');
    await tester.tap(find.text('Anything else?'));
    await settle(tester);
    await ripples(find.text('Read article'), 'a card in a bubble');
    await ripples(find.text('Great'), 'a CSAT face');
    await ripples(find.byIcon(Icons.chevron_left), 'Back on the header');
    await tester.enterText(composer(), 'Hello');
    await frames(tester, 15);
    await ripples(find.byIcon(Icons.arrow_upward), 'Send');
  });
}
