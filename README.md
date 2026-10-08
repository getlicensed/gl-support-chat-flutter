# gl_support_chat

A Flutter SDK for the GL Support Chat messenger: a native Home, Messages, Help and conversation, like Intercom's SDK, talking to the same API as the website messenger. One package, one chatbot per app. Each app's branding (colour, logo, the team faces it shows), articles and suggested questions are set in the GL Support Chat dashboard (Chatbots → the chatbot → Design) and change without a new app build.

> **Built and tested, not yet run on a phone.** `flutter analyze` is clean and the unit, widget and live tests pass (the live test against a real API and Socket.IO server). Send any error from the first build back as it is.

## 0. Requirements

| | |
|---|---|
| Flutter / Dart | **≥ 3.24 / ≥ 3.5**. Every dependency has a range that still resolves there; on a newer Flutter pub picks newer releases |
| Dependencies it brings | `socket_io_client` 3.x, `image_picker` 1.x, `shared_preferences` 2.x, `flutter_widget_from_html_core` 0.15–0.17, `http`, `url_launcher` |
| iOS | Two strings in the app's `Info.plist` for photos. Without them iOS ends the app when the customer taps the photo button: `NSPhotoLibraryUsageDescription` (e.g. "Send a photo to support") and `NSCameraUsageDescription` (e.g. "Take a photo to send to support") |
| Android | `minSdkVersion 21` or higher. Nothing to add for photos: the system picker needs no permission. Only if the app itself declares `CAMERA` in its manifest does Android ask the customer before the camera opens |
| Push | Notification channel `gl_support_chat` (Android) |
| Server | A running GL Support Chat server, and a chatbot created on it for your app (you need its id) |

## 1. Add it

```yaml
# pubspec.yaml of your app
dependencies:
  gl_support_chat:
    git:
      url: https://github.com/getlicensed/gl-support-chat-flutter.git
      ref: v0.4.4
```

Pin a tag (`ref`) so a build only changes when you move it. The versions and what changed in each are in [`CHANGELOG.md`](CHANGELOG.md).

## 2. Configure, sign in, show

```dart
await GLSupportChat.configure(
  // The base URL of your GL Support Chat server.
  apiUrl: 'https://support-api.example.com',
  // This app's chatbot id (Chatbots → the chatbot → Install).
  productId: '<your chatbot id>',
  // This platform's own id: Android's applicationId, iOS's bundle id, so they differ.
  // package_info_plus gives it as packageName. Shown to the team; never used to route.
  appId: packageInfo.packageName,
  // Shown to the team on each conversation: "iOS 17.4 · iPhone 15 Pro · v3.4.0 (412)".
  // Fill it from what your app already uses (device_info_plus, package_info_plus);
  // the package adds the platform and appId. Display only: never signed, never trusted.
  device: GLSupportChatDevice(
    os: 'iOS ${iosInfo.systemVersion}',          // or 'Android ${androidInfo.version.release}'
    model: iosInfo.utsname.machine,              // or androidInfo.model
    manufacturer: 'Apple',                       // or androidInfo.manufacturer
    appVersion: packageInfo.version,
    appBuild: packageInfo.buildNumber,
  ),
  // What the customer is offered if the chat cannot load. None of it needs the chat server.
  // Set your own email: the package's built-in default is the maintainer's address.
  fallback: const GLSupportChatFallback(
    email: 'support@example.com',
    whatsappNumber: null,                        // your support WhatsApp number, if you have one
    phoneNumber: null,                           // if customers may call
    helpUrl: 'https://help.example.com',
  ),
  // Forward to Crashlytics / Sentry: "support did not open" becomes a number you can see.
  onDiagnostic: (event, detail) => FirebaseCrashlytics.instance.log('support $event $detail'),
);

// Optional: after your own sign-in, with the identity YOUR backend signed (never in the app).
// tryParse never throws; login never throws and never blocks sign-in for long.
// Call it again whenever the details may have changed (see "Keeping the customer's details up to date").
final identity = GLSupportChatIdentity.tryParse(profile['support_identity']);
if (identity != null) await GLSupportChat.login(identity);

// Badge
GLSupportChat.unreadCount.listen((n) => setState(() => unread = n));

// Open
GLSupportChat.present(context);                                       // Home
GLSupportChat.present(context, screen: GLSupportChatScreen.messages); // the list, or straight into the open conversation if it has unread replies
GLSupportChat.presentHelp(context);
GLSupportChat.presentArticle(context, 'how-do-i-reset-my-password');

// Sign-out (returns at once). The next person on this phone starts as a new visitor.
await GLSupportChat.logout();
```

