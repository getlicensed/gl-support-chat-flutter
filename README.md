# gl_support_chat

A Flutter SDK for the GL Support Chat messenger: a native Home, Messages, Help and conversation, like Intercom's SDK, talking to the same API as the website messenger. One package, one chatbot per app. Each app's branding (colour, logo, chat avatar, the team faces it shows), articles and suggested questions are set in the GL Support Chat dashboard (Chatbots → the chatbot → Design) and change without a new app build.

> **0.4.4 is in the four apps; 0.4.5 and 0.4.6 are built and tested, not yet run on a phone.** Moving to 0.4.6 is the `ref` alone: no code changes in the app, the same Flutter 3.24 floor. `flutter analyze` is clean and the unit and widget tests pass; `test/frames_test.dart` checks what moves frame by frame. The widget tests draw the screens at iPhone 13, iPhone SE, Android 360 and landscape sizes, with the keyboard up and down, the safe areas, text sizes up to 2.0 and a dark app theme. The live test runs against a real API and Socket.IO server (see "Working on the package"). Send any error from the first build back as it is.

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
      ref: v0.4.6
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
GLSupportChat.present(context, screen: GLSupportChatScreen.conversation(id)); // one conversation: the open one to reply in, a closed one to read
GLSupportChat.presentHelp(context);
GLSupportChat.presentArticle(context, 'how-do-i-reset-my-password');

// Sign-out (returns at once). The next person on this phone starts as a new visitor.
await GLSupportChat.logout();
```

**Android and iOS:** use the same `productId` on both (one chatbot per app, so a customer's conversations are the same whichever phone they use) and each platform's own `appId`. `appId` is optional: it labels the device and the push token for the team (the conversation's device chip says which app build wrote), and nothing depends on it.

**It opens on Home at once.** After `login` the package fetches what Home shows in the background — the conversations, the top articles, the team's photos and the logo — without going live (no connection opens until the messenger does), using `login`'s own sign-in. So `present` shows Home in its first frame, and the open conversation follows behind it. The messenger keeps what it showed for as long as the same customer is signed in: opened again, it shows that at once and refreshes behind it. With nothing yet (an anonymous visitor's first open, or `present` straight after the app starts), Home shows as a skeleton in the chatbot's colours, remembered from last time, and Home cross-fades in. A `logout`, or a `login` as someone else, drops all of it at once.

**The sheet.** The messenger opens as a sheet over the app: the app stays drawn behind it, dimmed, in a strip under the status bar; the top corners are rounded. A drag down past a quarter of its height, or a flick down, closes it; Home, Help or an article scrolled to the top pulls the sheet down (the Messages list keeps its pull-to-refresh). The status bar sits over the dimmed app, so it keeps the app's own style while support is open. Nothing to set up: `present` does it.

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
| Home | The chatbot's logo (Design → Logo), the team faces the admin chose (Design → Team faces: automatic, chosen, or nobody), a greeting ("Hi Ayesha 👋" when signed in), **Send us a message** with the team's status (online · back tomorrow at 9am · we'll reply by email), the **recent message**, help search and the top five articles |
| Messages | Every conversation with this app's chatbot, newest first: preview, who, when, unread dot, "Closed". **Send us a message** at the bottom |
| Conversation | The header shows the team faces, or the chatbot's circle when none are shown: its chat avatar (Design → Chat avatar, filling the circle), else its logo on the brand colour, else its initial. The latest message stays in view; reading further up, the customer keeps their place and a **New message** pill takes them down. A drag of the thread or a tap outside the box puts the keyboard away. The team's replies with their name and photo, the workflow's messages beside the chatbot's circle, photos and files the team sends, AI answers (typed out as they stream), the workflow's buttons and questions, CSAT faces after a close, ✓ / ✓✓, "New messages", typing dots both ways: beside the teammate's photo (their initial without one) when a teammate types, the chatbot's circle when the workflow does. A reply or the customer's own message fades in and the thread glides up to it; the typing dots open and close in place, and the reply takes their place. The composer takes text and photos (library or camera) and grows a line at a time. **While the workflow waits on a button or a detail it asked for, the composer is locked** and says why ("Choose an option above"), at the same height, so nothing jumps when typing is allowed. The customer's own message is whole at once; "Sending…" shows only if it takes longer than 600 ms. While nobody is online and the customer has no email on record: "Your email for follow-up". A closed conversation reads in full, with **Send us a message** instead of a composer |
| Help | Search (instant, then full text from the server) and the articles, drawn natively; links open in the browser. A paragraph that is only a link (Intercom's article buttons, as imported) is a button in the brand colour. Under each article, **Did this answer your question?** with 😞 😐 😃; after 😞, **Send us a message**. The five articles on Home are fetched as it opens, and an article read once opens at once |
| Everywhere | It moves as Intercom's does. The sheet rises over the app (400 ms, fast then settling) and goes down in 250 ms; Home's parts come in one after another; the tabs fade through (out, then in); what loads comes in with a short fade instead of popping; bars and the "New message" pill open and close softly. With the phone's Reduce Motion (iOS) or Remove animations (Android) on, all of it changes at once. In an app that follows the phone's dark mode, typed text, hints and the help search stay dark on white; Android back steps back a screen at a time, then to the tab it opened on, then out; on an iPhone a swipe from the left edge steps back; buttons, chips and files take taps on at least 44 points |

## 4. When something goes wrong

Nothing here leaves a customer on a blank screen, an error page, or a dead button.

| What happens | What the customer sees |
|---|---|
| No signal, the server down, a 5xx | **"We can't open the chat right now"** with *Try again*, *Open in browser*, and Email / WhatsApp / Call / Help centre from `fallback`. Sign-in retries a 429/502/503/504 or a dropped connection twice by itself first |
| `configure()` never called | The same screen, not a crash |
| The connection drops mid-conversation | A yellow "Reconnecting…" bar. Send still works: messages wait, show "Sending…" (after 600 ms), and go once, in order, when it is back. On reconnect, anything that arrived meanwhile is fetched |
| The answer to a message is lost (a drop, or the phone locked, just after sending) | "No answer from the server" with **Try again**; if the message did reach the team, the catch-up shows it once, as sent, and the failed copy goes |
| The app goes to the background and comes back | Nothing is marked read while it is away; back, it reconnects and fetches what came meanwhile |
| The visitor token (24 h) runs out while the app is open | Renewed by itself; the customer sees nothing |
| The server refuses a message (sending too fast, too long) | The bubble stays, greyed, with the reason in words and **Try again** / **Delete** |
| A photo is too large or not a photo | The reason, under the bubble (the phone resizes photos first, so this is rare) |
| The backend's identity signature is refused | The messenger opens anonymously; `identity_rejected` in diagnostics |
| A link (WhatsApp, the help centre, mail, phone) | Opens in WhatsApp / the browser / the mail or phone app; WhatsApp not installed → wa.me in the browser |
| Before anything has loaded (an open with nothing fetched yet) | Home as a skeleton, in the chatbot's colours, logo, greeting and team when this phone has seen them before, with a close button, until the sign-in and the Messages list are in; then Home cross-fades in. A conversation opened before its messages are in shows a spinner and a locked composer until they are. Opened again later, what it had shows at once |
| A reaction under an article does not save | The choice stays shown, nothing else; `article_reaction_failed` in diagnostics. Needs the server with `POST /widget/article-reaction` (being added alongside 0.4.6); until then every reaction reports a 404 |

`onDiagnostic` events: `messenger_ready {ms, cached}`, `messenger_failed {reason, detail}`, `auth_failed {status, detail, failures}` (badge and push calls), `identity_rejected {code}`, `article_reaction_failed {status, slug}`.

## 5. Push: "an agent replied" on the lock screen

```dart
// with firebase_messaging
final token = await FirebaseMessaging.instance.getToken();
if (token != null) await GLSupportChat.registerPushToken(token, platform: Platform.isIOS ? 'ios' : 'android');
FirebaseMessaging.instance.onTokenRefresh.listen((t) => GLSupportChat.registerPushToken(t, platform: Platform.isIOS ? 'ios' : 'android'));

