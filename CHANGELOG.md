## 0.4.2

- **The chatbot's logo beside the bot.** The workflow's messages carry the chatbot's logo (Chatbots → Design → Logo URL), and so does the chat header when the admin has chosen to show nobody's face — on white, whole whatever its shape; the initial when there is no logo. Agents keep their photos.
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
