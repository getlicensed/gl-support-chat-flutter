import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:gl_support_chat/src/messenger_page.dart';
import 'package:gl_support_chat/src/ui/common.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';
import 'package:gl_support_chat/src/ui/tabs.dart';

import 'support/fakes.dart';
import 'support/phone.dart';

// The messenger on a phone (0.4.5): the keyboard goes away, the latest stays
// in view, it reads in a dark app, back steps back. No simulator: the screens
// are pumped at phone sizes with the keyboard, the notch and the text size a
// phone reports, against the pretend server and socket.
void main() {
  late FakeServer server;
  late FakeChannel channel;

  setUp(() {
    server = FakeServer();
    channel = FakeChannel();
    server.articles = <Map<String, dynamic>>[
      <String, dynamic>{'slug': 'renew-sia', 'title': 'How do I renew my SIA licence?', 'description': 'Three steps, about ten minutes.'},
      <String, dynamic>{'slug': 'id-photo', 'title': 'Taking a good ID photo', 'description': null},
    ];
  });

  final darkApp = ThemeData(brightness: Brightness.dark, colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark));

  List<Map<String, dynamic>> thread([int n = 30]) => <Map<String, dynamic>>[
        for (var i = 0; i < n; i++)
          msg('m$i', i.isEven ? 'visitor' : 'agent', 'Message number $i, about the licence card and when it will arrive.',
              at: DateTime.utc(2026, 10, 6, 9, i).toIso8601String()),
      ];

  String later(int minutes) => DateTime.utc(2026, 10, 6, 11, minutes).toIso8601String();

  Finder page() => find.byType(ConversationPage);
  Finder threadList() => find.descendant(of: page(), matching: find.byType(ListView));
  Finder composer() => find.descendant(of: page(), matching: find.byType(TextField)).last;
  ScrollController scroll(WidgetTester tester) => tester.widget<ListView>(threadList()).controller!;

  bool focused(WidgetTester tester, Finder field) =>
      tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText))).focusNode.hasFocus;

  Color paragraphColor(WidgetTester tester, Finder text) => tester.renderObject<RenderParagraph>(text).text.style!.color!;

  /// The thread's rows on screen, by their text, and where each sits.
  Map<String, int> onScreen(WidgetTester tester) {
    final view = tester.getRect(threadList());
    final rows = <String, int>{};
    for (final e in find.descendant(of: threadList(), matching: find.textContaining('Message number')).evaluate()) {
      final w = e.widget as Text;
      final top = (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy;
      if (top >= view.top && top <= view.bottom) rows[w.data ?? w.textSpan!.toPlainText()] = top.round();
    }
    return rows;
  }

  bool inView(WidgetTester tester, Finder f) {
    if (f.evaluate().isEmpty) return false; // not even built: far off screen
    final r = tester.getRect(f);
    final view = tester.getRect(threadList());
    return r.top >= view.top - 0.5 && r.bottom <= view.bottom + 0.5;
  }

  /// Opens the live conversation with [messages].
  Future<MessengerController> openThread(
    WidgetTester tester, {
    List<Map<String, dynamic>>? messages,
    Phone phone = Phone.iphone13,
    double textScale = 1,
    ThemeData? theme,
  }) async {
    usePhone(tester, phone, textScale: textScale);
    if (messages != null) {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
      server.conversations = <Map<String, dynamic>>[row('conv-1')];
      server.details['conv-1'] = detail('conv-1', messages);
    }
    final c = await openMessenger(tester, server, channel, theme: theme);
    final send = find.text('Send us a message');
    // At a large text size Home's card may be below the fold, not built yet.
    if (send.evaluate().isEmpty) {
      await tester.scrollUntilVisible(send, 200, scrollable: find.descendant(of: find.byType(HomeTab), matching: find.byType(Scrollable)).first);
    }
    await tester.ensureVisible(send);
    await tester.pump();
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    return c;
  }

  void answerSends() {
    channel.answers['visitor:message'] = (data) => <String, dynamic>{
          'ok': true,
          'message': msg('sent-${channel.requests.length}', 'visitor', data['body'] as String, at: later(30)),
        };
  }

  group('the keyboard goes away', () {
    testWidgets('a drag or a tap on the thread puts it away; Send keeps it up', (tester) async {
      await openThread(tester, messages: thread(8));
      await tester.tap(composer());
      await tester.pump();
      expect(focused(tester, composer()), isTrue);

      await tester.drag(threadList(), const Offset(0, 200));
      await settle(tester);
      expect(focused(tester, composer()), isFalse, reason: 'a drag on the thread');

      await tester.tap(composer());
      await tester.pump();
      expect(focused(tester, composer()), isTrue);
      await tester.tapAt(tester.getCenter(threadList()));
      await tester.pump();
      expect(focused(tester, composer()), isFalse, reason: 'a tap on the thread');

      answerSends();
      await tester.enterText(composer(), 'Still there?');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await settle(tester);
      expect(find.text('Still there?'), findsOneWidget);
      expect(focused(tester, composer()), isTrue, reason: 'Send is part of the composer: the keyboard stays for the next line');
    });

    testWidgets('the thread, Messages and Help put it away on a drag; the help search on a tap outside', (tester) async {
      server.articles = <Map<String, dynamic>>[
        for (var i = 0; i < 20; i++) <String, dynamic>{'slug': 'a$i', 'title': 'Article $i', 'description': 'About $i'},
      ];
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
      server.conversations = <Map<String, dynamic>>[row('conv-1')];
      server.details['conv-1'] = detail('conv-1', thread(3));
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, channel, screen: GLSupportChatScreen.help);
      final helpList = find.descendant(of: find.byType(HelpTab), matching: find.byType(ListView));
      expect(tester.widget<ListView>(helpList).keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.onDrag);
      final search = find.descendant(of: find.byType(HelpTab), matching: find.byType(TextField));
      await tester.tap(search);
      await tester.pump();
      expect(focused(tester, search), isTrue);
      await tester.drag(helpList, const Offset(0, -300));
      await settle(tester);
      expect(focused(tester, search), isFalse);

      await tester.tap(find.text('Messages').last);
      await settle(tester);
      final messagesList = find.descendant(of: find.byType(MessagesTab), matching: find.byType(ListView));
      expect(tester.widget<ListView>(messagesList).keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.onDrag);
      await tester.tap(find.text('Hello'));
      await settle(tester);
      expect(tester.widget<ListView>(threadList()).keyboardDismissBehavior, ScrollViewKeyboardDismissBehavior.onDrag);
    });
  });

  group('the latest stays in view', () {
    testWidgets("the customer's own message always comes into view", (tester) async {
      await openThread(tester, messages: thread());
      final s = scroll(tester);
      s.jumpTo(900);
      await settle(tester);
      expect(inView(tester, find.text('Message number 29, about the licence card and when it will arrive.')), isFalse);

      answerSends();
      await tester.enterText(composer(), 'Is it on its way?');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await settle(tester);
      expect(s.offset, 0);
      expect(inView(tester, find.text('Is it on its way?')), isTrue);
    });

    testWidgets('a reply while reading further up: the place is kept, and a pill takes them down', (tester) async {
      await openThread(tester, messages: thread());
      final s = scroll(tester);
      await tester.drag(threadList(), const Offset(0, 600));
      await settle(tester);
      final before = onScreen(tester);
      expect(before, isNotEmpty);

      channel.server('message:created', msg('reply', 'agent', 'A reply while you read.', at: later(1)));
      await tester.pump();
      expect(onScreen(tester), before, reason: 'not a pixel moved, in the very next frame');
      expect(find.text('New message'), findsOneWidget);
      await settle(tester);
      expect(onScreen(tester), before);

      // An AI answer typing out below does not push the reader either.
      channel.server('ai:stream_start', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'authorName': 'GL Assistant'});
      for (var i = 0; i < 6; i++) {
        channel.server('ai:stream_chunk', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'delta': 'More words of the answer, line after line. '});
        await tester.pump(const Duration(milliseconds: 100));
      }
      channel.server('ai:stream_end', <String, dynamic>{'conversationId': 'conv-1', 'streamId': 's1', 'messageId': 'ai-1'});
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(onScreen(tester), before);
      expect(find.text('New messages'), findsOneWidget, reason: 'two now');

      await tester.tap(find.text('New messages'));
      await settle(tester);
      expect(s.offset, 0);
      expect(find.textContaining('New message'), findsNothing);
      expect(inView(tester, find.textContaining('More words of the answer')), isTrue);
    });

    testWidgets('a reply for a reader at (or near) the latest comes into view, with no pill', (tester) async {
      await openThread(tester, messages: thread());
      final s = scroll(tester);
      channel.server('message:created', msg('r1', 'agent', 'First reply.', at: later(1)));
      await settle(tester);
      expect(s.offset, 0);
      expect(inView(tester, find.text('First reply.')), isTrue);

      s.jumpTo(60);
      await tester.pump();
      channel.server('message:created', msg('r2', 'agent', 'Second reply.', at: later(2)));
      await settle(tester);
      expect(s.offset, 0);
      expect(inView(tester, find.text('Second reply.')), isTrue);
      expect(find.textContaining('New message'), findsNothing);
    });

    testWidgets('a photo row keeps its state when rows are added below it', (tester) async {
      await openThread(tester, messages: <Map<String, dynamic>>[
        msg('p', 'agent', '[Photo]', attachments: <Object?>[
          <String, dynamic>{'name': 'card.jpg', 'url': 'upload://11111111-2222-3333-4444-555555555555', 'contentType': 'image/jpeg'},
        ]),
        msg('t', 'visitor', 'Thanks', at: later(0)),
      ]);
      final photo = find.byType(FutureBuilder<Uint8List>);
      final before = tester.state(photo);
      channel.server('message:created', msg('n', 'agent', 'Anything else?', at: later(1)));
      await settle(tester);
      expect(identical(tester.state(photo), before), isTrue, reason: 'keyed rows: not rebuilt as its neighbour, so no reload and no flash');
    });

    testWidgets('a photo just sent shows at once when it goes through — no spinner in between', (tester) async {
      final held = _HeldChannel();
      channel = held;
      final c = await openThread(tester, messages: thread(4));
      channel.answers['visitor:message'] = (data) => <String, dynamic>{
            'ok': true,
            'message': msg('photo-1', 'visitor', '[Photo]', at: later(5), attachments: <Object?>[
              <String, dynamic>{'name': 'p.png', 'url': 'upload://${(data['attachments'] as List<Object?>).first}', 'contentType': 'image/png'},
            ]),
          };
      unawaited(c.send('', image: Uint8List.fromList(_png), imageName: 'p.png', imageType: 'image/png'));
      // On its way for a few frames, as an upload on a phone is.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.outgoing, hasLength(1));
      held.release();
      // Frame by frame, to the first one that draws the confirmed bubble.
      final confirmed = find.byKey(const ValueKey<String>('msg:photo-1'));
      for (var i = 0; i < 40 && confirmed.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 5));
      }
      expect(confirmed, findsWidgets);
      expect(find.descendant(of: threadList(), matching: find.byType(CircularProgressIndicator)), findsNothing);
      expect(find.descendant(of: threadList(), matching: find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage)), findsOneWidget);
    });
  });

  group('readable whatever the app', () {
    testWidgets('a dark app theme: typed text and hints read at 4.5:1 or better', (tester) async {
      await openThread(tester, messages: thread(4), theme: darkApp);
      expect(Theme.of(tester.element(threadList())).brightness, Brightness.light);
      expect(contrast(DefaultTextStyle.of(tester.element(threadList())).style.color!, Colors.white), greaterThanOrEqualTo(4.5));

      final fill = tester.widget<TextField>(composer()).decoration!.fillColor!;
      await tester.enterText(composer(), 'Can you see what I am typing?');
      await tester.pump();
      final typed = tester.widget<EditableText>(find.descendant(of: composer(), matching: find.byType(EditableText))).style.color!;
      expect(contrast(typed, fill), greaterThanOrEqualTo(4.5));
      await tester.enterText(composer(), '');
      await tester.pump();
      expect(contrast(paragraphColor(tester, find.text('Type a message…')), fill), greaterThanOrEqualTo(4.5));
    });

    testWidgets('a dark app theme: the help search, its hint and the fallback screen read too', (tester) async {
      usePhone(tester, Phone.iphone13);
      await openMessenger(tester, server, channel, screen: GLSupportChatScreen.help, theme: darkApp);
      final search = find.descendant(of: find.byType(HelpTab), matching: find.byType(TextField));
      final fill = tester.widget<TextField>(search).decoration!.fillColor!;
      expect(contrast(paragraphColor(tester, find.text('Search for help').last), fill), greaterThanOrEqualTo(4.5));
      await tester.enterText(search, 'renew');
      await tester.pump();
      final typed = tester.widget<EditableText>(find.descendant(of: search, matching: find.byType(EditableText))).style.color!;
      expect(contrast(typed, fill), greaterThanOrEqualTo(4.5));

      await tester.pumpWidget(const SizedBox());
      server.authStatus = 500;
      await openMessenger(tester, server, channel, theme: darkApp);
      expect(find.text("We can't open the chat right now"), findsOneWidget);
      expect(contrast(paragraphColor(tester, find.text("We can't open the chat right now")), Colors.white), greaterThanOrEqualTo(4.5));
    });

    testWidgets('names, times and ticks read at 4.5:1 or better', (tester) async {
      await openThread(tester, messages: <Map<String, dynamic>>[
        msg('a', 'agent', 'Your card is in the post.', at: later(0)),
        msg('b', 'visitor', 'Thank you!', at: later(1)),
      ]);
      expect(contrast(paragraphColor(tester, find.textContaining('Levi John ·')), Colors.white), greaterThanOrEqualTo(4.5));
      final tick = find.byIcon(Icons.done);
      expect(contrast(tester.widget<Icon>(tick).color!, Colors.white), greaterThanOrEqualTo(4.5));
      final time = find.descendant(of: find.ancestor(of: tick, matching: find.byType(Row)).first, matching: find.byType(Text));
      expect(contrast(paragraphColor(tester, time), Colors.white), greaterThanOrEqualTo(4.5));
      // The header's status line, on the brand colour (#1F6FEB here). The
      // server says who is online as the connection comes up.
      channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 1});
      await tester.pump();
      final status = find.descendant(of: page(), matching: find.text('Active now'));
      expect(contrast(paragraphColor(tester, status), const Color(0xFF1F6FEB)), greaterThanOrEqualTo(4.5));
    });
  });

  testWidgets('with the keyboard up on a phone the away form is one line, and a tap opens it', (tester) async {
    server.session = <String, dynamic>{
      ...server.session,
      'officeHours': <String, dynamic>{'open': false, 'opensLabel': 'tomorrow at 9am', 'awayMessage': 'We are away right now.'},
    };
    await openThread(tester, messages: thread(4), phone: Phone.iphoneSE);
    channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 0});
    await tester.pump();
    expect(find.text('Your email for follow-up'), findsOneWidget, reason: 'keyboard down: the whole form');

    setKeyboard(tester, Phone.iphoneSE, 260);
    await tester.pump();
    final line = find.text("We're away — leave your email for a reply");
    expect(line, findsOneWidget);
    expect(find.text('Your email for follow-up'), findsNothing);
    final lineBox = find.ancestor(of: line, matching: find.byType(InkWell)).first;
    expect(tester.getSize(lineBox).height, inInclusiveRange(44, 48));

    await tester.tap(find.text('Add email'));
    await settle(tester, frames: 3);
    final email = find.ancestor(of: find.text('Your email for follow-up'), matching: find.byType(TextField));
    expect(email, findsOneWidget);
    expect(focused(tester, email), isTrue, reason: 'the keyboard moves to the email');

    await tester.tap(composer());
    await tester.pump();
    expect(line, findsOneWidget, reason: 'back to the message: one line again');

    // A tablet has room for the form even with the keyboard up.
    setKeyboard(tester, Phone.iphoneSE, 0);
    tester.view.physicalSize = const Size(820, 1180) * 3;
    setKeyboard(tester, const Phone('tablet', Size(820, 1180)), 400);
    await tester.pump();
    expect(find.text('Your email for follow-up'), findsOneWidget);
  });

  testWidgets('a link is a run of its sentence with a tap recogniser, scaled once with it', (tester) async {
    await openThread(tester, textScale: 1.3, messages: <Map<String, dynamic>>[
      msg('a', 'agent', 'Track it in [your SIA account](https://www.gov.uk/sia) today.', at: later(0)),
    ]);
    final paragraph = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'Track it in your SIA account today.');
    expect(paragraph, findsOneWidget, reason: 'one paragraph: the link wraps with the sentence');
    final rich = tester.widget<RichText>(paragraph);
    expect(rich.textScaler.scale(10), closeTo(13, 0.001));
    var widgetSpans = 0;
    TextSpan? link;
    rich.text.visitChildren((span) {
      if (span is WidgetSpan) widgetSpans++;
      if (span is TextSpan && span.text == 'your SIA account') link = span;
      return true;
    });
    expect(widgetSpans, 0);
    expect(link!.recognizer, isA<TapGestureRecognizer>());
    expect(link!.style?.fontSize, isNull, reason: 'the size comes from the sentence, so the text scale applies once');

    // A tap on the link's own words reaches it (in place of opening the
    // browser, which a test cannot).
    final recognizer = link!.recognizer! as TapGestureRecognizer;
    var tapped = false;
    recognizer.onTap = () => tapped = true;
    final text = tester.renderObject<RenderParagraph>(paragraph);
    const start = 'Track it in '.length;
    final words = text.getBoxesForSelection(const TextSelection(baseOffset: start, extentOffset: start + 'your SIA account'.length));
    await tester.tapAt(text.localToGlobal(words.first.toRect().center));
    expect(tapped, isTrue);
  });

  testWidgets('a link the URL parser refuses stays text: the message is read, never an error box', (tester) async {
    await openThread(tester, messages: <Map<String, dynamic>>[
      msg('a', 'agent', 'Book here: https://[booking-link] and log in at https://portal.example.com:login today.', at: later(0)),
      msg('b', 'agent', 'Or see https://www.gov.uk/sia for the rules.', at: later(1)),
    ]);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('Book here: https://[booking-link] and log in at https://portal.example.com:login today.', findRichText: true), findsOneWidget);
    TextSpan? link;
    tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Or see'))).text.visitChildren((span) {
      if (span is TextSpan && span.text == 'https://www.gov.uk/sia') link = span;
      return true;
    });
    expect(link?.recognizer, isA<TapGestureRecognizer>(), reason: 'a good link beside them still opens');
  });

  testWidgets('a file the team sends takes taps on 44 points, not the 20 of its line', (tester) async {
    await openThread(tester, messages: <Map<String, dynamic>>[
      msg('a', 'agent', '[Document]', at: later(0), attachments: <Object?>[
        <String, dynamic>{'name': 'Application-confirmation-letter-Ayesha-Khan.pdf', 'url': 'https://files.test/letter.pdf', 'contentType': 'application/pdf'},
      ]),
    ]);
    final chip = find.ancestor(of: find.text('Application-confirmation-letter-Ayesha-Khan.pdf'), matching: find.byType(InkWell)).first;
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('at text size 2.0 one line of text is a one-line box', (tester) async {
    await openThread(tester, messages: thread(4), phone: Phone.iphoneSE, textScale: 2.0);
    setKeyboard(tester, Phone.iphoneSE, Phone.iphoneSE.keyboard);
    await tester.enterText(composer(), 'Hello?');
    await settle(tester, frames: 3);
    // Two lines of the hint held it at about 166 points.
    expect(tester.getSize(composer()).height, lessThan(90));
    expect(tester.takeException(), isNull);
  });

  testWidgets("Home's dot is grey until the connection is up, as the chat header's", (tester) async {
    channel = _NeverConnects();
    usePhone(tester, Phone.iphone13);
    final c = await openMessenger(tester, server, channel);
    StatusDot dot() => tester.widget<StatusDot>(find.descendant(of: find.byType(HomeTab), matching: find.byType(StatusDot)));
    expect(c.connected, isFalse);
    expect(dot().away, isTrue, reason: 'nobody is known online yet');
    channel.server('connect', null);
    channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 1});
    await tester.pump();
    expect(dot().away, isFalse);
  });

  testWidgets('Back, Close, chips and Send take taps on at least 44 × 44', (tester) async {
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel);
    Finder button(String tooltip) => find.byWidgetPredicate((w) => w is RoundIconButton && w.tooltip == tooltip);
    void atLeast44(Finder f) {
      final size = tester.getSize(f);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }

    atLeast44(button('Close'));
    await tester.tap(find.text('Messages'));
    await settle(tester);
    atLeast44(find.descendant(of: find.byType(MessagesTab), matching: button('Close')));

    await tester.tap(find.text('Home'));
    await settle(tester);
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    atLeast44(find.descendant(of: page(), matching: button('Back')));
    atLeast44(find.descendant(of: page(), matching: button('Close')));
    expect(tester.getSize(find.ancestor(of: find.text('How do I renew my licence?'), matching: find.byType(InkWell)).first).height, greaterThanOrEqualTo(44));
    atLeast44(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(InkWell)).first);

    // A thumb beside the drawn circle still counts.
    final back = tester.getRect(find.descendant(of: page(), matching: button('Back')));
    await tester.tapAt(back.topLeft + const Offset(2, 2));
    await settle(tester);
    expect(page(), findsNothing);
  });

  group('back steps back', () {
    Future<void> systemBack(WidgetTester tester) async {
      final message = const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/navigation', message, (_) {});
      await settle(tester);
    }

    int tab(WidgetTester tester) => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

    testWidgets("Android's back: conversation → the list → the first tab → out", (tester) async {
      server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
      server.conversations = <Map<String, dynamic>>[row('conv-1')];
      server.details['conv-1'] = detail('conv-1', thread(3));
      usePhone(tester, Phone.android360);
      await openMessenger(tester, server, channel);
      await tester.tap(find.text('Messages'));
      await settle(tester);
      await tester.tap(find.text('Hello'));
      await settle(tester);
      expect(page(), findsOneWidget);

      await systemBack(tester);
      expect(page(), findsNothing);
      expect(tab(tester), 1, reason: 'back on the list');
      await systemBack(tester);
      expect(find.byType(MessengerTabs), findsOneWidget);
      expect(tab(tester), 0, reason: 'then Home, still in the messenger');
      await systemBack(tester);
      expect(find.byType(MessengerTabs), findsNothing);
      expect(find.text('Open support'), findsOneWidget, reason: 'then out, to the app');
    });

    testWidgets('opened on Help, back closes it at once', (tester) async {
      usePhone(tester, Phone.android360);
      await openMessenger(tester, server, channel, screen: GLSupportChatScreen.help);
      await systemBack(tester);
      expect(find.byType(MessengerTabs), findsNothing);
    });

    testWidgets('iOS: a swipe from the left edge steps back from a conversation', (tester) async {
      await openThread(tester, messages: thread(3));
      expect(ModalRoute.of(tester.element(page())), isA<CupertinoPageRoute<void>>());
      final swipe = await tester.startGesture(const Offset(5, 400));
      for (var i = 0; i < 10; i++) {
        await swipe.moveBy(const Offset(30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await settle(tester);
      expect(page(), findsNothing);
      expect(find.byType(MessengerTabs), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  });

  testWidgets('the status bar matches the header under it', (tester) async {
    usePhone(tester, Phone.iphone13);
    await openMessenger(tester, server, channel);
    SystemUiOverlayStyle style(Finder of) =>
        tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.descendant(of: of, matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first).value;
    // Home's top is the brand blue: light icons; nothing painted behind them.
    expect(style(find.byType(MessengerTabs)).statusBarIconBrightness, Brightness.light);
    expect(style(find.byType(MessengerTabs)).statusBarBrightness, Brightness.dark);
    expect(style(find.byType(MessengerTabs)).statusBarColor, const Color(0x00000000));
    await tester.tap(find.text('Help'));
    await settle(tester);
    expect(style(find.byType(MessengerTabs)).statusBarIconBrightness, Brightness.dark, reason: 'a white header: dark icons');
    await tester.tap(find.text('Home'));
    await settle(tester);
    await tester.tap(find.text('Send us a message'));
    await settle(tester);
    expect(style(page()).statusBarIconBrightness, Brightness.light);
  });

  group('the small things', () {
    void closedWithCsat() {
      server.conversations = <Map<String, dynamic>>[row('old', open: false, body: 'Your refund has gone through.')];
      server.details['old'] = detail('old', <Map<String, dynamic>>[
        msg('a', 'visitor', 'Can I have a refund?', conversationId: 'old', at: later(0)),
        msg('b', 'agent', 'Your refund has gone through.', conversationId: 'old', at: later(1)),
        msg('c', 'bot', 'How would you rate the help you received?', conversationId: 'old', at: later(2), meta: <String, dynamic>{
          'csat': <String, dynamic>{'ratingId': 'r1'},
        }),
      ], open: false);
    }

    Future<void> openClosed(WidgetTester tester) async {
      await openMessenger(tester, server, channel);
      await tester.tap(find.text('Messages'));
      await settle(tester);
      await tester.tap(find.text('Your refund has gone through.'));
      await settle(tester);
    }

    testWidgets('CSAT labels stay whole at text size 2.0', (tester) async {
      closedWithCsat();
      usePhone(tester, Phone.iphone13, textScale: 2.0);
      await openClosed(tester);
      for (final label in <String>['Terrible', 'Bad', 'OK', 'Great', 'Amazing']) {
        expect(tester.getSize(find.text(label)).height, lessThan(11 * 2.0 * 1.6), reason: '$label on one line');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets("the closed conversation's footer steps aside while the CSAT comment is typed", (tester) async {
      closedWithCsat();
      usePhone(tester, Phone.iphone13);
      await openClosed(tester);
      expect(find.text('This conversation has ended'), findsOneWidget);
      setKeyboard(tester, Phone.iphone13, 336);
      await tester.pump();
      expect(find.text('This conversation has ended'), findsNothing);
      setKeyboard(tester, Phone.iphone13, 0);
      await tester.pump();
      expect(find.text('This conversation has ended'), findsOneWidget);
    });

    testWidgets('a past conversation that failed to load offers Try again', (tester) async {
      server.conversations = <Map<String, dynamic>>[row('old', open: false, body: 'Your refund has gone through.')];
      usePhone(tester, Phone.iphone13);
      await openClosed(tester);
      expect(find.text('This conversation could not be loaded.'), findsOneWidget);
      closedWithCsat();
      await tester.tap(find.text('Try again'));
      await settle(tester);
      expect(find.text('Can I have a refund?'), findsOneWidget);
    });

    testWidgets('on its side, the thread and the composer keep clear of the notch', (tester) async {
      await openThread(tester, messages: thread(4), phone: Phone.landscape);
      const side = 47.0;
      final width = Phone.landscape.size.width;
      expect(tester.getRect(threadList()).left, greaterThanOrEqualTo(side));
      expect(tester.getRect(threadList()).right, lessThanOrEqualTo(width - side));
      expect(tester.getRect(find.byTooltip('Send a photo')).left, greaterThanOrEqualTo(side));
      expect(tester.getRect(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(InkWell)).first).right, lessThanOrEqualTo(width - side));
    });
  });

  testWidgets('while connecting: Send works, "Active now" waits, and the bar shows only if it is slow', (tester) async {
    channel = _NeverConnects();
    final c = await openThread(tester, messages: thread(3));
    expect(c.link, LinkState.connecting);
    expect(find.descendant(of: page(), matching: find.text('Active now')), findsNothing);
    expect(find.descendant(of: page(), matching: find.text('Typically replies in a few minutes')), findsOneWidget);
    expect(find.text('Connecting…'), findsNothing, reason: 'not a flash on every open');
    await tester.pump(ConnectionBar.patience);
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);

    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add_photo_alternate_outlined)).onPressed, isNotNull);
    answerSends();
    await tester.enterText(composer(), 'Hello while connecting');
    await tester.pump();
    expect(tester.widget<InkWell>(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(InkWell)).first).onTap, isNotNull);
    await tester.tap(find.bySemanticsLabel('Send'));
    await settle(tester);
    expect(find.text('Hello while connecting'), findsOneWidget, reason: 'on screen: on its way, or sent');
    expect(tester.widget<EditableText>(find.descendant(of: composer(), matching: find.byType(EditableText))).controller.text, isEmpty);

    expect(channel.requests.where((r) => r.$1 == 'visitor:message'), isEmpty, reason: 'held until connected');

    channel.server('connect', null);
    await tester.pump();
    expect(channel.requests.where((r) => r.$1 == 'visitor:message').map((r) => r.$2['body']), <Object?>['Hello while connecting'],
        reason: 'sent once connected, once');
    // Connected, and the server says who is online (as it does on connect).
    channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 1});
    await tester.pump();
    expect(find.descendant(of: page(), matching: find.text('Active now')), findsOneWidget);
    expect(find.text('Connecting…'), findsNothing);
    channel.server('disconnect', 'transport close');
    await tester.pump();
    expect(find.text('Reconnecting…'), findsOneWidget, reason: 'a drop shows at once');
    expect(find.descendant(of: page(), matching: find.text('Active now')), findsNothing, reason: 'nobody is known online while reconnecting');
  });

  testWidgets('what was typed and not sent is in the composer at the next open — and gone once someone else signs in', (tester) async {
    usePhone(tester, Phone.iphone13);
    server.openInfo = <String, dynamic>{'conversationId': 'conv-1', 'unreadCount': 0};
    server.conversations = <Map<String, dynamic>>[row('conv-1')];
    server.details['conv-1'] = detail('conv-1', thread(3));
    // One controller across opens, as GLSupportChat keeps it for the same customer.
    final c = controllerFor(server, channel);
    String typed() => tester.widget<EditableText>(find.descendant(of: composer(), matching: find.byType(EditableText))).controller.text;
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c, screen: GLSupportChatScreen.conversation('conv-1'))));
      await settle(tester);
    }

    await open();
    expect(typed(), isEmpty);
    await tester.enterText(composer(), 'My licence number is');
    await tester.pump();
    await tester.pumpWidget(const SizedBox()); // closed

    await open();
    expect(typed(), 'My licence number is');
    expect(tester.widget<InkWell>(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(InkWell)).first).onTap, isNotNull,
        reason: 'Send is ready for it');
    await tester.pumpWidget(const SizedBox());

    c.reset(); // a sign-out, or someone else signing in
    await open();
    expect(typed(), isEmpty, reason: 'never the customer before');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a chip tapped with words in the box sends the chip; the words are still there at the next open', (tester) async {
    usePhone(tester, Phone.iphone13);
    answerSends();
    final c = controllerFor(server, channel);
    String typed() => tester.widget<EditableText>(find.descendant(of: composer(), matching: find.byType(EditableText))).controller.text;
    Future<void> open() async {
      await tester.pumpWidget(MaterialApp(home: GLSupportChatPage(controller: c)));
      await settle(tester);
      await tester.tap(find.text('Send us a message'));
      await settle(tester);
    }

    await open();
    await tester.enterText(composer(), 'My licence number is 1234');
    await tester.pump();
    await tester.tap(find.text('How do I renew my licence?'));
    await settle(tester);
    expect(channel.requests.where((r) => r.$1 == 'visitor:message').map((r) => r.$2['body']), <Object?>['How do I renew my licence?']);
    expect(typed(), 'My licence number is 1234');
    await tester.pumpWidget(const SizedBox()); // closed

    await open();
    expect(typed(), 'My licence number is 1234', reason: 'never sent, so kept');
    await tester.tap(find.bySemanticsLabel('Send'));
    await settle(tester);
    await tester.pumpWidget(const SizedBox());

    await open();
    expect(typed(), isEmpty, reason: 'sent: gone from the box');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('every phone, with and without the keyboard, at 1.0, 1.3 and 2.0, in a dark app: nothing overflows, the composer sits above the keyboard', (tester) async {
    for (final phone in Phone.all) {
      for (final scale in <double>[1.0, 1.3, 2.0]) {
        for (final keyboard in <bool>[false, true]) {
          final what = '${phone.name} at $scale${keyboard ? ' with the keyboard' : ''}';
          await tester.pumpWidget(const SizedBox());
          server = FakeServer();
          channel = FakeChannel();
          server.session = <String, dynamic>{
            ...server.session,
            'officeHours': <String, dynamic>{'open': false, 'opensLabel': 'tomorrow at 9am', 'awayMessage': 'We are away right now.'},
          };
          await openThread(tester, messages: thread(6), phone: phone, textScale: scale, theme: darkApp);
          channel.server('presence:update', <String, dynamic>{'orgId': 'o', 'agentsOnline': 0});
          if (keyboard) {
            setKeyboard(tester, phone, phone.keyboard);
            // A long message: the composer grows to its five lines.
            await tester.enterText(composer(), List<String>.filled(7, 'A line of my message').join('\n'));
          }
          await settle(tester, frames: 3);
          expect(tester.takeException(), isNull, reason: what);
          final bottom = tester.getRect(find.ancestor(of: find.byIcon(Icons.arrow_upward), matching: find.byType(InkWell)).first).bottom;
          expect(bottom, lessThanOrEqualTo(phone.size.height - (keyboard ? phone.keyboard : 0) + 0.5), reason: what);
        }
      }
    }
  });
}

/// A connection whose answer to a message waits for [release], as a server
/// across a phone network does.
class _HeldChannel extends FakeChannel {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<Map<String, dynamic>> request(String event, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 20)}) async {
    if (event == 'visitor:message') await _gate.future;
    return super.request(event, data, timeout: timeout);
  }
}

/// A connection that stays "connecting" until the test says otherwise.
class _NeverConnects extends FakeChannel {
  @override
  void connect() => connects++;
}

/// A 1 × 1 PNG.
const _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
