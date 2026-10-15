import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';
import 'support/thread.dart';

// The thread as messages come and go, frame by frame (0.4.8), from the
// measurements of 15 Oct on an iPhone 13 and a 393-point Android:
//
// - Send with five lines typed: the composer eased down over 150 ms while
//   the thread glided up, and the thread dipped 28 points before it rose.
// - A reply: the thread stood still for two frames, then glided (32 ms
//   late); three replies in a row stood still at each, then started again
//   from rest.
// - Typing, then the reply: the dots vanished in one frame and the reply
//   faded in from nothing over 200 ms — a frame with neither; the dots, when
//   no reply came, held 250 ms and closed fastest at the very end.
// - The line under the customer's message eased its width as it changed,
//   cutting the time (":54 PM") while it did.

const phones = <(TargetPlatform, Phone)>[(TargetPlatform.iOS, Phone.iphone13), (TargetPlatform.android, Phone.android360)];

void main() {
  for (final (platform, phone) in phones) {
    group('${platform.name}, ${phone.name}:', () => thread(platform, phone));
  }
}

void thread(TargetPlatform platform, Phone phone) {
  testWidgets('Send with five lines typed: the composer is one line in the frame the message lands, and the thread only rises', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(), platform: platform, phone: phone, keyboard: phone.keyboard);
    channel.answers['visitor:message'] = echo(<String>[]);
    final ack = channel.holdAcks = Completer<void>();
    await tester.enterText(composer(), 'Line one\nLine two\nLine three\nLine four\nLine five');
    await frames(tester, 15);
    final above = inThread('You are welcome');
    // Their message before, whose line ("Seen") goes to the new one.
    final theirs = inThread('Thank you!');
    final tall = tester.getRect(composer()).height;
    final before = topOf(tester, above);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    final tops = <double>[before];
    double theirTop() => theirs.evaluate().isEmpty ? double.nan : topOf(tester, theirs);
    final theirTops = <double>[theirTop()];
    final fields = <double>[];
    for (var i = 0; i < 30; i++) {
      await tester.pump(frame);
      tops.add(topOf(tester, above));
      theirTops.add(theirTop());
      fields.add(tester.getRect(composer()).height);
    }
    for (var i = 1; i < theirTops.length; i++) {
      if (theirTops[i].isNaN || theirTops[i - 1].isNaN) continue; // risen out of view
      expect(theirTops[i] - theirTops[i - 1], lessThan(0.5), reason: 'frame $i: the bubble whose line went only rises: $theirTops');
    }
    expect(fields.first, lessThan(tall - 40), reason: 'one line in the first frame: ${fields.first} from $tall');
    expect(fields.toSet(), hasLength(1), reason: 'and stays: $fields');
    expect(tops[1], before, reason: 'in the frame it lands, nothing on screen moves');
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], lessThanOrEqualTo(tops[i - 1] + 0.01), reason: 'frame $i: it only rises — no dip: $tops');
    }
    expect(tops.last, lessThan(before - 20), reason: 'risen to make room for it');
    expect(scrollOf(tester), 0);
    ack.complete();
    await frames(tester, 5);
  });

  testWidgets('a reply: the thread starts gliding the frame after it lands, never standing still on the way', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20), platform: platform, phone: phone);
    final above = inThread('You are welcome');
    final before = topOf(tester, above);
    channel.server('message:created', msg('r1', 'agent', 'Found it: it was delivered to your post office on Monday.', at: now()));
    final tops = <double>[before];
    for (var i = 0; i < 30; i++) {
      await tester.pump(frame);
      tops.add(topOf(tester, above));
    }
    expect(tops[1], before, reason: 'the frame it lands in: what is on screen stays');
    expect(tops[2], lessThan(before - 1), reason: 'the next frame it moves: $tops');
    final rest = tops.last;
    for (var i = 2; i < tops.length; i++) {
      if (tops[i - 1] - rest < 1) break;
      expect(tops[i - 1] - tops[i], greaterThan(0.05), reason: 'frame $i still moving: $tops');
    }
  });

  testWidgets('three replies 96 ms apart: one glide that carries on — no frame without movement, never back down', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20), platform: platform, phone: phone);
    final above = inThread('You are welcome');
    void say(String id, String body) => channel.server('message:created', msg(id, 'agent', body, at: now()));
    final tops = <double>[topOf(tester, above)];
    say('q1', 'One moment.');
    for (var i = 1; i <= 40; i++) {
      if (i == 7) say('q2', 'I have checked with Royal Mail.');
      if (i == 13) say('q3', 'Tracking number: RM123456789GB.');
      await tester.pump(frame);
      tops.add(topOf(tester, above));
    }
    final rest = tops.last;
    for (var i = 2; i < tops.length; i++) {
      final moved = tops[i - 1] - tops[i];
      expect(moved, greaterThanOrEqualTo(-0.01), reason: 'frame $i: never back down: $tops');
      if (tops[i - 1] - rest >= 1) expect(moved, greaterThan(0.05), reason: 'frame $i: still on its way, and moving: $tops');
    }
    expect(find.text('New message'), findsNothing, reason: 'all at the latest');
    expect(scrollOf(tester), 0);
  });

  for (final (thread, long, reply) in <(String, int, String)>[
    ('a long thread', 20, 'Found it: it was delivered to your post office on Monday.'),
    // A short thread a tall reply takes past the screen: the shift and the scroll both hold it.
    ('a short thread', 0, 'Found it. ' * 15),
  ]) {
  testWidgets('$thread, a reply under a finger resting on it: nothing moves under the finger; let go, the thread goes down to the reply', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: long), platform: platform, phone: phone);
    final above = inThread('You are welcome');
    final finger = await tester.startGesture(tester.getCenter(above));
    await tester.pump(const Duration(milliseconds: 50));
    final held = topOf(tester, above);
    channel.server('message:created', msg('r1', 'agent', reply.trim(), at: now()));
    for (var i = 0; i < 30; i++) {
      await tester.pump(frame);
      expect(topOf(tester, above), closeTo(held, 0.01), reason: 'frame $i: under the finger, the thread stays');
    }
    await finger.up();
    // The message above, while it is still in view: it only rises.
    final tops = <double>[held];
    for (var i = 0; i < 30; i++) {
      await tester.pump(frame);
      tops.add(above.evaluate().isEmpty ? double.nan : topOf(tester, above));
    }
    expect(tops[4], lessThan(held - 5), reason: 'let go: it goes down to the reply: $tops');
    for (var i = 1; i < tops.length; i++) {
      if (tops[i].isNaN || tops[i - 1].isNaN) continue;
      expect(tops[i], lessThanOrEqualTo(tops[i - 1] + 0.01), reason: 'only up: $tops');
    }
    expect(scrollOf(tester), 0, reason: 'at the latest');
    expect(tester.getRect(inThread('Found it')).bottom, lessThanOrEqualTo(tester.getRect(threadList()).bottom), reason: 'the reply in view');
    expect(find.text('New message'), findsNothing);
  });
  }

  testWidgets('typing stops: the dots hold 600 ms, then close over 300 ms, quickly at first and gently into place', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20), platform: platform, phone: phone);
    channel.server('typing:start', leviTyping());
    await frames(tester, 20);
    final slot = find.descendant(of: find.byKey(const ValueKey<String>('typing'), skipOffstage: false).first, matching: find.byType(ClipRect), skipOffstage: false);
    final full = tester.getSize(slot).height;
    channel.server('typing:stop', leviTyping());
    await tester.pump();
    final heights = <double>[];
    for (var i = 0; i < 64; i++) {
      await tester.pump(frame);
      heights.add(slot.evaluate().isEmpty ? 0 : tester.getSize(slot).height);
    }
    final held = heights.indexWhere((h) => h < full - 0.01);
    expect(held * 16, inInclusiveRange(560, 640), reason: 'it holds about 600 ms: $heights');
    final closed = heights.indexWhere((h) => h == 0);
    expect((closed - held) * 16, inInclusiveRange(240, 330), reason: 'and closes over about 300 ms: $heights');
    final steps = <double>[for (var i = held; i < closed; i++) (i == 0 ? full : heights[i - 1]) - heights[i]];
    expect(steps.first, greaterThan(steps.last), reason: 'quick at first, gentle at the end: $steps');
  });

  testWidgets('typing, then the reply: it takes the dots\' place, the two cross-fading over 120 ms — never a frame with neither', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(long: 20), platform: platform, phone: phone);
    channel.server('typing:start', leviTyping());
    await frames(tester, 30);
    channel.server('typing:stop', leviTyping());
    await frames(tester, 5);
    final dotsRow = find.byKey(const ValueKey<String>('typing')).first;
    final dotsTop = tester.getRect(dotsRow).top;
    final face = tester.getRect(find.descendant(of: dotsRow, matching: find.byType(ClipOval)).first);
    channel.server('message:created', msg('r2', 'agent', 'Back with you: it is on its way.', at: now()));
    // The dots that fade out over the reply: drawn, not heard.
    final ghost = find.descendant(of: threadList(), matching: find.byWidgetPredicate((w) => w is Opacity && w.child.runtimeType.toString() == '_DotsBubble'), skipOffstage: false);
    final reply = inThread('Back with you');
    final seen = <(double, double)>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(frame);
      final dots = ghost.evaluate().isEmpty ? 0.0 : (ghost.evaluate().first.widget as Opacity).opacity;
      seen.add((dots, opacityOf(tester, reply)));
    }
    for (final (dots, words) in seen.skip(1)) {
      expect(dots + words, greaterThan(0.9), reason: 'every frame shows one or the other: $seen');
    }
    expect(seen.first.$2, lessThan(0.3), reason: 'the reply fades in: $seen');
    expect(seen.firstWhere((s) => s.$1 == 0, orElse: () => (1, 0)).$2, 1, reason: 'the dots gone once the reply is whole: $seen');
    expect(seen.indexWhere((s) => s.$2 == 1) * 16, lessThanOrEqualTo(144), reason: 'over 120 ms: $seen');
    final rows = find.byWidgetPredicate((w) => w is KeyedSubtree && '${w.key}'.contains(':r2'), skipOffstage: false);
    await tester.pump();
    final top = rows.evaluate().map((e) => (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy).reduce((a, b) => a < b ? a : b);
    expect(top, lessThan(dotsTop + 1), reason: 'the reply came in where the dots were, and has risen since');
    expect(face.left, greaterThanOrEqualTo(0));
  });

  testWidgets('the line under a message on its way: one line tall whatever it says, never cut while it changes', (tester) async {
    final (_, channel) = await openThread(tester, threadServer(), platform: platform, phone: phone, keyboard: phone.keyboard);
    channel.answers['visitor:message'] = echo(<String>[]);
    final ack = channel.holdAcks = Completer<void>();
    await tester.enterText(composer(), 'Is it posted yet?');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    final row = find.byKey(const ValueKey<String>('out:local-1')).first;
    final bubble = find.descendant(of: row, matching: find.text('Is it posted yet?'));
    final heights = <double>{};
    for (var i = 0; i < 60; i++) {
      if (i == 45) ack.complete();
      await tester.pump(frame);
      heights.add(tester.getRect(row).height - tester.getRect(bubble).height);
      expect(find.descendant(of: row, matching: find.byType(AnimatedSize)), findsNothing, reason: 'nothing eases its width');
    }
    expect(find.descendant(of: row, matching: find.text('Sending…')), findsNothing);
    expect(heights.reduce((a, b) => a > b ? a : b) - heights.reduce((a, b) => a < b ? a : b), lessThan(0.5), reason: 'the same height under it, from Sending… to sent: $heights');
  });
}
