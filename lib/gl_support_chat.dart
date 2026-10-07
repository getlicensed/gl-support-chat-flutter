/// GL Support Chat for the Get Licensed Flutter apps.
///
/// A native messenger — Home, Messages, Help, the conversation — talking to
/// the same API as the website messenger, behind a small static API:
///
/// ```dart
/// await GLSupportChat.configure(
///   apiUrl: 'https://support-api.get-licensed.co.uk',
///   productId: '<chatbot id from the dashboard>',
///   appId: 'com.getlicensed.guardpass',
///   onDiagnostic: (event, detail) => log('support $event $detail'),
/// );
/// final identity = GLSupportChatIdentity.tryParse(profile['support_identity']);
/// if (identity != null) await GLSupportChat.login(identity); // never throws
/// GLSupportChat.present(context);                              // full-screen messenger
/// GLSupportChat.unreadCount.listen((n) => setState(() => badge = n));
/// ```
library gl_support_chat;

export 'src/device.dart' show GLSupportChatDevice;
export 'src/fallback.dart' show GLSupportChatFallback;
export 'src/gl_support_chat.dart' show GLSupportChat, GLSupportChatDiagnostics, GLSupportChatIdentity;
export 'src/messenger_page.dart' show GLSupportChatScreen;
