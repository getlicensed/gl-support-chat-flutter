import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/gl_support_chat.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Sign-ins that overlap. The badge, the push token, the messenger and a new
// login can all ask at once: callers for the same customer share the sign-in
// that is out, and a login or logout since then waits for it and signs in
// afresh. So the customer the app signed in last is the last the server
// hears, and the token kept is theirs. Run with `flutter test test/login_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ayesha = GLSupportChatIdentity(id: 'A', name: 'Ayesha Khan', hash: 'ha');
  const bilal = GLSupportChatIdentity(id: 'B', name: 'Bilal Ahmed', hash: 'hb');

  late List<Map<String, dynamic>> auths; // every /widget/auth body, in order
  late List<String?> bearers; // the token every /widget/unread carried
  late Completer<void> answerA; // the server answers A's sign-in only when this completes

  List<String?> who() => auths.map((b) => (b['identity'] as Map<String, dynamic>?)?['id'] as String?).toList();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    auths = <Map<String, dynamic>>[];
    bearers = <String?>[];
    answerA = Completer<void>();
    GLSupportChat.debugOverride(
      client: MockClient((http.Request req) async {
        final json = <String, String>{'content-type': 'application/json'};
        if (req.url.path == '/widget/auth') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          auths.add(body);
          final id = (body['identity'] as Map<String, dynamic>?)?['id'] as String?;
          if (id == 'A') await answerA.future;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'token': 'tok-${id ?? 'anonymous'}',
              'visitorId': body['visitorId'] ?? 'visitor-new',
              'identified': id == null ? null : <String, dynamic>{'name': null, 'type': null},
            }),
            200,
            headers: json,
          );
        }
        if (req.url.path == '/widget/unread') bearers.add(req.headers['authorization']);
        return http.Response(jsonEncode(<String, dynamic>{'unreadCount': 0}), 200, headers: json);
      }),
    );
    await GLSupportChat.configure(apiUrl: 'https://api.test', productId: 'p1');
    await GLSupportChat.logout();
  });

  test('callers for the same customer share the sign-in that is out', () async {
    final login = GLSupportChat.login(ayesha);
    await pumpEventQueue();
    final badge = GLSupportChat.refreshUnread();
    await pumpEventQueue();
    answerA.complete();
    expect(await login, isTrue);
    await badge;

    expect(who(), <String?>['A'], reason: 'one sign-in, shared');
    expect(bearers, isNotEmpty);
    expect(bearers, everyElement('Bearer tok-A'));
  });

  test("login(B) while A's sign-in is still out: B is the last sign-in, and B's token is kept", () async {
    final first = GLSupportChat.login(ayesha);
    await pumpEventQueue();
    expect(who(), <String?>['A']);

    final second = GLSupportChat.login(bilal);
    await pumpEventQueue();
    expect(who(), <String?>['A'], reason: "never two sign-ins at once: B's waits for A's");

    answerA.complete();
    expect(await second, isTrue);
    expect(await first, isTrue, reason: 'A was accepted, even though B came after');

    expect(who(), <String?>['A', 'B'], reason: 'B is the last the server hears');
    await GLSupportChat.refreshUnread();
    expect(bearers, isNotEmpty);
    expect(bearers, everyElement('Bearer tok-B'), reason: "nothing goes out with A's token once B has logged in");
  });

  test("logout() then login(B) while A's sign-in is still out: B's token is kept", () async {
    final first = GLSupportChat.login(ayesha);
    await pumpEventQueue();
    await GLSupportChat.logout();
    final second = GLSupportChat.login(bilal);
    answerA.complete();
    expect(await second, isTrue);
    await first;

    expect(who(), <String?>['A', 'B']);
    expect(auths.last.containsKey('visitorId'), isFalse, reason: "A's late answer must not bring back the visitor id logout() forgot");
    await GLSupportChat.refreshUnread();
    expect(bearers, isNotEmpty);
    expect(bearers, everyElement('Bearer tok-B'));
  });
}