// tap → the conversation the push is about (null: not a GL Support Chat push)
FirebaseMessaging.onMessageOpenedApp.listen((m) {
  final screen = GLSupportChatScreen.fromPush(m.data);
  if (screen != null) GLSupportChat.present(navigatorKey.currentContext!, screen: screen);
});
```

`fromPush` opens the conversation the push names (its `conversationId`), or the Messages list when it names none. An app that still passes `GLSupportChatScreen.messages` gets the conversation with the unread reply, once the messenger has checked. Tapped while the messenger is open, the push goes to its conversation in the messenger already up. The messenger never closes the app's own screens: if the app has put a lock or sign-in screen over it, that screen stays and the push only switches the messenger behind it to Messages.

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
- ▢ An agent replies while the conversation is open: typing dots before it, beside the agent's photo (their initial if they have none); the reply takes the dots' place and fades in, and the thread glides up to it, no jump; ✓✓ once the agent has read the customer's message.
- ▢ A workflow button and a detail it asks for (email): both reach the inbox; a wrong email shows the reason under the box. Under the buttons the composer is locked ("Choose an option above"); it unlocks, without moving, once the workflow lets the customer type.
- ▢ The workflow's messages show the chatbot's chat avatar, filling its circle (Design → Chat avatar: uploaded there, or an https link); without one, the logo on the brand colour (Design → Logo). Home shows the logo and the team faces chosen on the Design page.
- ▢ Motion: the sheet rises over the app with the app dimmed in a strip above it, and Close takes it down; a drag down closes it, a short one springs back; on Home scrolled to the top, pulling down moves the sheet. Signed in, the first open shows Home at once; Home's cards come in one after another. Home, Messages and Help fade through. Typing three lines, the thread moves up smoothly; a sent message is whole at once. History and a reopen are simply there. With Reduce Motion (iOS) or Remove animations (Android) on: no movement at all.
- ▢ An article with a button (e.g. "How do I book a course?"): the button opens the link in the browser. Tap 😞 under it: "Still need help?" and **Send us a message**; the reaction reaches the server once it has the route (`article_reaction_failed` until then).
- ▢ **Photo**: library and camera, on both phones (the iPhone permission prompts appear once); the photo shows in the inbox thread and in the app.
- ▢ Close the conversation from the inbox: the CSAT faces appear; rate and comment; the rating shows in the inbox.
- ▢ Messages: the closed conversation reads in full, with **Send us a message**.
- ▢ **Airplane mode**, then open support: the fallback screen; *Email us* opens the mail app; network back, *Try again* opens the messenger.
- ▢ Airplane mode **inside** a conversation: "Reconnecting…"; an agent replies meanwhile; network back, and the reply appears without reopening.
- ▢ "Open WhatsApp" chip: WhatsApp with the message filled in; uninstalled, wa.me in the browser.
- ▢ An article, its links go to the browser; back returns to the article.
- ▢ Close: the X on every screen, and Android back, each close what they should.
- ▢ Push: an agent replies while the app is in the background, a notification arrives, and tapping it opens the conversation. Tapped with the messenger already open, it goes to that conversation in it.
- ▢ Close support and open it again: what it showed is there at once, with no spinner or skeleton. Sign out and in as someone else: nothing of the first customer.
- ▢ In a conversation, with the keyboard up: a drag on the thread, or a tap on it, puts the keyboard away; Send keeps it up. Your message scrolls into view. Scroll up, have an agent reply: you stay where you were and a **New message** pill takes you down.
- ▢ Airplane mode in a conversation, send a message: it shows "Sending…"; network back, it goes once.
- ▢ The phone in dark mode: typed text and hints are dark on white.
- ▢ Android back: a screen at a time, then to the tab support opened on, then out of support. iPhone: a swipe from the left edge steps back.
- ▢ Badge: an agent replies while the messenger is closed, and the badge goes up within 30 s.
- ▢ Kill and reopen the app, open support: the same conversation is still there (also signed out).
- ▢ `onDiagnostic` lines appear in the app's logs (`messenger_ready {ms: …}`).

## Not in this version

- Sending a PDF or other file from the phone (the server takes PDFs; the app's picker is photos only).
- A sound in the open messenger (the push notification is the alert).
- Replying in a closed conversation: it reads in full, and **Send us a message** continues the open one or starts a new one, one open conversation per customer, as on the website.

## Working on the package

```bash
flutter pub get && flutter analyze && flutter test
```

- `test/controller_test.dart` and `test/widgets_test.dart` run against a pretend server and socket (`test/support/fakes.dart`).
- `test/fluid_test.dart` (opening, sending while connecting, the app going and coming back, push, sign-out) and `test/mobile_ui_test.dart` (the screens at phone sizes with the keyboard, the safe areas, large text and a dark app theme; `test/support/phone.dart`) cover 0.4.5, with `test/faces_test.dart` (the chat avatar, who is typing) and `test/motion_test.dart` (what moves, what does not, and nothing with less motion).
- `test/attributes_test.dart` covers what `login` puts in the sign-in body, signed and unverified, against a pretend server.
- `test/frames_test.dart` samples what moves every 16 ms on an iPhone 13 (0.4.6): the sheet's rise, close and drag, the skeleton and Home's stagger, articles, the composer, sending, the tabs, the bars and the reactions under an article.
- `GL_SCREENSHOTS=1 flutter test test/screenshots_test.dart` renders the main screens to `test/screens/*.png` (gitignored) with real fonts, a look at a change without a phone, and the moments in between: the sheet mid-open, Home's skeleton and stagger, an article with a button and its reactions.
- `test/live_test.dart` runs against a real API and Socket.IO server, started from the GL Support Chat server repository: `pnpm messenger:live` there prints `GL_LIVE_API=… GL_LIVE_PRODUCT=…`; set both and run `flutter test test/live_test.dart`. Without them it is skipped.
- The example app (`example/`) has only `lib/` and `pubspec.yaml`; run `flutter create .` inside it once to generate the Android and iOS folders.
- A release: bump `version` in `pubspec.yaml`, add a `CHANGELOG.md` entry, commit, tag `v<version>`, push the tag; apps move their `ref` to it.

© Get Licensed Ltd. All rights reserved. The source is public so the apps can install it; it is not licensed for other use.
