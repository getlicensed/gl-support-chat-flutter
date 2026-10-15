## 0.4.6

Fluid from the first tap: the messenger no longer opens all at once. **Nothing to change in an app but the `ref`**; the Flutter floor stays 3.24, and no dependency was added.

- **A sheet over the app.** The messenger rises as a sheet on every platform (our own, not Flutter 3.29's CupertinoSheetRoute): the app stays drawn behind it under a 40% scrim, in a strip below the status bar, and its top corners are rounded (12 on iOS, 16 on Android). Up in 400 ms on Material's emphasised deceleration, down in 250 ms on its emphasised acceleration (0.4.5's close barely moved, then rushed off). Drag it down past a quarter of its height, or flick it, and it closes; less, it springs back; a list at its top pulls it down. A conversation or article opened in it slides in within the sheet and goes down with it on Close. Opened on a conversation (a push tapped), the conversation is simply there as the sheet rises, rather than sliding in from the side at the same time. The status bar now sits over the dimmed app and keeps the app's own style.
- **Home at once.** After `login` succeeds, the package signs the messenger in (with `login`'s own sign-in) and fetches the conversations, the top articles, the logo and the team's photos in the background, without opening a connection; `present` then shows Home in its first frame. With nothing yet, Home is a skeleton in the chatbot's colours, logo, greeting and team (remembered on the phone beside the visitor id; nothing about the customer), its cards at their final heights, and Home cross-fades in over 200 ms. No more spinner on white.
- **Home comes in one part after another**: the header, then each card 60 ms later, fading in as it rises 12 points. The help card holds five skeleton rows at the articles' height, so it no longer jumps from 115 to 270 points; the articles fade in 30 ms apart. Pictures fade in over the initials they replace.
- **Articles.** The five on Home are fetched as Home opens, and every article is kept while the customer is signed in, so most open at once; otherwise three skeleton bars, then the article fades in with an 8-point rise. A paragraph that is only a link — Intercom's article buttons, as they were imported (71 of 228 articles) — is a button again, in the brand colour. Headings inside an article are 20/18/16 (they were bigger than its title); list items no longer have a gap under each; "Open in the help centre" is centred, with room to tap.
- **"Did this answer your question?"** under every article, with 😞 😐 😃. The face tapped grows, the others fade; it can be changed; it is kept for the article while signed in. It goes to `POST /widget/article-reaction` (`{slug, reaction}`, `sad` · `neutral` · `happy`) with the visitor's token. If it does not save, the customer sees nothing different and `onDiagnostic` gets `article_reaction_failed {status, slug}`. After 😞, "Still need help?" and **Send us a message**. Needs the server with that route; until then each reaction reports a 404, quietly.
- **The thread, without jumps.** The composer grows and shrinks over 150 ms, so the thread moves smoothly instead of 46 points in one frame. A sent message is whole at once (it was dimmed and faded in); "Sending…" shows only after 600 ms; the server's copy takes over the same row, and the time and tick fade in. While the workflow waits on a button, the composer is locked at its own height and says why, instead of vanishing (and coming back taller). The open conversation's first load fades in; a past conversation opened again shows at once and refreshes behind. The workflow's pictures keep a 4:3 box from the start.
- **Tabs fade through** (out in 90 ms, in over 210 ms from 92%), one tab at a time, and the status bar changes when the tab under it does. "Reconnecting…", the away-email bar and the "New message" pill open and close over 200 ms; chips dim softly.
- With Reduce Motion (iOS) or Remove animations (Android) on, none of it moves: everything is simply there.
- `test/frames_test.dart` checks all of this frame by frame (16 ms frames, iPhone 13 size).

## 0.4.5

Smoother and steadier on phones. Nothing to change in an app; a push handler can now open the exact conversation (see below and the README).

- **Opens at once.** Opened again for the same customer, the messenger shows what it had straight away and refreshes behind it. The first open after the app starts shows Home as soon as the sign-in and the Messages list are in, and right after `login` it uses that sign-in instead of making a second one; the open conversation follows. All of it goes the moment the customer signs out or someone else signs in: conversations, messages, unsent text, anything still waiting to go.
- **Sends while connecting.** Send no longer waits for the connection. A message shows at once, waits while the phone connects, and goes once, in the order written. A message that reached the team after its answer was lost (a drop, a locked phone) no longer shows as failed next to itself, with a Try again that would send it twice.
- **The keyboard goes away** on a drag of the thread or a tap outside the box. Send and the photo button keep it up.
- **The latest stays in view.** The customer's own message always comes into view, and so does a reply when they are at the latest. A customer reading further up keeps their place, and a "New message" pill takes them down.
- **Readable in dark mode.** In an app that follows the phone's dark mode, typed text, hints and the help search now read on white. They were light grey.
- **Back steps back.** Android back goes back a screen at a time, then to the tab the messenger opened on, then out; it used to close the whole messenger from a tab. On an iPhone a swipe from the left edge steps back.
- **Catches up when the app comes back** from the background, without duplicates. Nothing is marked read while the phone is in a pocket, and nothing of a customer who has just signed in is marked read as the screen before closes.
- **A push opens its conversation.** `GLSupportChatScreen.fromPush(message.data)` gives the conversation the push names (`GLSupportChatScreen.conversation(id)`). `GLSupportChatScreen.messages` now checks first, then opens the conversation with the unread reply. A push tapped while the messenger is open goes there in the messenger already up, not a second one. The messenger never closes the app's own screens: a lock or sign-in screen the app put over it stays.
- **Bigger tap targets.** Back, Close, chips, cards, the team's files and Send take taps on at least 44 × 44 points. Names, times and ticks read at 4.5:1.
- **Moves like Intercom's.** A reply, the AI's answer and the customer's own message fade in with a small rise (200 ms) and the thread glides up to them, rather than jumping; history, a reopen and a catch-up are simply there. The typing dots open and close in place, and the reply takes their place. Home, Messages and Help cross-fade; Home fades in after "Connecting to support…"; the messenger rises from the bottom over the app (300 ms, as before, now with the app dimming a little behind it) and goes down in 240 ms. With the phone's Reduce Motion (iOS) or Remove animations (Android) on, none of it: everything changes at once.
- **A face on the typing dots.** When a teammate types, their photo (the one beside their replies), or their initial if they have none; the chatbot's circle when the workflow types. Needs the server from 12 Oct, whose typing names the teammate; an older server's typing keeps the plain person.
- **The chatbot's own chat avatar.** `/widget/auth` now sends `avatarUrl` (optional; Design → Chat avatar, an https picture). It fills the chatbot's circle beside the workflow's messages, its typing, and the header when no team faces are shown. Without one the circle shows the logo on the brand colour, no longer on white, where GL's white logo vanished; with neither, the initial. Home keeps the logo.
- Smaller: while typing on a phone the away "leave your email" form is one line, and it no longer comes and goes (moving the thread) on every reopen and reconnect. Text typed and not sent is in the box at the next open, even after a chip was tapped. At large text sizes one line of text is a one-line box. A link the team wrote with a placeholder ("https://[booking-link]") no longer hides the message. Home's status dot stays grey until the connection is up, and "Active now" only shows once the server says so. The status bar matches the header. Once the messenger closes, only the open conversation's photos stay in memory.

## 0.4.4

- **Every `login` reaches the server with the identity it was given.** A `login` made while another sign-in was still out (the badge, the push token, an open messenger, an earlier `login`) used to join that one, which carried the customer before; the new name, email or details then waited for the next chat open or the 24-hour renewal. Now it waits for the one that is out and signs in afresh, and the token kept is the last customer's; the same after `logout`.
- **`login` returns `false` when the server refused the identity** (no `hash`, or a signature that does not match), as its documentation always said: the messenger still opens anonymously and `identity_rejected` gives the reason. It used to return `true`.
- **`GLSupportChatIdentity.withExtra({...})`** adds the app's own details (the custom attributes it sent Intercom) to a signed identity without touching the six signed fields, so the signature holds.
- Extra keys: a list or a map is sent as its JSON (it was Dart's `{a: 1}`), a value of spaces is dropped, and a key that is one of the six with other capitals or spaces (`Email`, ` name`) is never sent as a detail.
- README: every `login` updates the customer in the inbox, as Intercom did — call it at app start, after a profile refresh, and before `present` when the details may have changed; only `id` and `hash` are required; what the server does with the extra keys (kept on the contact, up to 100, secrets dropped).
- Nothing to change in an app. Recommended: call `login` with the fresh identity before `present`, where the Intercom code logged in on every chat tap.

## 0.4.3

- **An identity without a `hash` is now accepted as unverified.** `GLSupportChatIdentity.tryParse` needs only an `id`. `login` sends the same `identity` object, without a `hash`. Keys other than the six known ones are kept in the new `GLSupportChatIdentity.extra` and sent inside that object, unsigned and never able to replace one of the six. It is up to the server whether to show it as unverified; a server that only takes signed identities answers 401 and the plugin opens the chat anonymously, as before. **Breaking:** `GLSupportChatIdentity.hash` is now `String?` (use `isVerified`), and `tryParse({'id': 1})` no longer returns `null`. `messengerUrl()` carries only a signed identity.

## 0.4.2

- **The chatbot's logo beside the bot.** The workflow's messages carry the chatbot's logo (Chatbots → Design → Logo — uploaded there since 7 Oct, or an https link), and so does the chat header when the admin has chosen to show nobody's face — on white, whole whatever its shape; the initial when there is no logo. Agents keep their photos.
- **No composer while the bot waits on a button**, as in Intercom: it is hidden — not greyed out — until typing is allowed again.
- The team faces now follow the chatbot's Design page (Automatic / chosen / nobody); nothing to change in the app.

## 0.4.1

- **Its own repository** (7 Oct): `github.com/getlicensed/gl-support-chat-flutter`. An app changes only its pubspec — this `url`, `ref: v0.4.1`, and no `path` — see the README. The code is the same.
- Files the team sends in a chat (the inbox's new paperclip) show as the photo or the file, without the "[Photo]" / "[Document]" label the inbox keeps. Nothing to change in the app.

## 0.4.0

- **Device info for the team.** `configure(device: GLSupportChatDevice(os:, model:, manufacturer:, appVersion:, appBuild:))` — sent with every sign-in, with the platform and `appId` added by the package. The inbox shows it on each conversation as one chip ("iOS 17.4 · iPhone 15 Pro · v3.4.0 (412)"). Display only: never signed, never trusted for who the customer is. Needs the server with migration 0042.

## 0.3.0

Native screens instead of the WebView — the messenger is now Flutter, like Intercom's SDK. The Dart API is the same as 0.2.0's, so an app that used `configure`, `login`, `present`, `presentHelp`, `presentArticle`, `unreadCount`, `registerPushToken` and `logout` does not change.

- **Home**: greeting by first name, team faces, "Send us a message" with the team's status (online, back at…, by email), the most recent conversation, help search and top articles.
- **Messages**: every conversation the customer has had with this app's chatbot, newest first, with unread dots; closed ones open read-only, with "Send us a message".
- **Conversation**: agent, AI and workflow messages; the workflow's buttons and detail requests; CSAT faces and comment; typing both ways; ✓ / ✓✓; "New messages"; AI answers typed out as they stream; links; article and file cards; "leave your email" while nobody is online.
- **Photos**: from the library or the camera, resized on the phone (an iPhone's HEIC arrives as JPEG). The app needs the two iOS permission strings — see the README.
- **Help**: search (instant, then the server's full-text search) and articles drawn natively.
- Over the website messenger: a refused message says why, with Try again; a reconnect fetches what was missed; an expired visitor token (24 h) is renewed instead of leaving the chat on "Reconnecting…".
- The anonymous visitor id is kept per chatbot (shared_preferences), so an anonymous chat survives a restart; `logout()` starts the next person on the phone afresh.
- Removed: `flutter_inappwebview`, `GLSupportChatPage` from the public API, the `readyTimeout` option.
- New dependencies: `socket_io_client`, `image_picker`, `shared_preferences`, `flutter_widget_from_html_core` — each with a range that still resolves on Flutter 3.24.

## 0.2.0

The messenger can no longer leave a customer stuck.

- **Native fallback.** If the messenger has not said it is ready within 15 s (`readyTimeout`) — no signal, a server or load-balancer error, a script that did not load — a native screen offers *Try again*, *Open in browser*, and email / WhatsApp / phone / help-centre contacts (`GLSupportChatFallback`) that do not depend on our servers. A late "ready" replaces it by itself.
- **Always closable.** A native close button until the messenger has drawn its own; a second close can never pop the app's own screen.
- **Links open in the right app.** WhatsApp chips, help-centre links, `mailto:` and `tel:` go through `url_launcher` (`whatsapp://` without WhatsApp → wa.me; Android `intent://` → its web fallback). They were silently cancelled before.
- **Identity in the URL fragment**, not the query — never sent to a server, so never in an access log.
- **Never throws into the app.** `login` returns `bool` and never throws; `GLSupportChatIdentity.tryParse` accepts a numeric id and `null` fields and returns `null` for anything unusable; `logout` returns at once. Every HTTP call has a 10 s timeout; auth failures back off from 30 s to 10 min.
- **WebView process crashes recover** by recreating the WebView.
- Badge polling pauses in the background.
- `onDiagnostic` reports `messenger_ready`, `messenger_failed`, `messenger_restart`, `auth_failed`, `identity_rejected`, `link_failed`.
- Requires Flutter ≥ 3.24 / Dart ≥ 3.5; adds `url_launcher`.

## 0.1.0

First version: WebView messenger, signed identity, unread badge, push token registration.
