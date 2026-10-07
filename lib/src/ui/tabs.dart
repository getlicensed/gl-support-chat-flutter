import 'dart:async';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../core/format.dart';
import 'common.dart';
import 'navigation.dart';

/// Home · Messages · Help, with the bar along the bottom — Intercom's spaces.
class MessengerTabs extends StatefulWidget {
  const MessengerTabs({super.key, this.initialTab = 0});

  /// 0 Home, 1 Messages, 2 Help.
  final int initialTab;

  @override
  State<MessengerTabs> createState() => _MessengerTabsState();
}

class _MessengerTabsState extends State<MessengerTabs> {
  late int _tab = widget.initialTab;
  bool _focusHelpSearch = false;

  void _go(int tab, {bool focusSearch = false}) => setState(() {
        _tab = tab;
        _focusHelpSearch = focusSearch;
      });

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    return Scaffold(
      backgroundColor: Colors.white,
      body: IndexedStack(
        index: _tab,
        children: [
          HomeTab(onSearch: () => _go(2, focusSearch: true), onMessages: () => _go(1)),
          const MessagesTab(),
          HelpTab(autofocus: _focusHelpSearch && _tab == 2),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: Palette.border))),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: Colors.white,
            indicatorColor: brand.light,
            labelTextStyle: WidgetStateProperty.resolveWith(
              (states) => TextStyle(
                fontSize: 13,
                fontWeight: states.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
                color: states.contains(WidgetState.selected) ? brand.primary : const Color(0xFF4B5563),
              ),
            ),
            iconTheme: WidgetStateProperty.resolveWith(
              (states) => IconThemeData(color: states.contains(WidgetState.selected) ? brand.primary : const Color(0xFF4B5563)),
            ),
          ),
          child: NavigationBar(
            height: 68,
            selectedIndex: _tab,
            onDestinationSelected: (i) => _go(i),
            destinations: [
              const NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: c.totalUnread > 0,
                  backgroundColor: Palette.danger,
                  label: Text(c.totalUnread > 9 ? '9+' : '${c.totalUnread}'),
                  child: const Icon(Icons.chat_bubble_outline),
                ),
                selectedIcon: Badge(
                  isLabelVisible: c.totalUnread > 0,
                  backgroundColor: Palette.danger,
                  label: Text(c.totalUnread > 9 ? '9+' : '${c.totalUnread}'),
                  child: const Icon(Icons.chat_bubble),
                ),
                label: 'Messages',
              ),
              const NavigationDestination(icon: Icon(Icons.help_outline), selectedIcon: Icon(Icons.help), label: 'Help'),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// Home
// ==========================================================================

class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.onSearch, required this.onMessages});

  final VoidCallback onSearch;
  final VoidCallback onMessages;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final s = c.session!;
    final brand = c.brand;
    final status = presenceLines(c.agentsOnline, s.officeHours);
    final subtitle = (s.welcomeSubtitle ?? '').trim();
    final recent = c.conversations.isEmpty ? null : c.conversations.first;
    return ColoredBox(
      color: Palette.page,
      child: Stack(
        children: [
          // The brand band behind the top of the page, fading into it.
          Container(
            height: 340,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: const Alignment(-0.17, -1),
                end: const Alignment(0.17, 1),
                colors: [brand.soft, brand.primary, brand.hover],
                stops: const [0, 0.58, 1],
              ),
            ),
          ),
          const Positioned(
            top: 250,
            left: 0,
            right: 0,
            height: 90,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00F5F6F7), Palette.page],
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
              children: [
                Row(
                  children: [
                    _Logo(session: s),
                    const Spacer(),
                    const TeamFaces(size: 40),
                    const SizedBox(width: 12),
                    RoundIconButton(icon: Icons.close, tooltip: 'Close', light: true, onTap: () => closeMessenger(context)),
                  ],
                ),
                const SizedBox(height: 34),
                Text(
                  greetingFor(s),
                  style: const TextStyle(fontSize: 29, height: 1.18, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.4),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(subtitle, style: const TextStyle(fontSize: 15, height: 1.45, color: Color(0xEBFFFFFF))),
                ],
                const SizedBox(height: 26),
                if (recent != null) ...[
                  _RecentCard(conversation: recent),
                  const SizedBox(height: 14),
                ],
                MessengerCard(
                  onTap: () => openLiveConversation(context),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Send us a message', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.text)),
                            const SizedBox(height: 3),
                            Row(
                              children: [
                                StatusDot(away: status.away, size: 7),
                                const SizedBox(width: 6),
                                Flexible(child: Text(status.home, style: const TextStyle(fontSize: 14, color: Palette.muted))),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(Icons.send, size: 22, color: brand.primary),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _HomeHelpCard(onSearch: onSearch),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.session});
  final MessengerSession session;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final tile = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: Text(
        session.productLabel.isEmpty ? 'S' : session.productLabel.characters.first.toUpperCase(),
        style: TextStyle(color: brand.primary, fontSize: 18, fontWeight: FontWeight.w800),
      ),
    );
    final logo = session.logoUrl;
    if (logo == null) return tile;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140, maxHeight: 40),
      child: Image.network(logo, height: 40, fit: BoxFit.contain, errorBuilder: (_, __, ___) => tile),
    );
  }
}