**Android and iOS:** use the same `productId` on both (one chatbot per app, so a customer's conversations are the same whichever phone they use) and each platform's own `appId`. `appId` is optional: it labels the device and the push token for the team (the conversation's device chip says which app build wrote), and nothing depends on it.

**Offer support before sign-in too.** "I can't log in" is one of the most common reasons to contact support, and those customers have no identity yet. `present` without `login` opens the messenger anonymously. An anonymous chat is kept on the phone (per chatbot) and becomes the customer's own history when they sign in with a signed identity.

### The identity

The identity tells the server who the customer is, so their name, email and history are one contact. **Your backend signs it** and returns it (for example in the profile or sign-in response); the app only passes it on. The signing secret belongs to the chatbot (Chatbots → the chatbot → Install) and never goes in the app.

```
{ id, email?, phone?, type?, name?, hash? }
id   = a unique, stable id for the customer in your system, as a string
hash = HMAC-SHA256(secret, "id|email|phone|type|name")   (hex; a missing field is an empty string)
       present: a verified identity the server checks. Missing: an unverified identity (below)
type = optional, one of the customer types the server accepts: learner | employer | trainer_partner
```

`GLSupportChatIdentity.isVerified` tells you which kind you hold: `true` when there is a `hash`.

Sign the values exactly as you send them. A numeric `id`, and `null` or `""` for missing fields, are accepted. Only those six fields are signed: extra keys in the object travel with it (see below) but are not part of the signature, and changing any of the six after signing (reformatting the phone, trimming the name, rebuilding the object) breaks the signature, so pass the object to `tryParse` unchanged.

**Only `id` and `hash` are required.** Any of `email`, `phone`, `type` and `name` may be missing. GL Support Chat checks the signature first, then each of those four on its own: one the inbox cannot use (an address that is not one, a `type` other than the three above, a phone with fewer than 6 digits) is left out and the rest of the identity stands, and a name longer than 120 characters is cut.

If the identity is refused (no `hash`, or a signature that does not match: a 401), the messenger still opens, anonymously, `login` returns `false`, and `onDiagnostic` reports `identity_rejected` with the reason: fix the backend, nothing in the app. If your backend has no identity for a customer, skip `login`: the messenger opens anonymously and everything else works.

**Without a hash (unverified).** `tryParse` also accepts a map that has an `id` but no `hash`, and `login` sends it as the same `identity` object, just without a `hash`:

```dart
final identity = GLSupportChatIdentity.tryParse({
  'id': '220657',                    // required, any non-empty value
  'email': 'ayesha@example.com',
  'name': 'Ayesha Khan',
  'order_ref': 'A-1042',             // any other key is kept as an extra
});
if (identity != null) await GLSupportChat.login(identity);   // identity.isVerified is false
```

That call sends this inside the sign-in body (`POST /widget/auth`), with no `hash`:

```json
"identity": { "order_ref": "A-1042", "id": "220657", "email": "ayesha@example.com", "name": "Ayesha Khan" }
```

- **The six fields, and any extra keys.** `id`, `email`, `phone`, `name`, `type` (and `hash` when there is one) are the identity. Any other key in the map is kept in `identity.extra` and sent inside the same `identity` object. Extra keys are never signed, so the server cannot trust them, and one can never replace the six: a key that is one of them with other capitals or spaces (`Email`, ` name`) is dropped. Values are sent as text (a number or a boolean as written, a list or a map as its JSON), and blank or `null` values are dropped.
- **Don't repeat what `device` already sends.** OS, model, manufacturer, app version and build go in `GLSupportChatDevice` in `configure` and travel in the sign-in's `device` block. Leave them out of the identity map.
- **The server decides.** Nothing vouches for an unverified identity, and a server may refuse it. When it does, the plugin signs the customer in anonymously, `login` returns `false`, and `onDiagnostic` reports `identity_rejected` with the server's code, for example `identity_bad_signature` or `identity_malformed`. A server that accepts unverified identities can show the details to the team as unverified.
- **On GL Support Chat** (Get Licensed's server): an identity without a `hash` is refused (`identity_malformed`), extras or not. Beside a **signed** identity the extra keys become the customer's details: see the next section.
- **Check what is sent.** Print `identity.toJson()` before calling `login`, or watch the request in a network proxy. `onDiagnostic` shows the server's answer.
- **Not shared across devices.** Only a signed identity (`identity.isVerified`) can join the customer to their history across devices and channels.
- **The browser link** from `messengerUrl()` carries a signed identity only.

### Keeping the customer's details up to date

As with Intercom, every `login` updates the customer in the inbox. It sends the identity with its extra keys, and GL Support Chat updates the contact: the name, email, phone and type the identity carries, and the extra keys merged into the contact's details (a key sent again takes the new value, a new key is added, a key not sent keeps its last value). An agent with the customer open sees the change at once, without reloading.

So call `login`:

- at every app start, once your own session is restored;
- again whenever you fetch the profile or booking that carries `support_identity` again;
- right before `present` when the details may have changed, as the Intercom integration did on every chat tap.

It is one request and safe to repeat; the last call wins, even while an earlier one is still out. Do not call `logout` before it: that starts a new anonymous visitor (§6, step 7).

**Your own details** (the custom attributes you sent Intercom) go beside the signed identity with `withExtra`. It returns a copy and never touches the six signed fields, so the signature still holds:

```dart
final identity = GLSupportChatIdentity.tryParse(profile['support_identity'])
    ?.withExtra({'booking_first_name': first, 'booking_last_name': last, 'staffing_id': staffingId});
if (identity != null) await GLSupportChat.login(identity); // still verified: the hash covers only the six
```

What GL Support Chat does with the extra keys:

- They describe the customer; they never identify them. They are kept on the contact, shown to the team under **Details** in the customer panel (labelled as sent by the app, not verified) and on the Contacts page, and never used to find or join a contact.
- Up to 100 a sign-in. Keys become snake_case (`bookingFirstName` → `booking_first_name`). Values are one line of text up to 500 characters; a list or a map arrives as its JSON. Blank and `null` values are dropped.
- Keys that look like secrets are dropped, inside a list or a map too: `password`, `passwd`, `pwd`, `secret`, `token`, `api_key`, `apikey`, `hash`, `otp`, `cvv` and `cvc`, as a word of the key (`wifi_password` too). Leave them out anyway.

## 3. What the customer sees

| Screen | What is on it |
|---|---|
| Home | The chatbot's logo, the team faces the admin chose (Design → Team faces: automatic, chosen, or nobody), a greeting ("Hi Ayesha 👋" when signed in), **Send us a message** with the team's status (online · back tomorrow at 9am · we'll reply by email), the **recent message**, help search and the top five articles |
| Messages | Every conversation with this app's chatbot, newest first: preview, who, when, unread dot, "Closed". **Send us a message** at the bottom |
| Conversation | The header shows the team faces, or the chatbot's logo when none are shown. The team's replies with their name and photo, the workflow's messages beside the chatbot's logo, photos and files the team sends, AI answers (typed out as they stream), the workflow's buttons and questions, CSAT faces after a close, ✓ / ✓✓, "New messages", typing dots both ways. The composer takes text and photos (library or camera); **while the workflow waits on a button or a detail it asked for there is no composer at all**, as in Intercom, and it comes back when typing is allowed. While nobody is online and the customer has no email on record: "Your email for follow-up". A closed conversation reads in full, with **Send us a message** instead of a composer |
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

## 5. Push: "an agent replied" on the lock screen

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

Push reaches **identified** users only (`registerPushToken` waits for `login`). Notifications collapse per conversation; the token is detached on `logout()`. Pushes are sent for agent replies, AI answers and hand-over lines in messenger conversations; email and WhatsApp conversations never push. The messenger plays no sound of its own: the push is the alert. Use the FCM token on iOS too, not the raw APNs token. The server side (a Firebase project with your APNs key, and its service account on the server) is set up on the GL Support Chat server.

## 6. Migrating from another chat SDK

The calls map across like this (shown for Intercom; other SDKs are similar):

1. Add the package (§1) and the two iOS strings (§0).
2. Identify the user: `Intercom.loginIdentifiedUser` → `GLSupportChat.login(GLSupportChatIdentity.tryParse(...))` with an identity your backend signed. Intercom's `user_hash`, which an app often computed on the phone, becomes the identity's `hash`, made by the backend.
3. Custom attributes: `Intercom.updateUser(customAttributes: …)` → `identity.withExtra({...})` and `login` again (§2, "Keeping the customer's details up to date"); every `login` updates the customer, as Intercom's did. Name, email and phone come in the signed identity; device and app details go in `GLSupportChatDevice` in `configure` (OS, model, manufacturer, version, build).
4. Open: `Intercom.displayMessenger()` → `GLSupportChat.present(context)`; `displayHelpCenter` → `presentHelp`; `displayArticle(id)` → `presentArticle(slug)` (slugs are on the dashboard's Articles page).
5. Unread badge: `GLSupportChat.unreadCount`.
6. Push: `Intercom.sendTokenToIntercom` → `GLSupportChat.registerPushToken`; handle `data['type'] == 'message'` on tap.
7. Sign out: `Intercom.logout()` → `GLSupportChat.logout()`. Call it on sign-out only, not before every chat tap, or an anonymous visitor starts an empty conversation each time. Where the Intercom code ran logout → login → updateUser on every chat tap, call only `login` (with the fresh identity) and then `present`.
8. Add a "Contact support" entry on the sign-in screen (anonymous).
9. Remove the old SDK's pod / gradle dependency.

## 7. Before submitting a build: test on real phones

At least one iPhone and one Android phone.

- ▢ Signed in: Home greets by first name; a message reaches the inbox with the customer's name.
- ▢ Signed out (sign-in screen entry): a message reaches the inbox anonymously; sign in, and the same conversation is in their Messages.
- ▢ An agent replies while the conversation is open: it appears at once; typing dots before it; ✓✓ once the agent has read the customer's message.
- ▢ A workflow button and a detail it asks for (email): both reach the inbox; a wrong email shows the reason under the box. Under the buttons there is no composer; it appears once the workflow lets the customer type.
- ▢ The workflow's messages show the chatbot's logo (Design → Logo: uploaded there, or an https link); Home and the header show the team faces chosen on the Design page.
- ▢ **Photo**: library and camera, on both phones (the iPhone permission prompts appear once); the photo shows in the inbox thread and in the app.
- ▢ Close the conversation from the inbox: the CSAT faces appear; rate and comment; the rating shows in the inbox.
- ▢ Messages: the closed conversation reads in full, with **Send us a message**.
- ▢ **Airplane mode**, then open support: the fallback screen; *Email us* opens the mail app; network back, *Try again* opens the messenger.
- ▢ Airplane mode **inside** a conversation: "Reconnecting…"; an agent replies meanwhile; network back, and the reply appears without reopening.
- ▢ "Open WhatsApp" chip: WhatsApp with the message filled in; uninstalled, wa.me in the browser.
- ▢ An article, its links go to the browser; back returns to the article.
- ▢ Close: the X on every screen, and Android back, each close what they should.
- ▢ Push: an agent replies while the app is in the background, a notification arrives, and tapping it opens the conversation.
- ▢ Badge: an agent replies while the messenger is closed, and the badge goes up within 30 s.
- ▢ Kill and reopen the app, open support: the same conversation is still there (also signed out).
- ▢ `onDiagnostic` lines appear in the app's logs (`messenger_ready {ms: …}`).

## Not in this version

- Sending a PDF or other file from the phone (the server takes PDFs; the app's picker is photos only).
- A sound in the open messenger (the push notification is the alert).
- Replying in a closed conversation: it reads in full, and **Send us a message** continues the open one or starts a new one, one open conversation per customer, as on the website.
- Queueing messages typed while offline (sending waits for the connection).

## Working on the package

```bash
flutter pub get && flutter analyze && flutter test
```

- `test/controller_test.dart` and `test/widgets_test.dart` run against a pretend server and socket (`test/support/fakes.dart`).
- `test/attributes_test.dart` covers what `login` puts in the sign-in body, signed and unverified, against a pretend server.
- `GL_SCREENSHOTS=1 flutter test test/screenshots_test.dart` renders the main screens to `test/screens/*.png` (gitignored) with real fonts, a look at a change without a phone.
- `test/live_test.dart` runs against a real API and Socket.IO server, started from the GL Support Chat server repository: `pnpm messenger:live` there prints `GL_LIVE_API=… GL_LIVE_PRODUCT=…`; set both and run `flutter test test/live_test.dart`. Without them it is skipped.
- The example app (`example/`) has only `lib/` and `pubspec.yaml`; run `flutter create .` inside it once to generate the Android and iOS folders.
- A release: bump `version` in `pubspec.yaml`, add a `CHANGELOG.md` entry, commit, tag `v<version>`, push the tag; apps move their `ref` to it.

© Get Licensed Ltd. All rights reserved. The source is public so the apps can install it; it is not licensed for other use.
