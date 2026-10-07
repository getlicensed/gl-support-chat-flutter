import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// setAttributes: unverified, display-only details that ride along with the
// sign-in. Run with `flutter test test/attributes_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const identity = GLSupportChatIdentity(id: 'learner:1', hash: 'h', email: 'a@b.co', name: 'Ayesha Khan');
  late List<Map<String, dynamic>> authBodies;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authBodies = <Map<String, dynamic>>[];
    GLSupportChat.debugOverride(
      client: MockClient((http.Request req) async {
        final json = <String, String>{'content-type': 'application/json'};
        if (req.url.path == '/widget/auth') {
          authBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          return http.Response(jsonEncode(<String, dynamic>{'token': 't', 'visitorId': 'visitor-1'}), 200, headers: json);
        }
        return http.Response(jsonEncode(<String, dynamic>{'unreadCount': 0}), 200, headers: json);
      }),
    );
    await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'p1', appId: 'com.example.app');
    await GLSupportChat.logout();
  });

  test('attributes set before sign-in travel with it, beside the identity', () async {
    await GLSupportChat.setAttributes(<String, String>{
      'email': 'a@b.co',
      'name': 'Ayesha Khan',
      'booking_id': '220657',
    });
    expect(authBodies, isEmpty, reason: 'not signed in yet, so no request');

    await GLSupportChat.login(identity);

    expect(authBodies, hasLength(1));
    expect(authBodies.single['attributes'], <String, dynamic>{
      'email': 'a@b.co',
      'name': 'Ayesha Khan',
      'booking_id': '220657',
    });
    expect((authBodies.single['identity'] as Map<String, dynamic>)['id'], 'learner:1');
  });

  test('changing attributes while signed in sends them at once', () async {
    await GLSupportChat.login(identity);
    expect(authBodies.single.containsKey('attributes'), isFalse);

    await GLSupportChat.setAttributes(<String, String>{'booking_id': '220657'});
    expect(authBodies, hasLength(2));
    expect(authBodies.last['attributes'], <String, dynamic>{'booking_id': '220657'});

    await GLSupportChat.setAttributes(<String, String>{'booking_id': '220657'});
    expect(authBodies, hasLength(2), reason: 'unchanged, nothing to send');
  });

  test('blank keys and values are dropped and the map is capped', () async {
    final many = <String, String>{
      ' ': 'blank key',
      'blank_value': '  ',
      for (var i = 0; i < 30; i++) 'k$i': 'v$i',
    };
    await GLSupportChat.setAttributes(many);
    await GLSupportChat.login(identity);

    final sent = authBodies.single['attributes'] as Map<String, dynamic>;
    expect(sent.length, GLSupportChat.maxAttributes);
    expect(sent.containsKey(' '), isFalse);
    expect(sent.containsKey('blank_value'), isFalse);
  });

  test('logout clears them for the next person on the phone', () async {
    await GLSupportChat.setAttributes(<String, String>{'email': 'a@b.co'});
    await GLSupportChat.login(identity);
    await GLSupportChat.logout();
    await GLSupportChat.login(identity);

    expect(authBodies.last.containsKey('attributes'), isFalse);
  });

  test('an empty map clears what was set', () async {
    await GLSupportChat.login(identity);
    await GLSupportChat.setAttributes(<String, String>{'email': 'a@b.co'});
    await GLSupportChat.setAttributes(<String, String>{});

    expect(authBodies.last.containsKey('attributes'), isFalse);
  });
}
