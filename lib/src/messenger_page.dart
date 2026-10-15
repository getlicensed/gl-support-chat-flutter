import 'dart:async';

import 'package:flutter/material.dart';

import 'api/models.dart';
import 'core/controller.dart';
import 'fallback.dart';
import 'links.dart';
import 'ui/common.dart';
import 'ui/navigation.dart';
import 'ui/sheet.dart';
import 'ui/tabs.dart';

/// Where the messenger opens.
class GLSupportChatScreen {
  const GLSupportChatScreen._(this.value);

  final String value;

  /// Home: greeting, "Send us a message", recent conversation, help search.
  static const home = GLSupportChatScreen._('home');

  /// The Messages list — straight into the conversation with unread
  /// replies, once the messenger has checked (what a push notification's
  /// tap wants).
  static const messages = GLSupportChatScreen._('messages');
  static const help = GLSupportChatScreen._('help');

  /// A single help-centre article, by slug.
  factory GLSupportChatScreen.article(String slug) => GLSupportChatScreen._('article:$slug');

  /// One conversation, by id — the `conversationId` a push notification
  /// carries. The open one to reply in; a closed one to read.
  factory GLSupportChatScreen.conversation(String id) => GLSupportChatScreen._('conversation:$id');

  /// The screen a tapped push notification asks for: its conversation, or
  /// the Messages list when it names none. Null when the push is not
  /// GL Support Chat's (its `data['type']` is not `message`).
  static GLSupportChatScreen? fromPush(Map<String, dynamic> data) {
    if (data['type'] != 'message') return null;
    final id = data['conversationId'];
    return id is String && id.trim().isNotEmpty ? GLSupportChatScreen.conversation(id.trim()) : messages;
  }

  String? get articleSlug => value.startsWith('article:') ? value.substring('article:'.length) : null;

  /// The conversation it opens, if it is one.
  String? get conversationId => value.startsWith('conversation:') ? value.substring('conversation:'.length) : null;
}

/// What the hosted web messenger's `start` understands for [screen]: it
/// opens on the list when asked for one conversation.
String webStart(GLSupportChatScreen screen) => screen.conversationId != null ? GLSupportChatScreen.messages.value : screen.value;

/// A screen asked for while the messenger is already up — a push tapped, or
/// `present` again — so it goes there instead of opening a second messenger.
class MessengerRequests extends ChangeNotifier {
  GLSupportChatScreen? _screen;
  final _gone = Completer<void>();

  /// Done when the page has gone: closed, or its navigator torn down
  /// without closing it (the app rebuilt its MaterialApp) — then nothing is
  /// on screen to take a request, and the next present opens a new one.
  Future<void> get gone => _gone.future;
  bool get isGone => _gone.isCompleted;

  void _pageGone() {
    if (!_gone.isCompleted) _gone.complete();
  }

  void go(GLSupportChatScreen screen) {
    _screen = screen;
    notifyListeners();
  }

  /// The screen asked for, once.
  GLSupportChatScreen? take() {
    final s = _screen;
    _screen = null;
    return s;
  }
}

/// The messenger, drawn natively, in its sheet.
///
/// It never leaves a customer on a blank or broken screen: while it signs in
/// Home shows as a skeleton, with a close button; if it cannot sign in — no signal,
/// our server down, [controller] null because `configure()` was never called
/// — a native screen offers Try again and ways to reach the team that do not
/// depend on our servers ([fallback]). Opened again for the same customer it
/// shows what it had at once, and refreshes behind it.
class GLSupportChatPage extends StatefulWidget {
  const GLSupportChatPage({
    super.key,
    required this.controller,
    this.screen = GLSupportChatScreen.home,
    this.fallback = const GLSupportChatFallback(),
    this.browserUrl,
    this.requests,
  });

  final MessengerController? controller;
  final GLSupportChatScreen screen;
  final GLSupportChatFallback fallback;

  /// The hosted messenger in a browser, offered on the failure screen.
  final String? browserUrl;

  /// Screens asked for while this one is open.
  final MessengerRequests? requests;

  @override
  State<GLSupportChatPage> createState() => _GLSupportChatPageState();
}

class _GLSupportChatPageState extends State<GLSupportChatPage> {
  /// The screen still to open on top of the tabs: the one asked for at the
  /// start, or since. Some wait for fresh data (which conversation is unread).
  GLSupportChatScreen? _pending;
  late int _tab;

