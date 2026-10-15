import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/models.dart';
import '../core/controller.dart';
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
    // Back (Android's button or gesture) steps back to the tab the messenger
    // opened on before it closes the messenger.
    return PopScope<Object?>(
      canPop: _tab == widget.initialTab,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(widget.initialTab);
      },
      child: _tabs(context),
    );
  }

  Widget _tabs(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    return Scaffold(
      backgroundColor: Colors.white,
      body: _TabStack(
        index: _tab,
        // Home's top is the brand colour; Messages and Help are white.
        styles: [statusBarOnBrand(brand), statusBarStyle(darkIcons: true), statusBarStyle(darkIcons: true)],
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

/// The tabs, each kept alive as an IndexedStack keeps them (a search typed
/// in Help, the list's place), changing by Material's fade-through: the tab
/// going fades out in 90 ms, then the one coming fades in over 210 ms as it
/// grows from 92% — one tab on screen at a time, never two over each other.
/// The status bar changes with what is on screen, when the new tab shows,
/// not a frame (or 90 ms) early. At once on a phone that asks for less
/// motion. As in an IndexedStack, a tab not shown takes no focus: a search
/// left typed in Help lets the keyboard go.
class _TabStack extends StatefulWidget {
  const _TabStack({required this.index, required this.styles, required this.children});
  final int index;
  final List<SystemUiOverlayStyle> styles;
  final List<Widget> children;

  static const time = Duration(milliseconds: 300);

  /// The share of [time] the tab going takes to fade out: 90 ms.
  static const out = 0.3;
  static const grow = 0.92;

  @override
  State<_TabStack> createState() => _TabStackState();
}

class _TabStackState extends State<_TabStack> with SingleTickerProviderStateMixin {
  // Linear, so a change cut short is picked up exactly where it was.
  late final AnimationController _t = AnimationController(vsync: this, duration: _TabStack.time, value: 1)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && _leaving != null && mounted) setState(() => _leaving = null);
    });
  late final CurvedAnimation _out = CurvedAnimation(parent: _t, curve: const Interval(0, _TabStack.out));
  late final Animation<double> _goes = ReverseAnimation(_out);
  late final CurvedAnimation _comes = CurvedAnimation(parent: _t, curve: const Interval(_TabStack.out, 1));
  late final CurvedAnimation _grows = CurvedAnimation(parent: _t, curve: const Interval(_TabStack.out, 1, curve: Curves.easeOutCubic));
  late final Animation<double> _scale = Tween<double>(begin: _TabStack.grow, end: 1).animate(_grows);

  /// The tab going, while it fades out.
  int? _leaving;

  /// The tab on screen with [current] the one asked for, and how much of it shows.
  (int, double) _onScreen(int current) {
    final v = _t.value;
    final leaving = _leaving;
    if (leaving != null && v < _TabStack.out) return (leaving, 1 - v / _TabStack.out);
    return (current, ((v - _TabStack.out) / (1 - _TabStack.out)).clamp(0.0, 1.0));
  }

  @override
  void didUpdateWidget(_TabStack old) {
    super.didUpdateWidget(old);
    if (old.index == widget.index) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _leaving = null;
      _t.value = 1;
      return;
    }
    final (shown, amount) = _onScreen(old.index);
    if (shown == widget.index) {
      // Straight back to the tab still on screen: it comes back from as
      // much of it as shows, with nothing to fade out first.
      _leaving = null;
      _t.forward(from: _TabStack.out + (1 - _TabStack.out) * amount);
    } else {
      // The one on screen fades out from as much as shows, then the new one in.
      _leaving = shown;
      _t.forward(from: _TabStack.out * (1 - amount));
    }
  }

  @override
  void dispose() {
    _out.dispose();
    _comes.dispose();
    _grows.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.children.length;
    final current = widget.index;
    final leaving = _leaving;
    // Painted in this order: the hidden ones, the one going, the one coming.
    final order = <int>[
      for (var i = 0; i < n; i++)
        if (i != current && i != leaving) i,
      if (leaving != null && leaving != current) leaving,
      current,
    ];
    final stack = Stack(
      children: [
        for (final i in order)
          // Keyed, so each tab keeps its state when the order changes.
          KeyedSubtree(
            key: ValueKey<int>(i),
            child: Offstage(
              offstage: i != current && i != leaving,
              child: TickerMode(
                enabled: i == current || i == leaving,
                child: ExcludeFocus(
                  excluding: i != current,
                  child: IgnorePointer(
                    ignoring: i != current,
                    child: FadeTransition(
                      opacity: i == current ? _comes : (i == leaving ? _goes : kAlwaysCompleteAnimation),
                      child: ScaleTransition(
                        scale: i == current ? _scale : kAlwaysCompleteAnimation,
                        // Messages and Help have no background of their own: white.
                        child: ColoredBox(color: Colors.white, child: widget.children[i]),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return AnimatedBuilder(
      animation: _t,
      child: stack,
      builder: (context, stack) => AnnotatedRegion<SystemUiOverlayStyle>(value: widget.styles[_onScreen(current).$1], child: stack!),
    );
  }
}

// ==========================================================================
// Home
// ==========================================================================

/// Home: the skeleton while the messenger signs in for the first time,
/// then Home itself, cross-faded over 200 ms.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key, required this.onSearch, required this.onMessages});

  final VoidCallback onSearch;
  final VoidCallback onMessages;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final ready = c.phase == MessengerPhase.ready && c.session != null;
    return AnimatedSwitcher(
      // A new one for each customer: after a sign-out the one before's Home
      // goes at once, never faded out over the next one's skeleton.
      key: ValueKey<int>(c.resets),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
      child: ready ? _Home(key: const ValueKey<String>('home'), onSearch: onSearch) : const HomeSkeleton(key: ValueKey<String>('skeleton')),
    );
  }
}

/// The brand band behind the top of Home, fading into the page.
class _Band extends StatelessWidget {
  const _Band({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return ColoredBox(
      color: Palette.page,
      child: Stack(
        children: [
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
          SafeArea(bottom: false, child: child),
        ],
      ),
    );
  }
}

const _homePadding = EdgeInsets.fromLTRB(20, 18, 20, 24);
const _greetingStyle = TextStyle(fontSize: 29, height: 1.18, fontWeight: FontWeight.w700, color: Colors.white, letterSpacing: -0.4);
const _subtitleStyle = TextStyle(fontSize: 15, height: 1.45, color: Color(0xEBFFFFFF));
const _sendTitleStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Palette.text);
const _statusStyle = TextStyle(fontSize: 14, color: Palette.muted);

/// Home as it will be, before anything has come back: the brand band in the
/// chatbot's colour (remembered from last time), its logo, team and
/// greeting when known, and the cards at their final heights with
/// shimmering bars where the words will be. Only Close works.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final look = c.look;
    final name = c.lookName;
    final known = look != null || (name ?? '').trim().isNotEmpty;
    final subtitle = (look?.subtitle ?? '').trim();
    return Shimmer(
      child: _Band(
        child: ListView(
          primary: false,
          physics: const NeverScrollableScrollPhysics(),
          padding: _homePadding,
          children: [
            Row(
              children: [
                _Logo(url: look?.logoUrl, label: look?.productLabel ?? ''),
                const Spacer(),
                if (look != null) TeamFaces(size: 40, team: look.team),
                const SizedBox(width: 8),
                RoundIconButton(icon: Icons.close, tooltip: 'Close', light: true, onTap: () => closeMessenger(context)),
              ],
            ),
            const SizedBox(height: 34),
            if (known)
              Text(greeting(name: name, chatbotGreeting: look?.greeting), style: _greetingStyle)
            else
              const TextBar(style: _greetingStyle, width: 190, onBrand: true),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(subtitle, style: _subtitleStyle),
            ],
            const SizedBox(height: 26),
            // What a screen reader hears for the cards still to come.
            Semantics(
              container: true,
              label: 'Connecting to support…',
              child: const ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    MessengerCard(
                      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                TextBar(style: _sendTitleStyle, width: 150),
                                SizedBox(height: 3),
                                Row(
                                  children: [
                                    StatusDot(away: true, size: 7),
                                    SizedBox(width: 6),
                                    TextBar(style: _statusStyle, width: 180),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          SizedBox(width: 12),
                          SkeletonBar(width: 22, height: 22),
                        ],
                      ),
                    ),
                    SizedBox(height: 14),
                    _HomeHelpCard(onSearch: null),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home. The first time it shows in an open messenger its parts come in
/// one after another — the header, then each card 60 ms after the one
/// before — each fading in as it rises 12 points, so it never lands all at
/// once. Not for a phone that asks for less motion.
class _Home extends StatefulWidget {
  const _Home({super.key, required this.onSearch});
  final VoidCallback onSearch;

  /// When each part starts, and how long it takes.
  static const step = Duration(milliseconds: 60);
  static const each = Duration(milliseconds: 280);
  static const rise = 12.0;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> with SingleTickerProviderStateMixin {
  static const _parts = 4;
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: _Home.step * (_parts - 1) + _Home.each,
  );
  late final List<CurvedAnimation> _part = <CurvedAnimation>[
    for (var i = 0; i < _parts; i++)
      CurvedAnimation(
        parent: _in,
        curve: Interval(
          (_Home.step * i).inMilliseconds / _in.duration!.inMilliseconds,
          (_Home.step * i + _Home.each).inMilliseconds / _in.duration!.inMilliseconds,
          curve: Curves.easeOutCubic,
        ),
      ),
  ];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _in.value = 1;
    } else {
      _in.forward();
    }
  }

  @override
  void dispose() {
    for (final p in _part) {
      p.dispose();
    }
    _in.dispose();
    super.dispose();
  }

  Widget _stagger(int i, Widget child) {
    final t = _part[i];
    return FadeTransition(
      opacity: t,
      child: AnimatedBuilder(
        animation: t,
        child: child,
        builder: (_, child) => Transform.translate(offset: Offset(0, _Home.rise * (1 - t.value)), child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final s = c.session;
    if (s == null) return const SizedBox.shrink();
    final brand = c.brand;
    final status = presenceLines(c.agentsOnline, s.officeHours);
    final subtitle = (s.welcomeSubtitle ?? '').trim();
    final recent = c.conversations.isEmpty ? null : c.conversations.first;
    var card = 1;
    return _Band(
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: _homePadding,
        children: [
          _stagger(
            0,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Logo(url: s.logoUrl, label: s.productLabel),
                    const Spacer(),
                    const TeamFaces(size: 40),
                    // 12 to the circle: its 44-point touch area adds 4.
                    const SizedBox(width: 8),
                    RoundIconButton(icon: Icons.close, tooltip: 'Close', light: true, onTap: () => closeMessenger(context)),
                  ],
                ),
                const SizedBox(height: 34),
                Text(greetingFor(s), style: _greetingStyle),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(subtitle, style: _subtitleStyle),
                ],
              ],
            ),
          ),
          const SizedBox(height: 26),
          if (recent != null) ...[
            _stagger(card++, _RecentCard(conversation: recent)),
            const SizedBox(height: 14),
          ],
          _stagger(
            card++,
            MessengerCard(
              onTap: () => openLiveConversation(context),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Send us a message', style: _sendTitleStyle),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            // Green only while connected, as in the chat header:
                            // before, nobody's presence is known.
                            StatusDot(away: status.away || !c.connected, size: 7),
                            const SizedBox(width: 6),
                            Flexible(child: Text(status.home, style: _statusStyle)),
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
          ),
          const SizedBox(height: 14),
          _stagger(card, _HomeHelpCard(onSearch: widget.onSearch)),
        ],
      ),
    );
  }
}

/// The chatbot's logo on Home's band, faded in once it has loaded (it is
/// usually fetched at sign-in, and then simply there); its initial on a
/// white tile without one.
class _Logo extends StatelessWidget {
  const _Logo({required this.url, required this.label});
  final String? url;
  final String label;

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
        label.isEmpty ? 'S' : label.characters.first.toUpperCase(),
        style: TextStyle(color: brand.primary, fontSize: 18, fontWeight: FontWeight.w800),
      ),
    );
    final logo = url;
    if (logo == null) return tile;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 140, maxHeight: 40),
      child: Image.network(logo, height: 40, fit: BoxFit.contain, errorBuilder: (_, __, ___) => tile, frameBuilder: fadeIn()),
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

/// A row of articles, and the skeleton rows that stand for them: one line
/// of title is [articleRowHeight] tall either way, so nothing jumps.
const articleRowHeight = 46.0;

/// Five shimmering rows where the top articles will be.
class ArticleRowsSkeleton extends StatelessWidget {
  const ArticleRowsSkeleton({super.key, this.rows = 5, this.inset = 14});
  final int rows;
  final double inset;

  static const _widths = <double>[0.78, 0.62, 0.7, 0.55, 0.66];

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: LayoutBuilder(
        builder: (context, box) => Column(
          children: [
            for (var i = 0; i < rows; i++)
              SizedBox(
                height: articleRowHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: inset),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: SkeletonBar(width: (box.maxWidth - inset * 2) * _widths[i % _widths.length], height: 12),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The help card on Home: the search, then the top five articles. While
/// they load, five skeleton rows of the same height stand for them; when
/// they come, each row fades in over 150 ms, 30 ms after the one above. A
/// card whose list is shorter than five eases to its height.
class _HomeHelpCard extends StatefulWidget {
  const _HomeHelpCard({required this.onSearch});

  /// Null in the skeleton: nothing to search yet.
  final VoidCallback? onSearch;

  @override
  State<_HomeHelpCard> createState() => _HomeHelpCardState();
}

class _HomeHelpCardState extends State<_HomeHelpCard> with SingleTickerProviderStateMixin {
  static const _fade = Duration(milliseconds: 150);
  static const _apart = Duration(milliseconds: 30);
  static const _rows = 5;

  late final AnimationController _in = AnimationController(vsync: this, duration: _fade + _apart * (_rows - 1), value: 1);
  late final List<CurvedAnimation> _row = <CurvedAnimation>[
    for (var i = 0; i < _rows; i++)
      CurvedAnimation(
        parent: _in,
        curve: Interval(
          (_apart * i).inMilliseconds / _in.duration!.inMilliseconds,
          (_apart * i + _fade).inMilliseconds / _in.duration!.inMilliseconds,
          curve: Curves.easeOut,
        ),
      ),
  ];

  /// The skeleton rows have been on screen: the articles fade in over them.
  bool _waited = false;

  @override
  void dispose() {
    for (final r in _row) {
      r.dispose();
    }
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final motion = !MediaQuery.disableAnimationsOf(context);
    Widget note(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
          child: Text(text, style: const TextStyle(fontSize: 13, color: Palette.muted)),
        );
    final loading = widget.onSearch == null || c.phase != MessengerPhase.ready || (c.session?.helpBaseUrl != null && !c.articlesLoaded);
    final Widget rows;
    if (loading) {
      _waited = true;
      rows = const ArticleRowsSkeleton(key: ValueKey<String>('skeleton'));
    } else if (c.session?.helpBaseUrl == null) {
      rows = note('Help articles are not available right now.');
    } else if (c.articles.isEmpty) {
      rows = note('Help articles will appear here once published.');
    } else {
      if (_waited && motion) {
        _waited = false;
        _in.forward(from: 0);
      }
      final shown = c.articles.take(_rows).toList();
      rows = Column(
        key: const ValueKey<String>('articles'),
        children: [
          for (var i = 0; i < shown.length; i++)
            FadeTransition(
              opacity: _row[i],
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => openArticle(context, shown[i].slug, title: shown[i].title),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: articleRowHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(child: Text(shown[i].title, style: const TextStyle(fontSize: 15, height: 1.4, color: Palette.body))),
                        Icon(Icons.chevron_right, size: 18, color: brand.primary),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    }
    final onSearch = widget.onSearch;
    return MessengerCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: onSearch != null,
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
          AnimatedSize(
            duration: motion ? _fade : Duration.zero,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: rows,
          ),
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
          // Its own scrolling, not the sheet's: pulled down at the top it
          // refreshes, as it always has, rather than move the sheet.
          primary: false,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
      // The close button's 44-point touch area reaches 5 points past its
      // circle; the padding gives that back, so the circle sits where it did.
      padding: const EdgeInsets.fromLTRB(20, 7, 9, 7),
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
              onTapOutside: dismissKeyboard,
              textInputAction: TextInputAction.search,
              style: fieldText,
              cursorColor: brand.primary,
              decoration: InputDecoration(
                hintText: 'Search for help',
                hintStyle: const TextStyle(color: Palette.hint),
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
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              children: [
                if (c.phase != MessengerPhase.ready || (c.session?.helpBaseUrl != null && !c.articlesLoaded))
                  const ArticleRowsSkeleton(inset: 12)
                else if (c.session?.helpBaseUrl == null)
                  note('Help articles are not available right now.')
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