/// The latest conversation, on Home — Intercom's "Recent message".
class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.conversation});
  final ConversationSummary conversation;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final unread = conversation.unreadCount > 0;
    return MessengerCard(
      onTap: () => openConversation(context, conversation),
      padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Recent message', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Palette.text)),
          const SizedBox(height: 12),
          Row(
            children: [
              _ConversationAvatar(conversation: conversation, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      previewLine(conversation),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: Palette.text, fontWeight: unread ? FontWeight.w600 : FontWeight.w400),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_conversationName(c.session?.productLabel ?? '', conversation)} · ${shortAgo(conversation.lastMessageAt, DateTime.now())}',
                      style: const TextStyle(fontSize: 13, color: Palette.muted),
                    ),
                  ],
                ),
              ),
              if (unread) ...[
                const SizedBox(width: 8),
                Container(width: 8, height: 8, decoration: const BoxDecoration(color: Palette.danger, shape: BoxShape.circle)),
              ],
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: context.brand.primary),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeHelpCard extends StatelessWidget {
  const _HomeHelpCard({required this.onSearch});
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    Widget note(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Text(text, style: const TextStyle(fontSize: 13, color: Palette.muted)),
        );
    final List<Widget> rows;
    if (c.session?.helpBaseUrl == null) {
      rows = [note('Help articles are not available right now.')];
    } else if (!c.articlesLoaded) {
      rows = [note('Loading articles…')];
    } else if (c.articles.isEmpty) {
      rows = [note('Help articles will appear here once published.')];
    } else {
      rows = [
        for (final a in c.articles.take(5))
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => openArticle(context, a.slug, title: a.title),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                children: [
                  Expanded(child: Text(a.title, style: const TextStyle(fontSize: 15, height: 1.4, color: Palette.body))),
                  Icon(Icons.chevron_right, size: 18, color: brand.primary),
                ],
              ),
            ),
          ),
      ];
    }
    return MessengerCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            label: 'Search for help',
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onSearch,
              child: Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(color: const Color(0xFFF1F3F4), borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('Search for help', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF1F2937))),
                    ),
                    Icon(Icons.search, size: 20, color: brand.primary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          ...rows,
        ],
      ),
    );
  }
}

// ==========================================================================
// Messages
// ==========================================================================

String _conversationName(String productLabel, ConversationSummary c) {
  final agent = (c.agentName ?? '').trim();
  if (agent.isNotEmpty) return agent;
  return productLabel.isEmpty ? 'Support' : productLabel;
}

class _ConversationAvatar extends StatelessWidget {
  const _ConversationAvatar({required this.conversation, this.size = 40});
  final ConversationSummary conversation;
  final double size;

  @override
  Widget build(BuildContext context) {
    final label = _conversationName(context.messenger.session?.productLabel ?? '', conversation);
    if (conversation.agentId != null) return PersonAvatar(name: label, photoPath: conversation.agentAvatarPath, size: size);
    return InitialAvatar(label: label, size: size);
  }
}

