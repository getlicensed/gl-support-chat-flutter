import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/ui/photo_viewer.dart';
// The package's own pretend platform, as url_launcher's tests use: nothing
// is added to the app (url_launcher already brings it).
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fakes.dart';
import 'support/gated.dart';
import 'support/phone.dart';
import 'support/thread.dart';

// Photos and files without leaving the app (0.4.9, from the director's
// feedback). A photo opens full screen, flying from the thread: swipe
// through the conversation's photos, pinch or tap twice to zoom, drag down
// to close. A file the team sent opens in Safari's view or a Custom Tab,
// over the app, not in the browser.

const _front = 'aaaaaaaa-0000-4000-8000-000000000001';
const _back = 'aaaaaaaa-0000-4000-8000-000000000002';
const _sign = 'aaaaaaaa-0000-4000-8000-000000000003';

/// A PNG of [w] × [h] pixels.
Future<Uint8List> _png(WidgetTester tester, int w, int h) async => (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF4A90D9));
      canvas.drawCircle(Offset(w / 2, h / 2), h / 3, Paint()..color = const Color(0xFFFFD54F));
      final image = await recorder.endRecording().toImage(w, h);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }))!;

/// Lets the image codec run (it decodes outside the test's clock).
Future<void> _decode(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(frame);
  }
}

Map<String, dynamic> _photo(String name, String id) => <String, dynamic>{'name': name, 'url': 'upload://$id', 'contentType': 'image/png'};

/// Three photos in a conversation: two the customer sent, one from Levi.
Future<GatedServer> _photos(WidgetTester tester) async {
  final s = threadServer();
  s.files[_front] = await _png(tester, 1200, 900);
  s.files[_back] = await _png(tester, 900, 1200);
  s.files[_sign] = await _png(tester, 800, 800);
  s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
    msg('m1', 'visitor', '[Photo]', at: ago(10), attachments: <Object?>[_photo('licence-front.png', _front)]),
    msg('m2', 'agent', 'Thanks — and the back?', at: ago(9)),
    msg('m3', 'visitor', '[Photo]', at: ago(8), attachments: <Object?>[_photo('licence-back.png', _back)]),
    msg('m4', 'agent', '[Photo]', at: ago(7), attachments: <Object?>[_photo('where-to-sign.png', _sign)]),
  ]);
  return s;
}

const _tall = Phone('tall iPhone', Size(390, 1300));

/// The thread's photos, top to bottom.
List<Finder> _thumbs() {
  final f = find.descendant(of: threadList(), matching: find.byWidgetPredicate((w) => w is SizedBox && w.width == threadPhotoWidth));
  final all = f.evaluate().toList()..sort((a, b) => (a.renderObject! as RenderBox).localToGlobal(Offset.zero).dy.compareTo((b.renderObject! as RenderBox).localToGlobal(Offset.zero).dy));
  return [for (final e in all) find.byElementPredicate((x) => identical(x, e))];
}

Finder _viewer() => find.byType(PhotoViewer);

Future<void> _openOn(WidgetTester tester, int i) async {
  await tester.tap(_thumbs()[i], warnIfMissed: false); // the press is laid over the picture
  await tester.pump();
  await frames(tester, 30);
  await _decode(tester);
}

/// The transform on the photo on screen.
double _scale(WidgetTester tester) =>
    tester.widget<InteractiveViewer>(find.descendant(of: _viewer(), matching: find.byType(InteractiveViewer)).first).transformationController!.value.getMaxScaleOnAxis();

/// How much of the black shows behind the photo.
int _black(WidgetTester tester) {
  final box = tester.widget<ColoredBox>(find.descendant(of: _viewer(), matching: find.byType(ColoredBox)).first);
  return box.color.toARGB32() >>> 24;
}

