import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/links.dart';

// The public API and the link helpers — the parts that decide whether a
// customer is stranded.
// Run with `flutter test` at the root of this repository.
void main() {
  // The test binding also answers every HTTP request with a 400, so nothing
  // here ever reaches a real server.
  TestWidgetsFlutterBinding.ensureInitialized();
  const own = 'support-api.get-licensed.co.uk';

  group('messenger URL', () {
    test('the identity travels in the fragment, never the query', () {
      final url = buildMessengerUrl(
        apiUrl: 'https://$own',
        productId: 'p1',
        start: 'home',
        identity: {'id': '12345', 'name': 'José Ørsted', 'hash': 'ab'},
      );
      final uri = Uri.parse(url);
      expect(uri.queryParameters['start'], 'home');
      expect(uri.queryParameters.containsKey('identity'), isFalse);
      expect(uri.fragment, startsWith('identity='));
      final encoded = uri.fragment.substring('identity='.length);
      expect(encoded.contains('='), isFalse, reason: 'unpadded base64url');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded)))) as Map<String, dynamic>;
      expect(decoded['name'], 'José Ørsted');
      expect(decoded['id'], '12345');
    });

    test('no identity, no fragment', () {
      expect(Uri.parse(buildMessengerUrl(apiUrl: 'https://$own', productId: 'p1', start: 'help')).hasFragment, isFalse);
    });

    test('messengerUrl() uses the fragment too', () async {
      await GLSupportChat.configure(apiUrl: 'https://$own/', productId: 'p1');
      // No server in tests: login reports false — and never throws.
      expect(await GLSupportChat.login(const GLSupportChatIdentity(id: '1', hash: 'h')), isFalse);
      final uri = Uri.parse(GLSupportChat.messengerUrl());
      expect(uri.host, own);
      expect(uri.path, '/m/p1');
      expect(uri.query.contains('identity'), isFalse);
      expect(uri.fragment, startsWith('identity='));
      await GLSupportChat.logout();
      expect(Uri.parse(GLSupportChat.messengerUrl()).hasFragment, isFalse);
    });
  });

  group('identity from the backend', () {
    test('a numeric id and nulls are accepted', () {
      final identity = GLSupportChatIdentity.tryParse({'id': 12345, 'email': null, 'phone': '', 'name': 'Ayesha Khan', 'hash': 'abc'});
      expect(identity, isNotNull);
      expect(identity!.id, '12345');
      expect(identity.email, isNull);
      expect(identity.phone, isNull);
      expect(identity.toJson().containsKey('email'), isFalse);
      expect(identity.toJson().containsKey('phone'), isFalse);
    });

    test('nothing usable → null, never an exception', () {
      expect(GLSupportChatIdentity.tryParse(null), isNull);
      expect(GLSupportChatIdentity.tryParse('not a map'), isNull);
      expect(GLSupportChatIdentity.tryParse({'hash': 'abc'}), isNull, reason: 'no id');
      expect(GLSupportChatIdentity.tryParse({'id': '  '}), isNull, reason: 'blank id');
      expect(GLSupportChatIdentity.tryParse({'email': 'a@b.co', 'name': 'Ayesha'}), isNull, reason: 'no id');
    });

    test('no hash is an unverified identity, not an error', () {
      final identity = GLSupportChatIdentity.tryParse({'id': 1, 'email': 'a@b.co'});
      expect(identity, isNotNull);
      expect(identity!.isVerified, isFalse);
      expect(identity.hash, isNull);
      expect(identity.toJson().containsKey('hash'), isFalse);
      expect(GLSupportChatIdentity.tryParse({'id': 1, 'hash': 123})!.isVerified, isFalse, reason: 'a non-string hash is no hash');
    });

    test('keys other than the six are kept as extra and travel with the identity', () {
      final identity = GLSupportChatIdentity.tryParse({
        'id': 'learner:1',
        'hash': 'abc',
        'email': 'a@b.co',
        'booking_first_name': 'Ayesha',
        'model': 'Pixel 8',
        'blank': '',
        'gone': null,
      })!;
      expect(identity.isVerified, isTrue);
      expect(identity.extra, <String, String>{'booking_first_name': 'Ayesha', 'model': 'Pixel 8'});
      expect(
        identity.toJson().keys.toSet(),
        <String>{'id', 'email', 'hash', 'booking_first_name', 'model'},
      );
    });

    test('an extra key can never replace one of the six', () {
      const identity = GLSupportChatIdentity(
        id: 'learner:1',
        email: 'real@b.co',
        extra: <String, String>{'email': 'fake@b.co', 'id': 'x', 'hash': 'y', 'Name': 'Not Signed'},
      );
      final json = identity.toJson();
      expect(json['id'], 'learner:1');
      expect(json['email'], 'real@b.co');
      expect(json.containsKey('hash'), isFalse);
      expect(json.containsKey('Name'), isFalse);
    });

    test('extra values: blank ones dropped, lists and maps as JSON, numbers and booleans as text', () {
      final identity = GLSupportChatIdentity.tryParse({
        'id': 1,
        'hash': 'abc',
        'spaces': '   ',
        'tab': '\t',
        'courses': ['SIA', 'CSCS'],
        'booking': {'ref': 'A-1042', 'paid': true},
        'empty_list': <Object?>[],
        'attempts': 3,
        'score': 4.5,
        'paid': false,
        ' booking_ref ': 'A-1042',
        ' email': 'fake@b.co',
        'Name': 'Not Signed',
        'HASH': 'x',
      })!;
      expect(identity.extra, <String, String>{
        'courses': '["SIA","CSCS"]',
        'booking': '{"ref":"A-1042","paid":true}',
        'empty_list': '[]',
        'attempts': '3',
        'score': '4.5',
        'paid': 'false',
        'booking_ref': 'A-1042',
      });
      expect(identity.email, isNull, reason: '" email" is not the signed field, and not a detail either');
      expect(identity.name, isNull);
      expect(identity.hash, 'abc');
      expect(identity.toJson().keys.toSet(), <String>{'id', 'hash', 'courses', 'booking', 'empty_list', 'attempts', 'score', 'paid', 'booking_ref'});
    });

    test('withExtra adds details without touching the six, and leaves the original as it was', () {
      final signed = GLSupportChatIdentity.tryParse({
        'id': 'learner:1',
        'hash': 'abc',
        'email': 'real@b.co',
        'name': 'Ayesha Khan',
        'model': 'Pixel 8',
        'staffing_id': '7',
      })!;
      final more = signed.withExtra(<String, Object?>{
        'booking_first_name': 'Ayesha',
        'model': 'Pixel 9', // replaces
        'staffing_id': null, // ignored: keeps what it had
        'note': '  ', // ignored
        'booking': {'ref': 'A-1042'},
        'email': 'fake@b.co', // one of the six: ignored
        ' Name ': 'Not Signed',
        'id': 'someone-else',
        'hash': 'forged',
        'type': 'employer',
      });

      expect(more.id, 'learner:1');
      expect(more.hash, 'abc');
      expect(more.email, 'real@b.co');
      expect(more.name, 'Ayesha Khan');
      expect(more.type, isNull);
      expect(more.isVerified, isTrue);
      expect(more.extra, <String, String>{
        'model': 'Pixel 9',
        'staffing_id': '7',
        'booking_first_name': 'Ayesha',
        'booking': '{"ref":"A-1042"}',
      });
      expect(signed.extra, <String, String>{'model': 'Pixel 8', 'staffing_id': '7'}, reason: 'a copy: the original is unchanged');
      final json = more.toJson();
      expect(json['id'], 'learner:1');
      expect(json['email'], 'real@b.co');
      expect(json['name'], 'Ayesha Khan');
      expect(json['hash'], 'abc');
      expect(json.containsKey('type'), isFalse);
    });
  });

  group('fallback links', () {
    test('wa.me, tel and mailto', () {
      expect(whatsappLink('+44 7700 900123').toString(), 'https://wa.me/447700900123');
      expect(whatsappLink('123'), isNull);
      expect(whatsappLink(null), isNull);
      expect(telLink('+44 (20) 1234 5678').toString(), 'tel:+442012345678');
      expect(telLink(''), isNull);
      expect(mailtoLink('we.care@get-licensed.co.uk', subject: 'Support request').toString(), 'mailto:we.care@get-licensed.co.uk?subject=Support%20request');
      expect(mailtoLink('not-an-address'), isNull);
    });

    test('Android intent:// links fall back to their web page', () {
      final intent = Uri.parse('intent://send/447700900123#Intent;scheme=whatsapp;package=com.whatsapp;S.browser_fallback_url=https%3A%2F%2Fwa.me%2F447700900123;end');
      expect(intentFallback(intent).toString(), 'https://wa.me/447700900123');
      expect(intentFallback(Uri.parse('intent://x#Intent;scheme=foo;end')), isNull);
      expect(intentFallback(Uri.parse('https://wa.me/1')), isNull);
    });

    test('whatsapp:// without WhatsApp → wa.me', () {
      final web = whatsappWebFallback(Uri.parse('whatsapp://send?phone=+447700900123&text=Hi%20there'));
      expect(web!.host, 'wa.me');
      expect(web.path, '/447700900123');
      expect(web.queryParameters['text'], 'Hi there');
    });
  });

  group('auth backoff', () {
    test('30 s doubling, capped at 10 min', () {
      expect(authBackoff(0), Duration.zero);
      expect(authBackoff(1), const Duration(seconds: 30));
      expect(authBackoff(2), const Duration(seconds: 60));
      expect(authBackoff(5), const Duration(seconds: 480));
      expect(authBackoff(6), const Duration(seconds: 600));
      expect(authBackoff(50), const Duration(seconds: 600));
    });
  });
}
