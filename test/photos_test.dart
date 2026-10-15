import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/thread.dart';

// Photos in the thread (0.4.8). Measured on 15 Oct: a photo took its own
// size only once decoded, so the thread jumped when it did — the customer's
// own as it went, and the team's as its bytes came in, after a spinner; a
// photo alone sat on a thick band of the bubble's colour; and every photo was
// decoded whole, up to 2048 pixels wide, to be drawn 240 points wide.

/// A PNG of [w] × [h] pixels.
Future<Uint8List> png(WidgetTester tester, int w, int h) async => (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF4A90D9));
      canvas.drawCircle(Offset(w / 2, h / 2), h / 3, Paint()..color = const Color(0xFFFFD54F));
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }))!;

/// Lets the image codec run (it decodes outside the test's clock).
Future<void> decode(WidgetTester tester) => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));

/// The thread's photos: the box each is drawn in — those just below the
/// view too, where a row that has just come in waits a frame.
Finder photoBoxes() => find.descendant(of: threadList(), matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == 240), skipOffstage: false);

void main() {
  testWidgets("the customer's photo and the team's: one box from the first frame, grey until it loads; nothing moves when it does", (tester) async {
    final server = threadServer();
    final (c, channel) = await openThread(tester, server);
    channel.answers['visitor:message'] = (data) {
      final uploads = (data['attachments'] as List?)?.cast<String>() ?? const <String>[];
      return <String, dynamic>{
        'ok': true,
        'message': msg('sent-1', 'visitor', '[Photo]', at: now(), attachments: <Object?>[
          for (final id in uploads) <String, dynamic>{'name': 'photo.png', 'url': 'upload://$id', 'contentType': 'image/png'},
        ]),
      };
    };
    final ack = channel.holdAcks = Completer<void>();
    server.hold(<String>['/widget/uploads']);
    final above = inThread('You are welcome');
    final bytes = await png(tester, 1200, 900);
    unawaited(c.send('', image: bytes, imageName: 'photo.png', imageType: 'image/png'));
    await tester.pump();
    await tester.pump(frame);
    expect(photoBoxes(), findsOneWidget, reason: 'its box from the first frame');
    expect(tester.getSize(photoBoxes()), const Size(240, 180), reason: '4:3, before anything has loaded');
    await frames(tester, 30); // the thread has glided up to it
    final rest = topOf(tester, above);

    await decode(tester);
    for (var i = 0; i < 12; i++) {
      await tester.pump(frame);
      expect(topOf(tester, above), rest, reason: 'decoded, frame $i: nothing moves');
      expect(tester.getSize(photoBoxes()), const Size(240, 180));
    }
    final image = tester.widget<Image>(find.descendant(of: photoBoxes(), matching: find.byType(Image)));
    expect(image.image, isA<ResizeImage>(), reason: 'decoded at the size it is drawn');
    expect((image.image as ResizeImage).width, 240 * 3, reason: '240 points at 3 pixels a point');
    expect(image.fit, BoxFit.cover);

    server.release();
    await decode(tester);
    await frames(tester, 3);
    ack.complete();
    await frames(tester, 3);
    await decode(tester);
    for (var i = 0; i < 12; i++) {
      await tester.pump(frame);
      expect(topOf(tester, above), rest, reason: "the server's copy takes the row, frame $i: nothing moves");
    }
    expect(photoBoxes(), findsOneWidget);
    expect(tester.getSize(photoBoxes()), const Size(240, 180));

    // A photo alone is the bubble: no band of colour under it.
    final mine = tester.getRect(photoBoxes());
    final bubble = tester.getRect(find.ancestor(of: photoBoxes(), matching: find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).borderRadius != null)).first);
    expect(bubble.bottom - mine.bottom, 0, reason: 'nothing under it');
    expect(bubble.height, mine.height);

    // The team's photo: fetched with the customer's token.
    const id = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    server.files[id] = await png(tester, 900, 1200);
    server.hold(<String>['/widget/files/$id']);
    channel.server('message:created', msg('ph', 'agent', '[Photo]', at: now(), attachments: <Object?>[
      <String, dynamic>{'name': 'card.png', 'url': 'upload://$id', 'contentType': 'image/png'},
    ]));
    await tester.pump();
    // It comes up from just below the view: its box from the first frame it
    // is built in, grey while the bytes come, never a spinner.
    for (var i = 0; i < 30; i++) {
      await tester.pump(frame);
      expect(find.descendant(of: threadList(), matching: find.byType(CircularProgressIndicator), skipOffstage: false), findsNothing, reason: 'no spinner, frame $i');
      if (photoBoxes().evaluate().length == 2) expect(tester.getSize(photoBoxes().last), const Size(240, 180), reason: 'frame $i');
    }
    expect(photoBoxes(), findsNWidgets(2));
    final team = find.descendant(of: threadList(), matching: find.text('Thank you!'));
    final settled = topOf(tester, team);
    final box = tester.getRect(photoBoxes().last);
    server.release();
    await decode(tester);
    await decode(tester);
    for (var i = 0; i < 16; i++) {
      await tester.pump(frame);
      expect(topOf(tester, team), settled, reason: 'its bytes in and decoded, frame $i: nothing moves');
      expect(tester.getRect(photoBoxes().last), box);
    }
    expect(find.descendant(of: photoBoxes().last, matching: find.byType(Image)), findsOneWidget, reason: 'it is there');
  });

  testWidgets('the server says a photo is portrait: the box takes its shape before it loads', (tester) async {
    final server = threadServer();
    server.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
      msg('p', 'agent', '[Photo]', at: ago(3), attachments: <Object?>[
        <String, dynamic>{'name': 'card.jpg', 'url': 'https://cdn.test/card.jpg', 'contentType': 'image/jpeg', 'width': 900, 'height': 1200},
      ]),
    ]);
    await openThread(tester, server);
    expect(tester.getSize(photoBoxes()), const Size(240, 320));
  });
}
