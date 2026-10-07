import 'package:flutter/material.dart';

import 'core/controller.dart';
import 'fallback.dart';
import 'links.dart';
import 'ui/common.dart';
import 'ui/navigation.dart';
import 'ui/tabs.dart';

/// Where the messenger opens.
class GLSupportChatScreen {
  const GLSupportChatScreen._(this.value);

  final String value;

  /// Home: greeting, "Send us a message", recent conversation, help search.
  static const home = GLSupportChatScreen._('home');

  /// The Messages list — straight into the open conversation when it has
  /// unread replies (what a push notification's tap wants).
  static const messages = GLSupportChatScreen._('messages');
  static const help = GLSupportChatScreen._('help');

  /// A single help-centre article, by slug.
  factory GLSupportChatScreen.article(String slug) => GLSupportChatScreen._('article:$slug');

  String? get articleSlug => value.startsWith('article:') ? value.substring('article:'.length) : null;
}

/// The messenger, full screen, drawn natively.
///
/// It never leaves a customer on a blank or broken screen: while it signs in
/// there is a spinner and a close button; if it cannot sign in — no signal,
/// our server down, [controller] null because `configure()` was never called
/// — a native screen offers Try again and ways to reach the team that do not
/// depend on our servers ([fallback]).
class GLSupportChatPage extends StatefulWidget {
  const GLSupportChatPage({
    super.key,
    required this.controller,
    this.screen = GLSupportChatScreen.home,
    this.fallback = const GLSupportChatFallback(),
    this.browserUrl,
  });

  final MessengerController? controller;
  final GLSupportChatScreen screen;
  final GLSupportChatFallback fallback;

  /// The hosted messenger in a browser, offered on the failure screen.
  final String? browserUrl;

  @override
  State<GLSupportChatPage> createState() => _GLSupportChatPageState();
}

class _GLSupportChatPageState extends State<GLSupportChatPage> {
  bool _startHandled = false;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    if (c != null && c.phase != MessengerPhase.ready) c.start();
  }

  /// Once, when the messenger is first ready: the screen it was asked to open.
  void _openStartScreen(BuildContext context, MessengerController c) {
    if (_startHandled) return;
    _startHandled = true;
    final slug = widget.screen.articleSlug;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      if (slug != null) {
        openArticle(context, slug);
      } else if (widget.screen == GLSupportChatScreen.messages && c.liveId != null && c.totalUnread > 0) {
        openLiveConversation(context);
      }
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
            switch (controller.phase) {
              case MessengerPhase.loading:
                return const _Loading();
              case MessengerPhase.failed:
                return _FallbackScreen(fallback: widget.fallback, browserUrl: widget.browserUrl, onRetry: controller.start);
              case MessengerPhase.ready:
                _openStartScreen(context, controller);
                return MessengerTabs(
                  initialTab: widget.screen == GLSupportChatScreen.messages ? 1 : (widget.screen == GLSupportChatScreen.help ? 2 : 0),
                );
            }
          }),
        );
      }),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          children: [
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Connecting to support…', style: TextStyle(fontSize: 14, color: Palette.muted)),
                ],
              ),
            ),
            // Always a way out, even before anything has loaded.
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

/// "We can't open the chat right now" — with Try again, and the contacts that
/// work without our servers.
class _FallbackScreen extends StatelessWidget {
  const _FallbackScreen({required this.fallback, this.browserUrl, this.onRetry});

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
