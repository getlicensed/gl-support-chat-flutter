import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/tabs.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';
import 'support/thread.dart';

// The small things (0.4.8): what the phone says under a finger, the Send
// button, the CSAT faces, skeletons instead of spinners, the tab's badge.

/// A conversation that asks for a rating and offers two workflow buttons.
GatedServer askingServer() {
  final s = threadServer();
  s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    msg('m1', 'visitor', 'Hi, my card has not arrived.', at: ago(9)),
    msg('m2', 'bot', '', at: ago(8), meta: <String, dynamic>{'csat': <String, dynamic>{'ratingId': 'r1'}}),
    msg('p1', 'bot', 'Which course is it about?', at: ago(6), meta: <String, dynamic>{
      'buttons': <Object?>[
        <String, dynamic>{'id': 'b1', 'label': 'Door Supervisor'},
        <String, dynamic>{'id': 'b2', 'label': 'CCTV'},
      ],
    }),
  ]);
  return s;
}

/// The phone's taps and ticks, as the app asks for them.
List<String> listenForHaptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add('${call.arguments}'.replaceFirst('HapticFeedbackType.', ''));
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

void main() {
  testWidgets('a tick of the phone for a choice — a workflow button, a CSAT face, an article face — none for Send, a light tap when a send fails or words are copied', (tester) async {
    final server = askingServer();
    server.article = <String, dynamic>{'slug': 'renew', 'title': 'Renewing', 'html': '<p>You can renew early.</p>'};
    final (c, channel) = await openThread(tester, server);
    final haptics = listenForHaptics(tester);

    await tester.tap(find.text('Great'));
    await frames(tester, 5);
    expect(haptics, <String>['selectionClick'], reason: 'a CSAT face');
    await tester.tap(find.text('Door Supervisor'));
    await frames(tester, 5);
    expect(haptics, <String>['selectionClick', 'selectionClick'], reason: 'a workflow button');

    haptics.clear();
    channel.answers['visitor:message'] = (data) => <String, dynamic>{'ok': true, 'message': msg('s1', 'visitor', data['body'] as String, at: now())};
    await tester.enterText(composer(), 'Thank you');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await frames(tester, 20);
    expect(haptics, isEmpty, reason: 'nothing for Send: the message rising is the answer');

    channel.answers['visitor:message'] = (_) => <String, dynamic>{'ok': false, 'error': 'server_error'};
    unawaited(c.send('One more thing'));
    await frames(tester, 20);
    expect(find.text('Failed to send ·'), findsOneWidget);
    expect(haptics, <String>['lightImpact'], reason: 'a light tap as it fails');
    await frames(tester, 20);
    expect(haptics, hasLength(1), reason: 'once, not at each build');

    haptics.clear();
    await tester.longPress(inThread('Which course is it about?'));
    await frames(tester, 5);
    expect(haptics, <String>['lightImpact'], reason: 'copied');
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('a reaction under an article: a tick of the phone', (tester) async {
    final server = threadServer();
    server.article = <String, dynamic>{'slug': 'renew', 'title': 'Renewing', 'html': '<p>You can renew early.</p>'};
    usePhone(tester, const Phone('tall', Size(390, 1400)));
    final c = controllerFor(server, FakeChannel());
    await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.article('renew'))));
    await settle(tester, frames: 14);
    final haptics = listenForHaptics(tester);
    await tester.tap(find.text('😃'));
    await frames(tester, 3);
    expect(haptics, <String>['selectionClick']);
  });

  testWidgets('Send: a 36-point circle in its 44-point target, grey with nothing to send, turning to the brand colour over about 180 ms', (tester) async {
    await openThread(tester, threadServer());
    final circle = find.descendant(
      of: find.bySemanticsLabel('Send'),
      matching: find.byWidgetPredicate((w) => w is Ink && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle),
    );
    Color colour() => (tester.widget<Ink>(circle).decoration! as BoxDecoration).color!;
    expect(tester.getSize(circle), const Size(36, 36));
    expect(tester.getSize(find.ancestor(of: circle, matching: find.byWidgetPredicate((w) => w is InkWell)).first), const Size(44, 44), reason: 'the target');
    expect(colour(), Palette.fill, reason: 'nothing to send');
    await tester.enterText(composer(), 'H');
    final seen = <Color>[];
    for (var i = 0; i < 14; i++) {
      await tester.pump(frame);
      seen.add(colour());
    }
    const brand = Color(0xFF1F6FEB);
    expect(seen.last, brand);
    final turning = seen.indexWhere((c) => c == brand);
    expect(turning * 16, inInclusiveRange(150, 210), reason: 'over about 180 ms, not at once: $seen');
    expect(seen.where((c) => c != brand && c != Palette.fill).length, greaterThanOrEqualTo(6), reason: 'through the colours between');
  });

  testWidgets('the CSAT faces as the article\'s: the one chosen grows with a slight overshoot; the others turn grey and fade', (tester) async {
    await openThread(tester, askingServer());
    double scale(String emoji) => tester.widget<ScaleTransition>(find.descendant(of: find.ancestor(of: find.text(emoji), matching: find.byType(AnimatedScale)), matching: find.byType(ScaleTransition))).scale.value;
    await tester.tap(find.text('Great'));
    final grows = <double>[];
    for (var i = 0; i < 20; i++) {
      await tester.pump(frame);
      grows.add(scale('😃'));
    }
    expect(grows.reduce((a, b) => a > b ? a : b), greaterThan(ChoiceFace.grown + 0.005), reason: 'past it, a little: $grows');
    expect(grows.last, closeTo(ChoiceFace.grown, 0.001));
    final others = find.ancestor(of: find.text('😠'), matching: find.byType(ColorFiltered));
    expect(tester.widget<ColorFiltered>(others).colorFilter, const ColorFilter.matrix(<double>[
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0,
    ]), reason: 'grey');
    expect(opacityOf(tester, find.text('😠')), closeTo(0.4, 0.01), reason: 'and faded back');
    expect(opacityOf(tester, find.text('😃')), 1);
  });

  testWidgets('loading: the conversation and the Messages list show their shapes, not spinners', (tester) async {
    final server = threadServer();
    server.hold(<String>['/widget/conversations', '/widget/messages']);
    usePhone(tester, Phone.iphone13);
    final c = controllerOn(server, ManualChannel(autoConnect: true));
    await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.messages)));
    await settle(tester);
    expect(find.byType(MessagesSkeleton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    server.release();
    await tester.pump();
    final fade = <double>[];
    for (var i = 0; i < 16; i++) {
      await tester.pump(frame);
      fade.add(opacityOf(tester, find.text('Anything else?')));
    }
    expect(fade.where((o) => o > 0.02 && o < 0.98).length, greaterThanOrEqualTo(5), reason: 'the list fades in over the skeleton: $fade');
    expect(find.byType(MessagesSkeleton), findsNothing);

    await tester.tap(find.text('Anything else?'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets("the Messages tab's count scales in over 200 ms, with a slight overshoot", (tester) async {
    final server = threadServer();
    usePhone(tester, Phone.iphone13);
    final channel = ManualChannel(autoConnect: true);
    final c = controllerOn(server, channel);
    await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c)));
    await settle(tester, frames: 16);
    final badge = find.ancestor(of: find.text('1'), matching: find.byType(AnimatedScale));
    channel.server('message:created', msg('away', 'agent', 'One more thing.', conversationId: 'conv-2', at: now()));
    await tester.pump();
    double scale() => tester.widget<ScaleTransition>(find.descendant(of: badge.first, matching: find.byType(ScaleTransition)).first).scale.value;
    final seen = <double>[];
    for (var i = 0; i < 16; i++) {
      await tester.pump(frame);
      seen.add(scale());
    }
    expect(seen.first, lessThan(0.4), reason: 'it starts small: $seen');
    expect(seen.reduce((a, b) => a > b ? a : b), greaterThan(1.0), reason: 'past full, a little: $seen');
    expect(seen.indexWhere((s) => s > 0.98) * 16, lessThanOrEqualTo(200));
    expect(seen.last, closeTo(1, 0.001));
  });
}