  /// Moves on to show the tabs afresh on the tab a request asks for.
  int _tabsVersion = 0;
  int _resets = 0;
  ModalRoute<Object?>? _route;

  /// A context under the scope and the messenger's theme, for the screens
  /// this opens.
  BuildContext? _inner;
  bool _openScheduled = false;

  /// The fallback screen showed at the last build.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _pending = widget.screen;
    _tab = _tabFor(widget.screen);
    final c = widget.controller;
    if (c != null) {
      _resets = c.resets;
      c.attach();
    }
    widget.requests?.addListener(_onRequest);
    // Asked for while this was on its way up (a push tapped during the opening).
    final early = widget.requests?.take();
    if (early != null) _goTo(early);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(GLSupportChatPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.requests, widget.requests)) {
      old.requests?.removeListener(_onRequest);
      widget.requests?.addListener(_onRequest);
    }
    if (!identical(old.controller, widget.controller)) {
      old.controller?.detach();
      widget.controller?.attach();
      _resets = widget.controller?.resets ?? 0;
    }
  }

  @override
  void dispose() {
    widget.requests
      ?..removeListener(_onRequest)
      .._pageGone();
    widget.controller?.detach();
    super.dispose();
  }

  static int _tabFor(GLSupportChatScreen screen) {
    if (screen == GLSupportChatScreen.messages || screen.conversationId != null) return 1;
    if (screen == GLSupportChatScreen.help) return 2;
    return 0;
  }

  void _goTo(GLSupportChatScreen screen) {
    _pending = screen;
    _tab = _tabFor(screen);
    _tabsVersion++;
  }

  void _onRequest() {
    final screen = widget.requests?.take();
    final c = widget.controller;
    if (screen == null || !mounted || c == null) return;
    // Already reading the conversation it is about: stay there.
    final aboutLive = screen == GLSupportChatScreen.messages || (screen.conversationId != null && screen.conversationId == c.liveId);
    if (c.viewingLive && aboutLive) return;
    _closeScreensAbove();
    setState(() => _goTo(screen));
    // A push tapped: what it is about may have arrived only just now.
    if (screen == GLSupportChatScreen.messages || screen.conversationId != null) unawaited(c.refresh());
  }

  /// Back to the tabs: close the messenger's own screens the customer had
  /// opened over them. Never one of the app's: a lock or sign-in screen the
  /// app put over the messenger stays, and nothing under it is popped (a
  /// push tapped then is dropped; the conversation screens of a customer
  /// signed out remove themselves from under it).
  void _closeScreensAbove() {
    final route = _route;
    if (route == null || !route.isActive || route.isCurrent) return;
    Navigator.of(context).popUntil((r) => r == route || !(r.settings.name ?? '').startsWith('$messengerRoutePrefix/'));
  }

  void _scheduleOpen(MessengerController c) {
    if (_pending == null || _openScheduled) return;
    _openScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openScheduled = false;
      final inner = _inner;
      if (!mounted || inner == null || !inner.mounted) return;
      _openPending(inner, c);
    });
  }

  /// Open the screen asked for, once it can be: an article or the open
  /// conversation at once; for the rest, once the messenger knows which
  /// conversation has the unread reply.
  void _openPending(BuildContext context, MessengerController c) {
    final screen = _pending;
    if (screen == null || c.phase != MessengerPhase.ready) return;
    // The customer has opened something themselves meanwhile: leave them there.
    final route = _route;
    if (route != null && !route.isCurrent) {
      _pending = null;
      return;
    }
    // While the sheet is still rising, the screen is simply there and rises
    // with it: one motion, not a slide in from the side on top of the rise.
    final instant = route?.animation?.status == AnimationStatus.forward;
    final slug = screen.articleSlug;
    if (slug != null) {
      _pending = null;
      openArticle(context, slug, instant: instant);
      return;
    }
    final id = screen.conversationId;
    if (id != null) {
      if (id != c.liveId && c.refreshing) return; // it may be the open one by now
      _pending = null;
      _openConversation(context, c, id, instant: instant);
      return;
    }
    if (screen == GLSupportChatScreen.messages) {
      if (c.refreshing) return;
      _pending = null;
      final unread = c.unreadConversationId;
      if (unread != null) _openConversation(context, c, unread, instant: instant);
      return;
    }
    _pending = null;
  }

  void _openConversation(BuildContext context, MessengerController c, String id, {bool instant = false}) {
    if (id == c.liveId) {
      openLiveConversation(context, instant: instant);
      return;
    }
    ConversationSummary? row;
    for (final r in c.conversations) {
      if (r.id == id) row = r;
    }
    openConversation(context, row ?? ConversationSummary(id: id, open: false, lastMessageAt: DateTime.now()), instant: instant);
  }

  /// Someone else signed in (or nobody) while it was open: nothing opened
  /// for the customer before stays on screen.
  void _afterReset() {
    _pending = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _closeScreensAbove();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (c == null) return _FallbackScreen(fallback: widget.fallback, browserUrl: widget.browserUrl);
    return MessengerScope(
      controller: c,
      fallback: widget.fallback,
      child: Builder(builder: (context) {
        final controller = context.messenger;
        return Theme(
          data: messengerTheme(context, controller.brand),
          child: Builder(builder: (context) {
            _inner = context;
            if (controller.resets != _resets) {
              _resets = controller.resets;
              _afterReset();
            }
            // While it signs in for the first time the tabs are already up,
            // Home as a skeleton in the chatbot's colours; Home itself
            // cross-fades in over it (see [HomeTab]).
            final Widget shown;
            final failed = controller.phase == MessengerPhase.failed;
            // A screen opened over the tabs while it signed in (they work
            // meanwhile) would cover the way out: back to the fallback.
            if (failed && !_failed) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _closeScreensAbove();
              });
            }
            _failed = failed;
            if (failed) {
              shown = _FallbackScreen(key: const ValueKey<String>('failed'), fallback: widget.fallback, browserUrl: widget.browserUrl, onRetry: controller.start);
            } else {
              if (controller.phase == MessengerPhase.ready) _scheduleOpen(controller);
              shown = MessengerTabs(key: ValueKey<int>(_tabsVersion), initialTab: _tab);
            }
            return AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
              child: shown,
            );
          }),
        );
      }),
    );
  }
}