class MessagesTab extends StatelessWidget {
  const MessagesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final Widget body;
    if (!c.conversationsLoaded) {
      body = const Center(child: CircularProgressIndicator());
    } else if (c.conversations.isEmpty) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 40, color: brand.primary),
              const SizedBox(height: 14),
              const Text('No messages', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Palette.text)),
              const SizedBox(height: 6),
              const Text('Messages from the team will be shown here', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Palette.muted)),
            ],
          ),
        ),
      );
    } else {
      body = RefreshIndicator(
        color: brand.primary,
        onRefresh: c.refreshConversations,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: c.conversations.length,
          separatorBuilder: (_, __) => const Divider(height: 1, indent: 72, color: Color(0xFFF1F3F4)),
          itemBuilder: (context, i) {
            final conv = c.conversations[i];
            final unread = conv.unreadCount > 0;
            return InkWell(
              onTap: () => openConversation(context, conv),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    _ConversationAvatar(conversation: conv),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            previewLine(conv),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, color: Palette.text, fontWeight: unread ? FontWeight.w600 : FontWeight.w400),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '${_conversationName(c.session?.productLabel ?? '', conv)} · ${shortAgo(conv.lastMessageAt, DateTime.now())}'
                            '${conv.open ? '' : ' · Closed'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: Palette.muted),
                          ),
                        ],
                      ),
                    ),
                    if (unread) ...[
                      const SizedBox(width: 8),
                      Container(width: 9, height: 9, decoration: const BoxDecoration(color: Palette.danger, shape: BoxShape.circle)),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      );
    }
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          const _TabHeader(title: 'Messages'),
          const ConnectionBar(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: body),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 20,
                  child: Center(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: brand.primary,
                        foregroundColor: brand.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                        shape: const StadiumBorder(),
                        textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      onPressed: () => openLiveConversation(context),
                      icon: const Icon(Icons.send, size: 18),
                      label: const Text('Send us a message'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TabHeader extends StatelessWidget {
  const _TabHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 14, 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F3F4)))),
      child: Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Palette.text))),
          RoundIconButton(icon: Icons.close, tooltip: 'Close', onTap: () => closeMessenger(context), size: 34),
        ],
      ),
    );
  }
}

// ==========================================================================
// Help
// ==========================================================================

class HelpTab extends StatefulWidget {
  const HelpTab({super.key, this.autofocus = false});
  final bool autofocus;

  @override
  State<HelpTab> createState() => _HelpTabState();
}

class _HelpTabState extends State<HelpTab> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  List<ArticleSummary>? _serverResults;
  String _serverQuery = '';

  @override
  void didUpdateWidget(HelpTab old) {
    super.didUpdateWidget(old);
    if (widget.autofocus && !old.autofocus) _focus.requestFocus();
  }

  void _changed(String value) {
    setState(() => _serverResults = null);
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 2) return;
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      final found = await context.messenger.searchArticles(q);
      if (!mounted || _query.text.trim() != q || found == null) return;
      setState(() {
        _serverResults = found;
        _serverQuery = q;
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final q = _query.text.trim();
    final results = _serverResults != null && _serverQuery == q ? _serverResults! : c.localSearch(q);
    Widget note(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
          child: Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Palette.muted)),
        );
    final helpUrl = c.helpUrl;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          const _TabHeader(title: 'Help'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _query,
              focusNode: _focus,
              onChanged: _changed,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search for help',
                filled: true,
                fillColor: const Color(0xFFF1F3F4),
                suffixIcon: Icon(Icons.search, color: brand.primary),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: [
                if (c.session?.helpBaseUrl == null)
                  note('Help articles are not available right now.')
                else if (!c.articlesLoaded)
                  note('Loading articles…')
                else if (results.isEmpty)
                  note(q.isEmpty ? 'No articles published yet.' : 'No articles match “$q”.')
                else
                  for (final a in results)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => openArticle(context, a.slug, title: a.title),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(a.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: Palette.text)),
                                  if ((a.description ?? '').isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      a.description!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13, color: Palette.muted),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 18, color: brand.primary),
                          ],
                        ),
                      ),
                    ),
                if (helpUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Center(
                      child: TextButton(
                        onPressed: () => openExternal(context, Uri.parse(helpUrl)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Open the help centre', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: brand.primary)),
                            const SizedBox(width: 4),
                            Icon(Icons.open_in_new, size: 14, color: brand.primary),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
