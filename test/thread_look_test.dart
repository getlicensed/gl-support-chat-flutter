import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/thread.dart';

// How the thread reads (0.4.8): messages in groups, a line under the
// customer's last message, the team's name and face once per group, and
// the typing dots.

/// The bubble around [text]: its decoration.
BoxDecoration bubbleOf(WidgetTester tester, String text) {
  final box = find.ancestor(of: inThread(text), matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).borderRadius != null));
  return tester.widget<Container>(box.first).decoration! as BoxDecoration;
}

Rect bubbleRect(WidgetTester tester, String text) =>
    tester.getRect(find.ancestor(of: inThread(text), matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).borderRadius != null)).first);

BorderRadius corners(double tl, double tr, double br, double bl) =>
    BorderRadius.only(topLeft: Radius.circular(tl), topRight: Radius.circular(tr), bottomRight: Radius.circular(br), bottomLeft: Radius.circular(bl));

GatedServer grouped() {
  final s = threadServer();
  s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    msg('a1', 'visitor', 'Hi, my licence card has not arrived.', at: ago(40)),
    msg('a2', 'visitor', 'It has been two weeks.', at: ago(39)),
    msg('a3', 'visitor', 'Can you check?', at: ago(38)),
    msg('a4', 'visitor', 'It is for my new job.', at: ago(31)), // seven minutes on: a new group
    msg('b1', 'agent', 'Sorry to hear that.', at: ago(30)),
    msg('b2', 'agent', 'Let me check with the SIA.', at: ago(29)),
    msg('c1', 'visitor', 'Thank you!', at: ago(28)),
  ]);
  return s;
}