/// The messenger's own route: a sheet that rises over the app, which shows
/// dimmed in a strip above it (see [MessengerSheetRoute]). A phone that asks
/// for less motion gets it at once both ways.
Route<void> messengerRoute(Widget page, {required bool reduceMotion}) => MessengerSheetRoute(page: page, reduceMotion: reduceMotion);

/// "We can't open the chat right now" — with Try again, and the contacts that
/// work without our servers.
class _FallbackScreen extends StatelessWidget {
  const _FallbackScreen({super.key, required this.fallback, this.browserUrl, this.onRetry});

  final GLSupportChatFallback fallback;
  final String? browserUrl;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mail = mailtoLink(fallback.email, subject: fallback.emailSubject);
    final whatsapp = whatsappLink(fallback.whatsappNumber);
    final phone = telLink(fallback.phoneNumber);
    final helpUrl = fallback.helpUrl;
    final help = helpUrl == null ? null : Uri.tryParse(helpUrl);
    final browser = browserUrl == null ? null : Uri.tryParse(browserUrl!);
    final hasContacts = mail != null || whatsapp != null || phone != null || help != null;
    final retry = onRetry;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 72, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.forum_outlined, size: 48, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text("We can't open the chat right now", textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'It may be your connection, or the chat may be briefly unavailable. '
                    'Try again, or reach the team another way.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  if (retry != null) FilledButton(onPressed: retry, child: const Text('Try again')),
                  if (browser != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: () => openExternal(context, browser), child: const Text('Open in browser')),
                  ],
                  if (hasContacts) ...[
                    const SizedBox(height: 24),
                    const Divider(),
                  ],
                  if (mail != null) _ContactRow(icon: Icons.email_outlined, label: 'Email ${fallback.email}', onTap: () => openExternal(context, mail)),
                  if (whatsapp != null) _ContactRow(icon: Icons.chat_outlined, label: 'WhatsApp us', onTap: () => openExternal(context, whatsapp)),
                  if (phone != null) _ContactRow(icon: Icons.phone_outlined, label: 'Call ${fallback.phoneNumber}', onTap: () => openExternal(context, phone)),
                  if (help != null) _ContactRow(icon: Icons.help_outline, label: 'Help centre', onTap: () => openExternal(context, help)),
                ],
              ),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: RoundIconButton(icon: Icons.close, tooltip: 'Close', onTap: () => closeMessenger(context)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(leading: Icon(icon), title: Text(label), onTap: onTap, contentPadding: EdgeInsets.zero);
}
