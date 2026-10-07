# gl_support_chat

GL Support Chat for the Get Licensed Flutter apps (GuardPass, GuardCheck, GuardSkills, APLH): a native messenger — Home, Messages, Help and the conversation — like Intercom's SDK, on the same API as the website messenger. One package, one chatbot per app; each app's branding, articles and suggested questions are set in the GL Support Chat dashboard.

> **Built and tested, not yet run on a phone.** `flutter analyze` is clean and the unit, widget and live tests pass (the live test against the real API and Socket.IO server). Send any error from the first build back as it is.

## 0. Requirements

| | |
|---|---|
| Flutter / Dart | **≥ 3.24 / ≥ 3.5**. Every dependency has a range that still resolves there; on a newer Flutter pub picks newer releases |
| Dependencies it brings | `socket_io_client` 3.x, `image_picker` 1.x, `shared_preferences` 2.x, `flutter_widget_from_html_core` 0.15–0.17, `http`, `url_launcher` |
| iOS | Two strings in the app's `Info.plist` for photos — without them iOS ends the app when the customer taps the photo button: `NSPhotoLibraryUsageDescription` (e.g. "Send a photo to support, like your licence") and `NSCameraUsageDescription` (e.g. "Take a photo to send to support") |
| Android | `minSdkVersion 21` or higher. Nothing to add for photos: the system picker needs no permission. Only if the app itself declares `CAMERA` in its manifest does Android ask the customer before the camera opens |
| Push | Notification channel `gl_support_chat` (Android) |

## 1. Add it

```yaml
# pubspec.yaml of the app
dependencies:
  gl_support_chat:
    git:
      url: https://github.com/getlicensed/gl-support-chat-flutter.git
      ref: v0.4.1
```

Pin a tag (`ref`) so a build only changes when you move it; the versions are in [`CHANGELOG.md`](CHANGELOG.md).

## 2. Configure, sign in, show

```dart
await GLSupportChat.configure(
  apiUrl: 'https://support-api.get-licensed.co.uk',
  productId: '<this app\'s chatbot id — Chatbots → the chatbot → Install>',
  appId: 'com.getlicensed.guardpass',
  // Shown to the team on each conversation: "iOS 17.4 · iPhone 15 Pro · v3.4.0 (412)".
  // Fill it from what the app already uses (device_info_plus, package_info_plus);
  // the package adds the platform and appId. Display only — never signed, never trusted.
  device: GLSupportChatDevice(
    os: 'iOS ${iosInfo.systemVersion}',          // or 'Android ${androidInfo.version.release}'
    model: iosInfo.utsname.machine,              // or androidInfo.model
    manufacturer: 'Apple',                       // or androidInfo.manufacturer
    appVersion: packageInfo.version,
    appBuild: packageInfo.buildNumber,
  ),
  // What the customer is offered if the chat cannot load. None of it needs the chat servers.
  fallback: const GLSupportChatFallback(
    email: 'we.care@get-licensed.co.uk',          // the default
    whatsappNumber: null,                         // the real support number, once it is on GL Support Chat
    phoneNumber: null,                            // if customers may call
    helpUrl: 'https://support.get-licensed.co.uk/help',
  ),
  // Forward to Crashlytics / Sentry: "support did not open" becomes a number you can see.
  onDiagnostic: (event, detail) => FirebaseCrashlytics.instance.log('support $event $detail'),
);

// After your sign-in, with the identity YOUR backend signed (never in the app).
// tryParse never throws; login never throws and never blocks sign-in for long.
final identity = GLSupportChatIdentity.tryParse(profile['support_identity']);
if (identity != null) await GLSupportChat.login(identity);

// Badge
GLSupportChat.unreadCount.listen((n) => setState(() => unread = n));

// Open
GLSupportChat.present(context);                                       // Home
GLSupportChat.present(context, screen: GLSupportChatScreen.messages); // the list — or straight into the open conversation if it has unread replies
GLSupportChat.presentHelp(context);
GLSupportChat.presentArticle(context, 'how-do-i-renew-my-sia-licence');

// Sign-out (returns at once). The next person on this phone starts as a new visitor.
await GLSupportChat.logout();
```

**Put a "Contact support" entry on the sign-in screen too.** "I can't log in" is one of the most common reasons to contact support, and those customers have no identity yet — `present` without `login` opens the messenger anonymously. An anonymous chat is kept on the phone (per chatbot) and becomes the customer's own history when they sign in.

### The identity

The app's backend signs it and sends it in the profile response; the app only passes it on. The signing secret is the chatbot's (Chatbots → the chatbot → Install) and never goes in the app.

