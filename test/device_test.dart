import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:gl_support_chat/src/core/session_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// The phone and app go with every sign-in, so the team sees them on the
// conversation. Its own file: it sets the package's static test overrides.
void main() {
  test('configure(device:) is sent with the sign-in, with the platform and app id', () async {
    final sent = <Map<String, dynamic>>[];
    GLSupportChat.debugOverride(
      client: MockClient((req) async {
        if (req.url.path == '/widget/auth') sent.add(jsonDecode(req.body) as Map<String, dynamic>);
        // `identified`, as the server answers an identity it accepted: login() is true only then.
        return http.Response(jsonEncode(<String, dynamic>{'token': 't', 'visitorId': 'v', 'identified': <String, dynamic>{'name': null, 'type': null}, 'unreadCount': 0}), 200);
      }),
      store: MemorySessionStore(),
    );
    await GLSupportChat.configure(
      apiUrl: 'https://api.test',
      productId: 'p1',
      appId: 'com.getlicensed.guardpass',
      device: const GLSupportChatDevice(os: 'Android 14', model: 'SM-S911B', manufacturer: 'samsung', appVersion: '3.4.0', appBuild: ' 412 '),
    );
    expect(await GLSupportChat.login(const GLSupportChatIdentity(id: 'learner:1', hash: 'h')), isTrue);
    expect(sent.single['device'], <String, String>{
      'platform': 'android', // the test platform
      'os': 'Android 14',
      'model': 'SM-S911B',
      'manufacturer': 'samsung',
      'appId': 'com.getlicensed.guardpass',
      'appVersion': '3.4.0',
      'appBuild': '412',
    });
    expect(sent.single['identity'], isNotNull);
  });

  test('without a device, the platform and app id still go', () {
    expect(const GLSupportChatDevice().toJson(appId: 'com.x'), <String, String>{'platform': 'android', 'appId': 'com.x'});
    expect(const GLSupportChatDevice(os: '  ').toJson(), <String, String>{'platform': 'android'}, reason: 'blank fields are left out');
  });
}
