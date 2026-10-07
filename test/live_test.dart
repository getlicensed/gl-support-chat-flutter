import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/client.dart';
import 'package:gl_support_chat/src/core/controller.dart';
import 'package:http/http.dart' as http;

// The package against the REAL API and Socket.IO server — the check the
// pretend server cannot make: that this Socket.IO client and the server's
// speak to each other, and that a photo goes up and comes back.
//
//   in the GL Support Chat server repository (private):
//   cd apps/api && DATABASE_URL=…_test pnpm messenger:live      (prints the two values)
//   GL_LIVE_API=http://127.0.0.1:4100 GL_LIVE_PRODUCT=<id> flutter test test/live_test.dart
//
// Skipped when the two are not set. No widget binding here: it would answer
// every HTTP request with a 400.
void main() {
  final apiUrl = Platform.environment['GL_LIVE_API'];
  final productId = Platform.environment['GL_LIVE_PRODUCT'];
  final skip = apiUrl == null || productId == null ? 'set GL_LIVE_API and GL_LIVE_PRODUCT (the server repository: pnpm messenger:live)' : null;

  Future<void> until(bool Function() ok, String what) async {
    for (var i = 0; i < 100; i++) {
      if (ok()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('timed out waiting for $what');
  }

  test('sign in, go live, send text and a photo, get a reply', () async {
    final api = MessengerApi(apiUrl: apiUrl!, productId: productId!);
    api.reauthenticate = () async => (await api.authenticate()).token;
    const device = <String, String>{'platform': 'ios', 'os': 'iOS 17.4', 'model': 'iPhone 15 Pro', 'appVersion': '3.4.0', 'appBuild': '412'};
    final c = MessengerController(api: api, signIn: () => api.authenticate(device: device));
    await c.start();
    expect(c.phase, MessengerPhase.ready, reason: c.failure);
    await until(() => c.link == LinkState.connected, 'the socket to connect');
    expect(c.agentsOnline, 0, reason: 'presence arrives on connect');

    expect(await c.send('Hello from the Flutter package'), isTrue, reason: c.sendError);
    final conversationId = c.liveId;
    expect(conversationId, isNotNull);
    final seen = jsonDecode((await http.get(Uri.parse('$apiUrl/live/conversation/$conversationId'))).body) as Map<String, dynamic>;
    expect(seen['device'], device, reason: 'the conversation the socket started carries the phone and app');

    // A real 1×1 PNG.
    final png = Uint8List.fromList(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
    expect(await c.send('front of my licence', image: png, imageName: 'licence.png', imageType: 'image/png'), isTrue, reason: c.sendError);
    final photo = c.live.last;
    expect(photo.body, '[Photo] front of my licence', reason: 'stored like WhatsApp media');
    final uploadId = photo.attachments.single.uploadId;
    expect(uploadId, isNotNull);
    expect(await api.file(uploadId!), png, reason: 'the customer reads their own photo back');

    // The team answers, as the inbox does: over the conversation's room.
    final reply = await http.post(Uri.parse('$apiUrl/live/agent-reply'),
        headers: <String, String>{'content-type': 'application/json'}, body: jsonEncode(<String, String>{'conversationId': conversationId!, 'body': 'Thanks — got it.'}));
    expect(reply.statusCode, 200);
    await until(() => c.live.any((m) => m.body == 'Thanks — got it.'), 'the agent reply over the socket');
    expect(c.live.last.authorName, 'Levi John');
    expect(c.totalUnread, 1, reason: 'not on screen, so unread');

    final list = await api.conversations();
    expect(list.first.id, conversationId);
    expect(list.first.lastBody, 'Thanks — got it.');
    final full = await api.conversation(conversationId);
    expect(full.messages.map((m) => m.authorType), <String>['visitor', 'visitor', 'agent']);

    c.setViewingLive(true);
    await until(() => c.totalUnread == 0, 'seen');
    c.dispose();
    api.close();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));
}