void main() {
  for (final platform in <TargetPlatform>[TargetPlatform.iOS, TargetPlatform.android]) {
    testWidgets('${platform.name}: a photo opens full screen, flying from the thread; swipe through the photos, each named', (tester) async {
      final server = await _photos(tester);
      await openThread(tester, server, platform: platform, phone: _tall);
      await _decode(tester);
      expect(_thumbs(), hasLength(3));
      final from = tester.getRect(_thumbs()[1]);
      final tag = tester.widget<Hero>(find.ancestor(of: _thumbs()[1], matching: find.byType(Hero))).tag;

      await tester.tap(_thumbs()[1], warnIfMissed: false); // the press is laid over the picture
      await tester.pump();
      await tester.pump(frame);
      final flight = find.byKey(const ValueKey<String>('photo-flight'));
      expect(flight, findsOneWidget, reason: 'the photo flies from the thread');
      final first = tester.getRect(flight);
      expect((first.center - from.center).distance, lessThan(80), reason: 'from where it was: $first, $from');
      var width = first.width;
      for (var i = 0; i < 30 && flight.evaluate().isNotEmpty; i++) {
        await tester.pump(frame);
        if (flight.evaluate().isEmpty) break;
        final w = tester.getRect(flight).width;
        expect(w, greaterThanOrEqualTo(width - 0.5), reason: 'it only grows');
        width = w;
      }
      expect(flight, findsNothing);
      await _decode(tester);
      expect(width, greaterThan(300), reason: 'to the width of the screen');
      expect(find.text('licence-back.png'), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
      final shown = find.descendant(of: _viewer(), matching: find.byType(Hero));
      expect(identical(tester.widget<Hero>(shown).tag, tag), isTrue, reason: "the thread's photo, by its tag");
      final full = tester.getRect(shown);
      expect(full.width, closeTo(390, 1), reason: 'portrait 900 × 1200: the width of the screen');
      expect(full.height, closeTo(520, 1), reason: 'at its own shape, not the thread\'s crop');

      await tester.fling(_viewer(), const Offset(-300, 0), 1500);
      await frames(tester, 30);
      expect(find.text('where-to-sign.png'), findsOneWidget);
      expect(find.text('3 of 3'), findsOneWidget);
      await tester.fling(_viewer(), const Offset(300, 0), 1500);
      await frames(tester, 30);
      await tester.fling(_viewer(), const Offset(300, 0), 1500);
      await frames(tester, 30);
      expect(find.text('licence-front.png'), findsOneWidget);
      expect(find.text('1 of 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tap twice to zoom where tapped, twice again to come back; pinch zooms; zoomed in, a swipe pans and does not turn the page', (tester) async {
    final server = await _photos(tester);
    await openThread(tester, server, phone: _tall);
    await _decode(tester);
    await _openOn(tester, 0);
    expect(_scale(tester), 1);

    final centre = tester.getCenter(_viewer());
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    await frames(tester, 25);
    expect(_scale(tester), closeTo(PhotoViewer.doubleTapScale, 0.01));
    expect(tester.widget<PageView>(find.byType(PageView)).physics, isA<NeverScrollableScrollPhysics>(), reason: 'zoomed: no turning the page');
    await tester.drag(_viewer(), const Offset(-200, 0));
    await frames(tester, 20);
    expect(find.text('1 of 3'), findsOneWidget, reason: 'it panned');

    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(centre);
    await frames(tester, 25);
    expect(_scale(tester), closeTo(1, 0.01));
    expect(tester.widget<PageView>(find.byType(PageView)).physics, isNull);

    // Two fingers, moving apart.
    final a = await tester.startGesture(centre - const Offset(40, 0), pointer: 1);
    final b = await tester.startGesture(centre + const Offset(40, 0), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-12, 0));
      await b.moveBy(const Offset(12, 0));
      await tester.pump(frame);
    }
    await a.up();
    await b.up();
    await frames(tester, 10);
    expect(_scale(tester), greaterThan(1.8), reason: 'pinched');
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('drag down: the black fades with it; let go short, it springs back; past 120 points it closes and flies back', (tester) async {
    final server = await _photos(tester);
    await openThread(tester, server, phone: _tall);
    await _decode(tester);
    await _openOn(tester, 2);
    expect(_black(tester), 255);

    var finger = await tester.startGesture(tester.getCenter(_viewer()));
    for (var i = 0; i < 4; i++) {
      await finger.moveBy(const Offset(0, 20));
      await tester.pump(frame);
    }
    expect(_black(tester), lessThan(230), reason: 'fading as it goes');
    await finger.up();
    await frames(tester, 25);
    expect(_viewer(), findsOneWidget, reason: '80 points: it springs back');
    expect(_black(tester), 255);

    finger = await tester.startGesture(tester.getCenter(_viewer()));
    for (var i = 0; i < 10; i++) {
      await finger.moveBy(const Offset(0, 20));
      await tester.pump(frame);
    }
    await finger.up();
    await tester.pump();
    await tester.pump(frame);
    expect(find.byKey(const ValueKey<String>('photo-flight')), findsOneWidget, reason: 'back to the thread');
    await frames(tester, 30);
    expect(_viewer(), findsNothing);
    expect(page(), findsOneWidget);
  });

  testWidgets('Close closes it; on a phone on its side its bar is clear of the notch', (tester) async {
    final server = await _photos(tester);
    await openThread(tester, server, phone: _tall);
    await _decode(tester);
    await _openOn(tester, 0);
    final close = find.descendant(of: _viewer(), matching: find.byIcon(Icons.close));
    expect(tester.getSize(find.ancestor(of: close, matching: find.byWidgetPredicate((w) => w is InkWell)).first), const Size(44, 44));
    // Turned on its side while open: the bar keeps clear of the notch.
    usePhone(tester, Phone.landscape);
    await frames(tester, 5);
    expect(tester.getRect(close).left, greaterThanOrEqualTo(Phone.landscape.left));
    expect(tester.getRect(find.text('licence-front.png')).right, lessThanOrEqualTo(Phone.landscape.size.width - Phone.landscape.right));
    expect(tester.takeException(), isNull);

    await tester.tap(close);
    await frames(tester, 30);
    expect(_viewer(), findsNothing);
    expect(page(), findsOneWidget);
  });

  group('files', () {
    late _Launcher launcher;

    setUp(() {
      final before = UrlLauncherPlatform.instance;
      launcher = _Launcher();
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = before);
    });

    GatedServer files() {
      final s = threadServer();
      s.details['conv-1'] = detail('conv-1', <Map<String, dynamic>>[
        msg('m1', 'visitor', '[Document]', at: ago(10), attachments: <Object?>[
          <String, dynamic>{'name': 'my-certificate.pdf', 'url': 'upload://$_front', 'contentType': 'application/pdf'},
        ]),
        msg('m2', 'agent', '[Document]', at: ago(9), attachments: <Object?>[
          <String, dynamic>{'name': 'Confirmation-letter.pdf', 'url': 'https://api.test/files/abc.sig', 'contentType': 'application/pdf'},
        ]),
        msg('m3', 'bot', 'Here is the checklist.', at: ago(8), meta: <String, dynamic>{
          'file': <String, dynamic>{'name': 'Checklist.pdf', 'url': 'https://api.test/files/def.sig'},
        }),
        msg('m4', 'agent', 'The rules are at https://www.gov.uk/sia today.', at: ago(7)),
      ]);
      return s;
    }

    testWidgets("the team's PDF and the workflow's file open inside the app (Safari's view, a Custom Tab), not in the browser", (tester) async {
      await openThread(tester, files());
      await tester.tap(find.text('Confirmation-letter.pdf'));
      await tester.pump();
      await tester.tap(find.text('Checklist.pdf'));
      await tester.pump();
      expect(launcher.launched, <(String, PreferredLaunchMode)>[
        ('https://api.test/files/abc.sig', PreferredLaunchMode.inAppBrowserView),
        ('https://api.test/files/def.sig', PreferredLaunchMode.inAppBrowserView),
      ]);
    });

    testWidgets('a phone with no in-app view opens the file outside, as before', (tester) async {
      launcher.inApp = false;
      await openThread(tester, files());
      await tester.tap(find.text('Confirmation-letter.pdf'));
      await tester.pump();
      expect(launcher.launched, <(String, PreferredLaunchMode)>[
        ('https://api.test/files/abc.sig', PreferredLaunchMode.inAppBrowserView),
        ('https://api.test/files/abc.sig', PreferredLaunchMode.externalApplication),
      ]);
    });

    testWidgets("the customer's own PDF has no address to open (it is read with their token): named, as before; a link still opens outside", (tester) async {
      await openThread(tester, files());
      await tester.tap(find.text('my-certificate.pdf'));
      await tester.pump();
      expect(launcher.launched, isEmpty);
      expect(tester.widget<InkWell>(find.ancestor(of: find.text('my-certificate.pdf'), matching: find.byType(InkWell)).first).onTap, isNull);

      _tapLink(tester, 'https://www.gov.uk/sia');
      await tester.pump();
      expect(launcher.launched, <(String, PreferredLaunchMode)>[('https://www.gov.uk/sia', PreferredLaunchMode.externalApplication)]);
    });
  });
}

/// A link in a message, tapped as its words are.
void _tapLink(WidgetTester tester, String url) {
  TextSpan? link;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == url) link = span;
      return true;
    });
  }
  (link!.recognizer! as TapGestureRecognizer).onTap!();
}

/// url_launcher's platform, pretend: what was opened, and how.
class _Launcher extends UrlLauncherPlatform {
  final launched = <(String, PreferredLaunchMode)>[];

  /// Whether this phone has an in-app view (Safari's, a Custom Tab).
  bool inApp = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add((url, options.mode));
    return options.mode != PreferredLaunchMode.inAppBrowserView || inApp;
  }

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> supportsCloseForMode(PreferredLaunchMode mode) async => true;
}
