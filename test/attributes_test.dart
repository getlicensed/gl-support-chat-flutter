import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// What `login` puts in the sign-in body: a signed identity with its hash, an
// unverified one without, and the changed details at every login. Run with
// `flutter test test/attributes_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> authBodies;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    authBodies = <Map<String, dynamic>>[];
    GLSupportChat.debugOverride(
      client: MockClient((http.Request req) async {
        final json = <String, String>{'content-type': 'application/json'};
        if (req.url.path == '/widget/auth') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          authBodies.add(body);
          return http.Response(
            jsonEncode(<String, dynamic>{
              'token': 't',
              'visitorId': 'visitor-1',
              // As the server: set when it accepted an identity, null for an anonymous sign-in.
              'identified': body.containsKey('identity') ? <String, dynamic>{'name': null, 'type': null} : null,
            }),
            200,
            headers: json,
          );
        }
        return http.Response(jsonEncode(<String, dynamic>{'unreadCount': 0}), 200, headers: json);
      }),
    );
    await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'p1', appId: 'com.example.app');
    await GLSupportChat.logout();
  });

  test('a signed identity is sent with its hash', () async {
    final identity = GLSupportChatIdentity.tryParse(<String, dynamic>{
      'id': 'learner:1',
      'hash': 'h',
      'email': 'a@b.co',
      'name': 'Ayesha Khan',
    })!;
    expect(await GLSupportChat.login(identity), isTrue);

    expect(authBodies.single['identity'], <String, dynamic>{
      'id': 'learner:1',
      'email': 'a@b.co',
      'name': 'Ayesha Khan',
      'hash': 'h',
    });
  });

  test('every login sends the identity again, with what changed since', () async {
    final first = GLSupportChatIdentity.tryParse(<String, dynamic>{
      'id': 'learner:1',
      'hash': 'h1',
      'name': 'Ayesha Khan',
      'booking_ref': 'A-1041',
    })!;
    expect(await GLSupportChat.login(first), isTrue);

    // The profile was fetched again: a new name (signed again by the backend), new details.
    final second = GLSupportChatIdentity.tryParse(<String, dynamic>{'id': 'learner:1', 'hash': 'h2', 'name': 'Ayesha Malik'})!
        .withExtra(<String, Object?>{'booking_ref': 'A-1042', 'staffing_id': 7});
    expect(await GLSupportChat.login(second), isTrue);

    expect(authBodies, hasLength(2));
    expect(authBodies.last['identity'], <String, dynamic>{
      'booking_ref': 'A-1042',
      'staffing_id': '7',
      'id': 'learner:1',
      'name': 'Ayesha Malik',
      'hash': 'h2',
    });
    expect(authBodies.last['visitorId'], 'visitor-1', reason: 'the same phone, the same visitor');
  });

  test('tryParse(data) then login(identity) sends an unverified identity without a hash', () async {
    final data = <String, dynamic>{
      'id': '220657',
      'email': 'ayesha@example.com',
      'name': 'Ayesha Khan',
      'phone': '07700 900123',
      'type': 'learner',
    };
    final identity = GLSupportChatIdentity.tryParse(data);
    expect(identity, isNotNull);
    expect(identity!.isVerified, isFalse);

    await GLSupportChat.login(identity);

    expect(authBodies, hasLength(1));
    expect(authBodies.single['identity'], <String, dynamic>{
      'id': '220657',
      'email': 'ayesha@example.com',
      'name': 'Ayesha Khan',
      'phone': '07700 900123',
      'type': 'learner',
    });
    expect((authBodies.single['identity'] as Map<String, dynamic>).containsKey('hash'), isFalse);
  });

  test('the whole map from tryParse(data) goes inside the identity, with no separate attributes', () async {
    final data = <String, dynamic>{
      'id': '220657',
      'email': 'ayesha@example.com',
      'name': 'Ayesha Khan',
      'system_version': 'Android 14',
      'version': 'SDK 34',
      'manufacturer': 'samsung',
      'model': 'SM-S918B',
      'booking_first_name': 'Ayesha',
      'booking_last_name': 'Khan',
    };
    final identity = GLSupportChatIdentity.tryParse(data)!;
    await GLSupportChat.login(identity);

    expect(authBodies.single['identity'], data);
    expect(authBodies.single.containsKey('attributes'), isFalse);
  });

  test('a refused identity falls back to an anonymous sign-in', () async {
    var calls = 0;
    GLSupportChat.debugOverride(
      client: MockClient((http.Request req) async {
        final json = <String, String>{'content-type': 'application/json'};
        if (req.url.path == '/widget/auth') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          authBodies.add(body);
          calls++;
          if (body.containsKey('identity')) {
            return http.Response(jsonEncode(<String, dynamic>{'error': 'no', 'code': 'identity_bad_signature'}), 401, headers: json);
          }
          return http.Response(jsonEncode(<String, dynamic>{'token': 't', 'visitorId': 'visitor-1', 'identified': null}), 200, headers: json);
        }
        return http.Response(jsonEncode(<String, dynamic>{'unreadCount': 0}), 200, headers: json);
      }),
    );
    final diagnostics = <String>[];
    await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'p1', onDiagnostic: (event, detail) => diagnostics.add('$event ${detail['code']}'));

    final ok = await GLSupportChat.login(GLSupportChatIdentity.tryParse(<String, dynamic>{'id': '1', 'email': 'a@b.co'})!);

    expect(ok, isFalse, reason: 'refused: the customer is anonymous, so login says so');
    expect(calls, 2, reason: 'refused once, then anonymous');
    expect(authBodies.last.containsKey('identity'), isFalse);
    expect(diagnostics, contains('identity_rejected identity_bad_signature'));
  });
}