void main() {
  testWidgets('messages from one author within five minutes are a group: corners 20, 4 where bubbles meet; 4 points apart, 16 between groups', (tester) async {
    await openThread(tester, grouped());
    // The customer's, on the right: [top-left, top-right, bottom-right, bottom-left].
    expect(bubbleOf(tester, 'Hi, my licence').borderRadius, corners(20, 20, 4, 20), reason: 'top of a group');
    expect(bubbleOf(tester, 'two weeks').borderRadius, corners(20, 4, 4, 20), reason: 'middle');
    expect(bubbleOf(tester, 'Can you check').borderRadius, corners(20, 4, 20, 20), reason: 'bottom');
    expect(bubbleOf(tester, 'new job').borderRadius, corners(20, 20, 4, 20), reason: 'seven minutes later: alone');
    // The team's, mirrored.
    expect(bubbleOf(tester, 'Sorry to hear').borderRadius, corners(20, 20, 20, 4), reason: "the team's top");
    expect(bubbleOf(tester, 'Let me check').borderRadius, corners(4, 20, 20, 20), reason: "the team's bottom");
    expect(bubbleOf(tester, 'Thank you').borderRadius, corners(20, 20, 4, 20), reason: 'a lone bubble');

    expect(bubbleRect(tester, 'two weeks').top - bubbleRect(tester, 'Hi, my licence').bottom, 4, reason: 'in a group');
    expect(bubbleRect(tester, 'Can you check').top - bubbleRect(tester, 'two weeks').bottom, 4);
    expect(bubbleRect(tester, 'new job').top - bubbleRect(tester, 'Can you check').bottom, 16, reason: 'between groups');
    expect(bubbleRect(tester, 'Let me check').top - bubbleRect(tester, 'Sorry to hear').bottom, 4);
  });

  testWidgets("the team's name, time and face once, at the group's last bubble — in the column the typing dots use", (tester) async {
    final (_, channel) = await openThread(tester, grouped());
    final names = find.descendant(of: threadList(), matching: find.textContaining('Levi John ·'));
    expect(names, findsOneWidget, reason: 'once for the group');
    expect(tester.getRect(names).top, greaterThan(bubbleRect(tester, 'Let me check').bottom), reason: 'under its last bubble');
    expect(tester.widget<Text>(names).data, 'Levi John · 29m');
    final faces = find.descendant(of: threadList(), matching: find.byType(ClipOval));
    expect(faces, findsOneWidget, reason: 'one face');
    final face = tester.getRect(faces);
    expect(face.bottom, bubbleRect(tester, 'Let me check').bottom, reason: 'beside the last bubble, at its foot');
    expect(face.size, const Size(28, 28));
    expect(bubbleRect(tester, 'Sorry to hear').left, bubbleRect(tester, 'Let me check').left, reason: 'the bubbles in one column beside it');

    channel.server('typing:start', leviTyping());
    await frames(tester, 20);
    final dotsFace = tester.getRect(find.descendant(of: find.bySemanticsLabel('Levi John is typing'), matching: find.byType(ClipOval)));
    expect(dotsFace.left, face.left, reason: 'the typing face in the same column: a reply that takes the dots\' place keeps it there');
    expect(dotsFace.size, face.size);
  });

  testWidgets('under the customer\'s last message alone: "Not seen yet · Just now", then "Seen", the time kept true', (tester) async {
    final server = threadServer();
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('m1', 'agent', 'How can we help?', at: ago(6)),
      msg('m2', 'visitor', 'My card has not arrived.', at: now()),
      msg('m3', 'visitor', 'It has been two weeks.', at: now()),
    ]);
    final (_, channel) = await openThread(tester, server);
    final lines = find.descendant(of: threadList(), matching: find.textContaining(RegExp(r'^(Seen|Not seen yet) · ')));
    expect(lines, findsOneWidget, reason: 'one line, for the last');
    expect(tester.widget<Text>(lines).data, 'Not seen yet · Just now');
    expect(tester.getRect(lines).top, greaterThan(bubbleRect(tester, 'two weeks').bottom), reason: 'under the last');

    channel.server('conversation:seen', <String, dynamic>{'conversationId': 'conv-1', 'seenBy': 'agent', 'seenAt': now()});
    await frames(tester, 15);
    expect(tester.widget<Text>(lines).data, 'Seen · Just now');

    // The time is the phone's, which a test cannot move on: what moves is
    // the clock the line listens to — every 15 seconds — and the words
    // ([agoLabel], unit-tested) follow it.
    final ticks = await BuildCounts.during(() async {
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 15));
      }
    });
    expect(ticks['ValueListenableBuilder<DateTime>'], greaterThanOrEqualTo(4), reason: 'told the time four times a minute: $ticks');
    expect(ticks.of(<String>{'_MineRow', '_TeamRow', '_Bubble'}), 0, reason: 'and nothing else is built for it');
  });

  testWidgets('a message on its way says "Sending…" only after 600 ms; refused, "Failed to send · Retry", and Retry sends it', (tester) async {
    final (c, channel) = await openThread(tester, threadServer());
    final ack = channel.holdAcks = Completer<void>();
    var refuse = true;
    channel.answers['visitor:message'] = (data) => refuse
        ? <String, dynamic>{'ok': false, 'error': 'server_error'}
        : <String, dynamic>{'ok': true, 'message': msg('s1', 'visitor', data['body'] as String, at: now())};
    unawaited(c.send('Is it posted?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacityOf(tester, find.text('Sending…')), 0, reason: 'not yet');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(opacityOf(tester, find.text('Sending…')), 1);
    expect(find.descendant(of: threadList(), matching: find.textContaining('Seen ·')), findsNothing, reason: 'the line under the message before goes: this one is the last');
    ack.complete();
    await frames(tester, 15);
    expect(find.text('Failed to send ·'), findsOneWidget);
    expect(find.text('Something went wrong — please try again.'), findsNothing, reason: 'no reason of its own: none said');
    refuse = false;
    channel.holdAcks = null;
    await tester.tap(find.text('Retry'));
    await frames(tester, 20);
    expect(find.text('Failed to send ·'), findsNothing);
    expect(find.descendant(of: threadList(), matching: find.text('Not seen yet · Just now')), findsOneWidget);
  });

  testWidgets('the typing dots: 8 points, 4 apart; each fades to 30% and back, 200 ms after the one before', (tester) async {
    final (_, channel) = await openThread(tester, threadServer());
    channel.server('typing:start', leviTyping());
    await frames(tester, 20);
    final row = find.bySemanticsLabel('Levi John is typing');
    final dots = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 8 && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle));
    expect(dots, findsNWidgets(3));
    final rects = dots.evaluate().map((e) => tester.getRect(find.byWidget(e.widget))).toList();
    for (final r in rects) {
      expect(r.size, const Size(8, 8));
    }
    expect(rects[1].left - rects[0].right, 4);
    expect(rects[2].left - rects[1].right, 4);
    double fade(int i) => tester.widget<FadeTransition>(find.ancestor(of: find.byWidget(dots.evaluate().elementAt(i).widget), matching: find.byType(FadeTransition)).first).opacity.value;
    final seen = <List<double>>[];
    for (var i = 0; i < 80; i++) {
      await tester.pump(frame);
      seen.add(<double>[fade(0), fade(1), fade(2)]);
    }
    for (var d = 0; d < 3; d++) {
      final values = seen.map((s) => s[d]).toList();
      expect(values.reduce((a, b) => a > b ? a : b), closeTo(1, 0.02), reason: 'dot $d at full');
      expect(values.reduce((a, b) => a < b ? a : b), closeTo(0.3, 0.02), reason: 'dot $d down to 30%');
    }
    int lowest(int d) {
      var at = 0;
      for (var i = 0; i < 75; i++) {
        if (seen[i][d] < seen[at][d]) at = i;
      }
      return at;
    }
    // Each dot reaches its faintest 200 ms (12–13 frames) after the one before.
    expect(((lowest(1) - lowest(0)) % 75) * 16, closeTo(200, 20));
    expect(((lowest(2) - lowest(1)) % 75) * 16, closeTo(200, 20));
  });
}