```
{ id, email?, phone?, type?, name?, hash }
hash = HMAC-SHA256(secret, "id|email|phone|type|name")   — hex; a missing field is an empty string
type = learner | employer | trainer_partner
```

A numeric `id`, and `null` or `""` for missing fields, are accepted. If the signature is refused, the messenger still opens — anonymously — and `onDiagnostic` reports `identity_rejected` with the reason: fix the backend, nothing in the app.

**Where it comes from in GuardPass and APLH:** the manage-booking response, `data.support_identity` (GuardPass `GET /protect/api/auth/manage-booking`, APLH `GET /api/v1/aplh/elearning/auth/manage-booking`). It is `null` until the backend has that app's secret; pass it to `tryParse` either way.

### What the app sent to Intercom, and where it is now

The booking travels **inside the signed identity**, filled in by the backend from the booking — the app does not send it separately:

| Sent to Intercom from the app | In GL Support Chat |
|---|---|
| `email`, `name` | the identity's `email` and `name`, from the booking |
| `user_hash` (made on the phone) | the identity's `hash`, made by the backend — the app never signs anything |
| `custom_attributes.booking_id` | the identity's `id`: `learner:<booking id>` (`stg:learner:<booking id>` on staging) |
| `custom_attributes.booking_first_name`, `booking_last_name` | the identity's `name`: `"<first name> <last name>"` |
| `custom_attributes.system_version`, `version`, `manufacturer`, `model` | `GLSupportChatDevice(os:, appVersion:, manufacturer:, model:, appBuild:)` in `configure` (§2) |

So for the booking the app does one thing: pass `data.support_identity` to `tryParse` **unchanged**. Only the six fields above are read and signed: extra fields added to the object are dropped, and changing any of the six (formatting the phone, trimming the name, rebuilding the object) breaks the signature. The team sees the name and a Learner chip on the conversation, and the booking itself — course, dates, payment — in the inbox's customer panel, looked up from GL Admin by that `id`.

## 3. What the customer sees

| Screen | What is on it |
|---|---|
| Home | Greeting ("Hi Ayesha 👋" when signed in), team faces, **Send us a message** with the team's status (online · back tomorrow at 9am · we'll reply by email), the **recent message**, help search and the top five articles |
| Messages | Every conversation with this app's chatbot, newest first: preview, who, when, unread dot, "Closed". **Send us a message** at the bottom |
| Conversation | The team's replies with their name and photo, photos and files the team sends, AI answers (typed out as they stream), the workflow's buttons and questions, CSAT faces after a close, ✓ / ✓✓, "New messages", typing dots both ways. The composer takes text and photos (library or camera). While nobody is online and the customer has no email on record: "Your email for follow-up". A closed conversation reads in full, with **Send us a message** instead of a composer |
| Help | Search (instant, then full text from the server) and the articles, drawn natively; links open in the browser |

## 4. When something goes wrong

Nothing here leaves a customer on a blank screen, an error page, or a dead button.

| What happens | What the customer sees |
|---|---|
| No signal, the server down, a 5xx | **"We can't open the chat right now"** with *Try again*, *Open in browser*, and Email / WhatsApp / Call / Help centre from `fallback`. Sign-in retries a 429/502/503/504 or a dropped connection twice by itself first |
| `configure()` never called | The same screen, not a crash |
| The connection drops mid-conversation | A yellow "Reconnecting…" bar; sending waits. On reconnect, anything that arrived meanwhile is fetched |
| The visitor token (24 h) runs out while the app is open | Renewed by itself; the customer sees nothing |
| The server refuses a message (sending too fast, too long) | The bubble stays, greyed, with the reason in words and **Try again** / **Delete** |
| A photo is too large or not a photo | The reason, under the bubble (the phone resizes photos first, so this is rare) |
| The backend's identity signature is refused | The messenger opens anonymously; `identity_rejected` in diagnostics |
| A link (WhatsApp, the help centre, mail, phone) | Opens in WhatsApp / the browser / the mail or phone app; WhatsApp not installed → wa.me in the browser |
| Before anything has loaded | A spinner, "Connecting to support…", and a close button |

`onDiagnostic` events: `messenger_ready {ms}`, `messenger_failed {reason, detail}`, `auth_failed {status, detail, failures}` (badge and push calls), `identity_rejected {code}`.

## 5. Push — "an agent replied" on the lock screen

```dart
// with firebase_messaging
final token = await FirebaseMessaging.instance.getToken();
if (token != null) await GLSupportChat.registerPushToken(token, platform: Platform.isIOS ? 'ios' : 'android');
FirebaseMessaging.instance.onTokenRefresh.listen((t) => GLSupportChat.registerPushToken(t, platform: Platform.isIOS ? 'ios' : 'android'));

// tap → the conversation
FirebaseMessaging.onMessageOpenedApp.listen((m) {
  if (m.data['type'] == 'message') GLSupportChat.present(navigatorKey.currentContext!, screen: GLSupportChatScreen.messages);
});
```

