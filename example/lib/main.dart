import 'package:flutter/material.dart';
import 'package:gl_support_chat/gl_support_chat.dart';

/// Minimal host app: configure, sign in with an identity the backend signed,
/// show the badge, open the messenger — and a support entry for signed-out
/// customers, who are often the ones who need it most.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GLSupportChat.configure(
    apiUrl: 'https://support-api.get-licensed.co.uk',
    productId: '00000000-0000-0000-0000-000000000000', // this app's chatbot id
    appId: 'com.getlicensed.guardpass',
    fallback: const GLSupportChatFallback(
      helpUrl: 'https://support.get-licensed.co.uk/help',
    ),
    onDiagnostic: (event, detail) => debugPrint('[support] $event $detail'),
  );
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    GLSupportChat.unreadCount.listen((n) {
      if (mounted) setState(() => _unread = n);
    });
    // After your own sign-in, with the identity object your backend returned:
    //   final identity = GLSupportChatIdentity.tryParse(profile['support_identity']);
    //   if (identity != null) await GLSupportChat.login(identity);
    // With Firebase Messaging:
    //   final t = await FirebaseMessaging.instance.getToken();
    //   if (t != null) await GLSupportChat.registerPushToken(t, platform: Platform.isIOS ? 'ios' : 'android');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('GuardPass'),
            actions: [
              IconButton(
                tooltip: 'Support',
                icon: Badge(
                  isLabelVisible: _unread > 0,
                  label: Text('$_unread'),
                  child: const Icon(Icons.chat_bubble_outline),
                ),
                onPressed: () => GLSupportChat.present(context, screen: GLSupportChatScreen.messages),
              ),
            ],
          ),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: () => GLSupportChat.presentHelp(context), child: const Text('Help centre')),
                TextButton(onPressed: () => GLSupportChat.present(context), child: const Text("Can't sign in? Contact support")),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