Push reaches **identified** users only (`registerPushToken` waits for `login`). Notifications collapse per conversation; the token is detached on `logout()`. Pushes are sent for agent replies, AI answers and hand-over lines in messenger conversations; email and WhatsApp conversations never push. The messenger plays no sound of its own — the push is the alert. The server side (the Firebase project the four apps share) is set up by the GL Support Chat team.

## 6. Replacing the Intercom SDK — per app

1. Add the package (§1) and the two iOS strings (§0).
2. `Intercom.loginIdentifiedUser` → `GLSupportChat.login(GLSupportChatIdentity.tryParse(...))` with `data.support_identity`; Intercom's `custom_attributes` are not sent — see "What the app sent to Intercom" (§2).
3. `Intercom.displayMessenger()` → `GLSupportChat.present(context)`; `displayHelpCenter` → `presentHelp`; `displayArticle(id)` → `presentArticle(slug)` (slugs from the dashboard's Articles page).
4. Unread badge: `GLSupportChat.unreadCount`.
5. Push: `Intercom.sendTokenToIntercom` → `GLSupportChat.registerPushToken`; handle `data['type'] == 'message'` on tap.
6. `Intercom.logout()` → `GLSupportChat.logout()`.
7. A "Contact support" entry on the sign-in screen (anonymous).
8. Remove the Intercom pod / gradle dependency.

## 7. Before submitting a build — test on real phones

At least one iPhone and one Android phone, each app.

- ▢ Signed in: Home greets by first name; a message reaches the inbox with the customer's name and type.
- ▢ Signed out (sign-in screen entry): a message reaches the inbox anonymously; sign in → the same conversation is in their Messages.
- ▢ An agent replies while the conversation is open: it appears at once; typing dots before it; ✓✓ once the agent has read the customer's message.
- ▢ A workflow button and a detail it asks for (email): both reach the inbox; a wrong email shows the reason under the box.
- ▢ **Photo**: library and camera, on both phones (the iPhone permission prompts appear once); the photo shows in the inbox thread and in the app.
- ▢ Close the conversation from the inbox: the CSAT faces appear; rate and comment; the rating shows in the inbox.
- ▢ Messages: the closed conversation reads in full, with **Send us a message**.
- ▢ **Airplane mode** → open support: the fallback screen; *Email us* opens the mail app; network back → *Try again* opens the messenger.
- ▢ Airplane mode **inside** a conversation: "Reconnecting…"; an agent replies meanwhile; network back → the reply appears without reopening.
- ▢ "Open WhatsApp" chip → WhatsApp with the message filled in; uninstalled → wa.me in the browser.
- ▢ An article, its links → the browser; back → the article.
- ▢ Close: the X on every screen, and Android back, each close what they should.
- ▢ Push: an agent replies while the app is in the background → notification → tap → the conversation.
- ▢ Badge: an agent replies while the messenger is closed → the badge goes up within 30 s.
- ▢ Kill and reopen the app, open support: the same conversation is still there (also signed out).
- ▢ `onDiagnostic` lines appear in the app's logs (`messenger_ready {ms: …}`).

## Not in this version

- Sending a PDF or other file from the phone (the server takes PDFs; the app's picker is photos only).
- A sound in the open messenger (the push notification is the alert).
- Replying in a closed conversation: it reads in full, and **Send us a message** continues the open one or starts a new one — one open conversation per customer, as on the website.
- Queueing messages typed while offline (sending waits for the connection).

## Working on the package

```bash
flutter pub get && flutter analyze && flutter test
```

- `test/controller_test.dart` and `test/widgets_test.dart` run against a pretend server and socket (`test/support/fakes.dart`).
- `GL_SCREENSHOTS=1 flutter test test/screenshots_test.dart` renders the main screens to `test/screens/*.png` (gitignored) with real fonts — a look at a change without a phone.
- `test/live_test.dart` runs against the real API and Socket.IO server, started from the GL Support Chat server repository (private): `pnpm messenger:live` there prints `GL_LIVE_API=… GL_LIVE_PRODUCT=…`; set both and run `flutter test test/live_test.dart`. Without them it is skipped.
- The example app (`example/`) has only `lib/` and `pubspec.yaml`; run `flutter create .` inside it once to generate the Android and iOS folders.
- A release: bump `version` in `pubspec.yaml`, add a `CHANGELOG.md` entry, commit, tag `v<version>`, push the tag; the apps move their `ref` to it.

© Get Licensed Ltd. All rights reserved. The source is public so the apps can install it; it is not licensed for other use.
