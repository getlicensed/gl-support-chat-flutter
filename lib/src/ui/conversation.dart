import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/models.dart';
import '../api/realtime.dart';
import '../core/controller.dart';
import '../core/format.dart';
import 'common.dart';
import 'navigation.dart';

/// One conversation. Without [conversationId] it is the live one — the open
/// conversation, or a new one on the first message. With an id it is that
/// conversation as it stands: read-only, CSAT still answerable.
class ConversationPage extends StatefulWidget {
  const ConversationPage({super.key, this.conversationId});

  final String? conversationId;

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  MessengerController? _controller;
  Future<ConversationDetail>? _past;

  /// The messages on their way at the last build. One that has since gone
  /// through hands its photo to the confirmed bubble, so the picture stays
  /// put instead of flashing a spinner while its bytes are looked up.
  List<OutgoingMessage> _sending = const <OutgoingMessage>[];

  bool get _live => widget.conversationId == null;

  /// The controller's [MessengerController.resets] when this opened.
  int _resets = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final c = context.messenger;
    _controller = c;
    _resets = c.resets;
    if (_live) {
      // After this frame: the controller notifies, and the tree is building.
      WidgetsBinding.instance.addPostFrameCallback((_) => c.setViewingLive(true));
    } else {
      _past = c.loadConversation(widget.conversationId!);
    }
  }

  @override
  void dispose() {
    final c = _controller;
    final resets = _resets;
    // After this frame: the controller notifies, and the tree is being torn
    // down now (notifying here was an error on every Back from a chat). Not
    // after a reset: what is on screen then is the next customer's.
    if (_live && c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (c.resets == resets) c.setViewingLive(false);
      });
    }
    super.dispose();
  }

  void _reloadPast() {
    setState(() {
      _past = context.messenger.loadConversation(widget.conversationId!);
    });
  }

  void _handOverPhotos(MessengerController c) {
    for (final out in _sending) {
      final id = out.uploadId;
      final image = out.image;
      if (id != null && image != null && !c.outgoing.contains(out)) _photoBytes[c.fileBytes(id)] = image;
    }
    _sending = List<OutgoingMessage>.of(c.outgoing);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    // Read here, above the Scaffold: inside it the keyboard is already taken
    // out of the insets.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // A phone with the keyboard up has little room left for the thread; one
    // on its side, almost none.
    final room = MediaQuery.sizeOf(context).height - keyboard;
    final cramped = keyboard > 0 && room < 600;
    final tight = keyboard > 0 && room < 300;
    final Widget thread;
    if (_live) {
      _handOverPhotos(c);
      var mine = c.outgoing.length;
      for (final m in c.live) {
        if (m.fromVisitor) mine++;
      }
      // The first open shows Home before the open conversation is in: a
      // spinner until it is, never the opening chips flashing before it.
      thread = !c.liveLoaded && c.live.isEmpty && c.outgoing.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _Thread(rows: _liveRows(context, c), sent: mine, received: c.live.length + c.outgoing.length - mine);
    } else {
      thread = FutureBuilder<ConversationDetail>(
        future: _past,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('This conversation could not be loaded.', style: TextStyle(color: Palette.muted)),
                  TextButton(onPressed: _reloadPast, child: const Text('Try again')),
                ],
              ),
            );
          }
          final d = snap.data;
          if (d == null) return const Center(child: CircularProgressIndicator());
          return _Thread(rows: _messageRows(context, c, d.messages.where((m) => !m.isSystem).toList(), agentSeenAt: d.agentLastSeenAt));
        },
      );
    }
    return _GoneOnReset(
      controller: c,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: statusBarOnBrand(c.brand),
        child: Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            children: [
              _Header(live: _live),
              if (_live) const ConnectionBar(),
              // Side insets (a phone on its side): clear of the notch and the
              // rounded corners, as the header is. The footer never takes more
              // than the room under the header: on a phone on its side with
              // the keyboard up and a large text size, the composer gives way
              // (and scrolls inside) rather than overflow the screen.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) => Column(
                    children: [
                      Expanded(child: SafeArea(top: false, bottom: false, child: thread)),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: box.maxHeight),
                        child: SafeArea(
                          top: false,
                          bottom: false,
                          child: _live
                              ? _LiveFooter(compact: cramped, emailBar: !tight)
                              // While the CSAT comment is being typed the footer
                              // steps aside: the box and its Send need the room.
                              // Kept built, so it comes back whole, not a frame
                              // without its line.
                              : Offstage(offstage: keyboard > 0, child: _PastFooter(conversationId: widget.conversationId!, past: _past)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A screen with what the customer signed in now has (a conversation, a
/// photo). Once the controller is reset — a sign-out, or someone else
/// signing in — it goes, even from under a screen of the app's own that
/// the messenger never pops (a lock or sign-in screen): when the app pops
/// that, the next customer never lands on it.
class _GoneOnReset extends StatefulWidget {
  const _GoneOnReset({required this.controller, required this.child});
  final MessengerController controller;
  final Widget child;

  @override
  State<_GoneOnReset> createState() => _GoneOnResetState();
}

class _GoneOnResetState extends State<_GoneOnReset> {
  late final int _resets;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _resets = widget.controller.resets;
    widget.controller.addListener(_check);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_check);
    super.dispose();
  }

  void _check() {
    if (_leaving || widget.controller.resets == _resets) return;
    _leaving = true;
    // After the frame: the controller may be telling its listeners mid-build.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        final route = ModalRoute.of(context);
        if (route == null || !route.isActive) return; // already on its way out
        if (!(route.settings.name ?? '').startsWith('$messengerRoutePrefix/')) return; // never one of the app's
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      })
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ==========================================================================
// What the thread shows, top to bottom
// ==========================================================================

/// The thread's rows, each under a key of its own (the message's id, the
/// local id of one on its way), so a row keeps its state — a photo already
/// fetched — when rows are added below it, instead of taking another row's.
class _Rows {
  final list = <Widget>[];
  final _used = <String>{};

  void add(String key, Widget row) {
    // Two rows never share a key, even if the server ever sent an id twice.
    var k = key;
    for (var n = 2; !_used.add(k); n++) {
      k = '$key#$n';
    }
    list.add(KeyedSubtree(key: ValueKey<String>(k), child: row));
  }
}

List<Widget> _liveRows(BuildContext context, MessengerController c) {
  final rows = _Rows();
  final label = c.session?.productLabel ?? '';
  if (c.live.isEmpty) {
    final pendingCsat = c.pendingCsatRatingId;
    if (pendingCsat != null) {
      rows.add('csat-pending:$pendingCsat', CsatCard(
        ratingId: pendingCsat,
        title: label.isEmpty ? 'How did we do? Rate your last conversation.' : 'How did we do? Rate your last conversation with $label.',
      ));
    }
    final preview = c.preview;
    if (preview != null) {
      rows.add('preview-author', _AuthorRow(authorType: 'bot', name: label, time: c.previewShownAt ?? DateTime.now()));
      for (var i = 0; i < preview.messages.length; i++) {
        final m = preview.messages[i];
        final meta = m.meta;
        if (m.body.trim().isNotEmpty || meta?.imageUrl != null || meta?.articleSlug != null || meta?.fileUrl != null) {
          rows.add('preview:$i', _Bubble(
            message: ChatMessage(id: '', conversationId: '', body: m.body, authorType: 'bot', createdAt: DateTime.now(), meta: meta),
          ));
        }
        if (meta != null && meta.buttons.isNotEmpty) {
          rows.add('preview-buttons:$i', _FlowButtons(buttons: meta.buttons, onTap: c.startWorkflow));
        }
      }
    } else if (c.typingAuthor != null) {
      rows.add('typing', _TypingRow(author: c.typingAuthor!));
    } else {
      rows.add('intro', const _IntroAndChips());
    }
  } else {
    _messageRows(context, c, c.live, agentSeenAt: c.agentSeenAt, divider: c.dividerIndex, livePrompt: c.livePrompt, into: rows);
    final typing = c.typingAuthor;
    if (typing != null) rows.add('typing', _TypingRow(author: typing));
  }
  final notice = c.flowNotice;
  if (notice != null) rows.add('notice', _ErrorLine(notice));
  for (final out in c.outgoing) {
    rows.add('out:${out.localId}', _OutgoingBubble(out: out));
  }
  return rows.list;
}

List<Widget> _messageRows(
  BuildContext context,
  MessengerController c,
  List<ChatMessage> messages, {
  DateTime? agentSeenAt,
  int divider = -1,
  ChatMessage? livePrompt,
  _Rows? into,
}) {
  final rows = into ?? _Rows();
  final label = c.session?.productLabel ?? '';
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (i == divider) rows.add('divider', const _NewMessagesDivider());
    if (!m.fromVisitor) {
      final prev = i == 0 ? null : messages[i - 1];
      final startsGroup = prev == null || prev.fromVisitor || prev.authorType != m.authorType || prev.authorName != m.authorName;
      if (startsGroup) {
        rows.add('author:${m.id}', _AuthorRow(
          authorType: m.authorType,
          name: switch (m.authorType) {
            'bot' => label.isNotEmpty ? label : (m.authorName ?? 'Support'),
            'ai' => m.authorName ?? 'AI',
            _ => m.authorName ?? 'Support',
          },
          time: m.createdAt,
          authorId: m.authorId,
        ));
      }
    }
    final meta = m.meta;
    final bodyless = m.authorType == 'bot' && m.body.trim().isEmpty && m.attachments.isEmpty &&
        meta?.imageUrl == null && meta?.articleSlug == null && meta?.fileUrl == null;
    if (!bodyless) {
      rows.add('msg:${m.id}', _Bubble(
        message: m,
        seen: m.fromVisitor && agentSeenAt != null && !m.createdAt.isAfter(agentSeenAt),
      ));
    }
    final csat = meta?.csatRatingId;
    if (m.authorType == 'bot' && csat != null) rows.add('csat:${m.id}', CsatCard(ratingId: csat, title: 'Tap a face'));
    if (livePrompt != null && identical(m, livePrompt)) {
      if (meta!.buttons.isNotEmpty) {
        rows.add('buttons:${m.id}', _FlowButtons(buttons: meta.buttons, onTap: (b) => c.choose(m, b)));
      } else if (meta.collect != null) {
        rows.add('collect:${m.id}', _CollectBox(prompt: m, request: meta.collect!));
      }
    }
  }
  return rows.list;
}

/// The rows, newest at the bottom — and the list anchored there, so it opens
/// on the latest message.
///
/// What the customer sends always comes into view. A reply comes into view
/// only for a reader already at (or near) the latest; one reading further up
/// stays exactly where they are, with a "New message" pill that takes them
/// down. A drag or a tap on the thread puts the keyboard away.
class _Thread extends StatefulWidget {
  const _Thread({required this.rows, this.sent = 0, this.received = 0});
  final List<Widget> rows;

  /// The customer's own messages, sent or on their way.
  final int sent;

  /// Everyone else's: the team's, the AI's, the workflow's.
  final int received;

  @override
  State<_Thread> createState() => _ThreadState();
}

class _ThreadState extends State<_Thread> {
  final _scroll = ScrollController();
  late final _physics = _KeepPlace(this);

  /// The rows built right now, by key: where each is laid out.
  final _slots = <Key, _SlotState>{};

  /// A row on screen before an update, and how far it sat above the bottom
  /// of the view: for the one layout that follows.
  ({Key key, double above})? _anchor;

  /// Replies that arrived while the reader was up the thread.
  int _unseen = 0;

  /// How far from the latest still counts as reading it, in logical pixels.
  static const _near = 120.0;

  bool get _atLatest => !_scroll.hasClients || _scroll.offset <= _near;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_unseen > 0 && _scroll.offset <= _near) setState(() => _unseen = 0);
  }

  @override
  void didUpdateWidget(_Thread old) {
    super.didUpdateWidget(old);
    if (!_atLatest) _holdPlace();
    if (widget.sent > old.sent) {
      _unseen = 0;
      _toLatest();
    } else if (widget.received > old.received) {
      if (_atLatest) {
        _toLatest();
      } else {
        _unseen += widget.received - old.received;
      }
    }
  }

  /// A reader up the thread keeps their place through the update. The list
  /// is reversed: a row added below moves every other row to a new index,
  /// and the list would lay them out a little off where they were (and an
  /// answer typing out below would push them up). So: note a row on screen
  /// now, and in the layout that follows set the scroll offset so that it is
  /// where it was ([_KeepPlace]).
  void _holdPlace() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final view = _scroll.position.viewportDimension;
    ({Key key, double above})? found;
    for (final slot in _slots.values) {
      final at = slot.layoutOffset;
      if (at == null || at < pixels || at > pixels + view) continue;
      if (found == null || at - pixels < found.above) found = (key: slot.widget.key!, above: at - pixels);
    }
    if (found == null) return;
    _anchor = found;
    // For this update's layout only: a later one is the reader scrolling.
    WidgetsBinding.instance.addPostFrameCallback((_) => _anchor = null);
  }

  /// The scroll offset that keeps [_anchor] where it was, or [pixels].
  double _keptPixels(ScrollMetrics now, double pixels) {
    final anchor = _anchor;
    if (anchor == null) return pixels;
    final at = _slots[anchor.key]?.layoutOffset;
    if (at == null) return pixels;
    final kept = at - anchor.above;
    if (kept < now.minScrollExtent) return now.minScrollExtent;
    if (kept > now.maxScrollExtent) return now.maxScrollExtent;
    return kept;
  }

  /// Once the new rows are laid out: down to the latest (the list is
  /// reversed, so that is offset 0). A short way is animated; from far up
  /// it jumps, rather than scroll through the whole history.
  void _toLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final from = _scroll.offset;
      if (from <= 0) return;
      if (from > _scroll.position.viewportDimension * 2) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final n = rows.length;
    final at = <Key, int>{
      for (var i = 0; i < n; i++)
        if (rows[i].key != null) rows[i].key!: i,
    };
    final list = ListView.builder(
      controller: _scroll,
      physics: _physics,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      itemCount: n,
      itemBuilder: (_, i) {
        final row = rows[n - 1 - i];
        final key = row.key;
        return key == null ? row : _Slot(key: key, slots: _slots, child: row);
      },
      // A row added below moves the others up by one index: found by key,
      // each keeps its own state instead of being rebuilt as its neighbour.
      findChildIndexCallback: (key) {
        final i = at[key];
        return i == null ? null : n - 1 - i;
      },
    );
    // Always in the Stack, pill or not: the same tree keeps the list, and
    // with it the reader's place.
    return Stack(
      children: [
        Positioned.fill(child: list),
        if (_unseen > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: Center(
              child: _NewMessagePill(
                count: _unseen,
                onTap: () {
                  setState(() => _unseen = 0);
                  _toLatest();
                },
              ),
            ),
          ),
      ],
    );
  }
}

/// The platform's scrolling, plus one thing: right after the rows change,
/// the offset that keeps the reader's place (see [_ThreadState._holdPlace]).
/// It runs inside the layout, so the rows are never drawn shifted.
class _KeepPlace extends ScrollPhysics {
  const _KeepPlace(this.thread, {super.parent});
  final _ThreadState thread;

  @override
  _KeepPlace applyTo(ScrollPhysics? ancestor) => _KeepPlace(thread, parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final pixels = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    return thread._keptPixels(newPosition, pixels);
  }
}

/// A row of the thread, known to the thread by its key while it is built.
class _Slot extends StatefulWidget {
  const _Slot({required Key key, required this.slots, required this.child}) : super(key: key);
  final Map<Key, _SlotState> slots;
  final Widget child;

  @override
  State<_Slot> createState() => _SlotState();
}

class _SlotState extends State<_Slot> {
  @override
  void initState() {
    super.initState();
    widget.slots[widget.key!] = this;
  }

  @override
  void dispose() {
    if (identical(widget.slots[widget.key!], this)) widget.slots.remove(widget.key!);
    super.dispose();
  }

  /// Where the row is laid out along the thread (0 at the latest), or null
  /// while it is not laid out.
  double? get layoutOffset {
    RenderObject? r = context.findRenderObject();
    while (r != null) {
      final data = r.parentData;
      if (data is SliverMultiBoxAdaptorParentData) return data.layoutOffset;
      r = r.parent;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// "New message ↓" over the thread, for a reader further up.
class _NewMessagePill extends StatelessWidget {
  const _NewMessagePill({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    // Inside the text fields' tap region: going down to read a reply does
    // not put the keyboard away mid-sentence.
    return TextFieldTapRegion(
      child: Material(
        color: brand.primary,
        elevation: 3,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RoundIconButton.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    count == 1 ? 'New message' : 'New messages',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: brand.onPrimary),
                  ),
                  const SizedBox(width: 6),
                  Icon(Icons.arrow_downward, size: 16, color: brand.onPrimary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// Header and footers
// ==========================================================================

class _Header extends StatelessWidget {
  const _Header({required this.live});
  final bool live;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final s = c.session;
    // The controller knows of nobody online while it connects or reconnects
    // (agentsOnline is null then), so the line says "Active now" only once
    // the connection is up and the server has said someone is.
    final status = presenceLines(c.agentsOnline, s?.officeHours);
    final hasTeam = (s?.team ?? const []).isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [brand.primary, brand.hover]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          // Back and Close take taps 6 points past their circles (44-point
          // targets); the padding gives that back, so the circles sit where
          // they always did.
          padding: const EdgeInsets.fromLTRB(6, 5, 8, 7),
          child: Row(
            children: [
              RoundIconButton(icon: Icons.chevron_left, tooltip: 'Back', light: true, size: 32, onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 4),
              // The faces the admin chose (or none): then the chatbot's logo.
              if (hasTeam) const TeamFaces(size: 30, border: 1.5) else LogoAvatar(label: s?.productLabel ?? '?', size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (s?.productLabel ?? '').isEmpty ? 'Support' : s!.productLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: brand.onPrimary),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (live) ...[
                          Container(
                            width: 6,
                            height: 6,
                            // Green only while connected: before, nobody sees the customer typing.
                            decoration: BoxDecoration(color: status.away || !c.connected ? Palette.away : const Color(0xFF4ADE80), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            live ? status.header : 'Conversation history',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            // Full strength: faded, it fell under 4.5:1 on most brand colours.
                            style: TextStyle(fontSize: 12, color: brand.onPrimary),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              RoundIconButton(icon: Icons.close, tooltip: 'Close', light: true, size: 32, onTap: () => closeMessenger(context)),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveFooter extends StatelessWidget {
  const _LiveFooter({this.compact = false, this.emailBar = true});

  /// The keyboard is up on a phone: the "leave your email" form is one line.
  final bool compact;

  /// False when even that line would not fit (a phone on its side, typing):
  /// the form is there again once the keyboard goes down.
  final bool emailBar;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final sendError = c.sendError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.showEmailBar && emailBar) _EmailBar(compact: compact),
        if (sendError != null && c.outgoing.isEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: _ErrorLine(sendError)),
        // Flexible: in the little room of a phone on its side it is the
        // composer that gives way.
        const Flexible(child: _Composer()),
      ],
    );
  }
}

class _PastFooter extends StatelessWidget {
  const _PastFooter({required this.conversationId, required this.past});
  final String conversationId;
  final Future<ConversationDetail>? past;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return FutureBuilder<ConversationDetail>(
      future: past,
      builder: (context, snap) {
        final closed = snap.data?.open == false;
        return Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.of(context).padding.bottom),
          decoration: const BoxDecoration(color: Palette.input, border: Border(top: BorderSide(color: Palette.border))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (closed)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('This conversation has ended', style: TextStyle(fontSize: 13, color: Palette.muted)),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: brand.primary, foregroundColor: brand.onPrimary, shape: const StadiumBorder()),
                onPressed: () => replaceWithLiveConversation(context),
                icon: const Icon(Icons.send, size: 16),
                label: const Text('Send us a message'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==========================================================================
// Messages
// ==========================================================================

String _clock(BuildContext context, DateTime t) {
  final loc = MaterialLocalizations.of(context);
  final time = loc.formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat);
  final now = DateTime.now();
  final today = t.year == now.year && t.month == now.month && t.day == now.day;
  return today ? time : '${loc.formatShortMonthDay(t)} $time';
}

/// A teammate's photo, by their user id: the path is only built from a
/// well-formed id. Null without one.
String? _teammatePhoto(String? userId) =>
    userId != null && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(userId) ? '/widget/avatar/$userId' : null;

class _AuthorRow extends StatelessWidget {
  const _AuthorRow({required this.authorType, required this.name, required this.time, this.authorId});

  final String authorType;
  final String name;
  final DateTime time;
  final String? authorId;

  @override
  Widget build(BuildContext context) {
    final Widget avatar;
    if (authorType == 'ai') {
      avatar = InitialAvatar(label: name, size: 22, icon: Icons.smart_toy_outlined);
    } else if (authorType == 'bot') {
      // The workflow speaks as the chatbot: its logo, as Intercom shows the brand beside the bot.
      avatar = LogoAvatar(label: name, size: 22);
    } else if (authorType == 'agent' && _teammatePhoto(authorId) != null) {
      avatar = PersonAvatar(name: name, photoPath: _teammatePhoto(authorId), size: 22);
    } else {
      avatar = InitialAvatar(label: name, size: 22);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4, left: 2),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '$name · ${_clock(context, time)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text with its links tappable (never HTML).
///
/// A link is a run of the same paragraph with a tap recogniser, not a widget
/// set into it: it wraps with the sentence, and the phone's text size is
/// applied once (a widget inside was scaled twice, and broke the line).
class _RichText extends StatefulWidget {
  const _RichText(this.text, {required this.color, required this.linkColor});
  final String text;
  final Color color;
  final Color linkColor;

  @override
  State<_RichText> createState() => _RichTextState();
}

class _RichTextState extends State<_RichText> {
  /// One per link in the text; made again when the text changes (an AI
  /// answer typing out), and every one disposed.
  final _taps = <TapGestureRecognizer>[];
  List<InlineSpan> _spans = const <InlineSpan>[];

  @override
  void initState() {
    super.initState();
    _spans = _build();
  }

  @override
  void didUpdateWidget(_RichText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || old.linkColor != widget.linkColor) _spans = _build();
  }

  @override
  void dispose() {
    _forget();
    super.dispose();
  }

  void _forget() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  List<InlineSpan> _build() {
    _forget();
    final link = TextStyle(color: widget.linkColor, decoration: TextDecoration.underline, decorationColor: widget.linkColor);
    final spans = <InlineSpan>[];
    for (final r in linkify(widget.text)) {
      // A link the URL parser refuses (an unfilled placeholder such as
      // "https://[booking-link]") stays plain text. Parsed while building,
      // it threw and hid the whole message behind an error box.
      final url = r.isLink ? Uri.tryParse(r.url!) : null;
      spans.add(url == null ? TextSpan(text: r.text) : TextSpan(text: r.text, style: link, recognizer: _tap(url)));
    }
    return spans;
  }

  TapGestureRecognizer _tap(Uri url) {
    final t = TapGestureRecognizer()..onTap = () => openExternal(context, url);
    _taps.add(t);
    return t;
  }

  @override
  Widget build(BuildContext context) {
    return Text.rich(TextSpan(style: TextStyle(fontSize: 15, height: 1.45, color: widget.color), children: _spans));
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.seen = false});

  final ChatMessage message;
  final bool seen;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final m = message;
    final mine = m.fromVisitor;
    // A file alone is stored as "[Photo]" / "[Document]" for the inbox — the customer's or, since
    // 6 Oct, the team's; under the file itself only the words are shown.
    final text = bodyBesideFiles(m).trim();
    final meta = m.meta;
    final bot = m.authorType == 'bot';
    final fg = mine ? brand.onPrimary : Palette.text;
    final children = <Widget>[
      if (bot && meta?.imageUrl != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(meta!.imageUrl!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          ),
        ),
      for (final a in m.attachments) Padding(padding: const EdgeInsets.only(bottom: 6), child: _AttachmentView(attachment: a, mine: mine)),
      if (text.isNotEmpty) _RichText(text, color: fg, linkColor: mine ? fg : brand.primary),
      if (bot && meta?.articleSlug != null && context.messenger.session?.helpBaseUrl != null)
        _InBubbleCard(
          icon: Icons.description_outlined,
          title: meta!.articleTitle ?? 'Help article',
          hint: 'Read article',
          onTap: () => openArticle(context, meta.articleSlug!, title: meta.articleTitle ?? 'Help article'),
        ),
      if (bot && meta?.fileUrl != null)
        _InBubbleCard(
          icon: Icons.attach_file,
          title: meta!.fileName ?? 'File',
          onTap: () => openExternal(context, Uri.parse(meta.fileUrl!)),
        ),
    ];
    final onlyMedia = text.isEmpty && m.attachments.isNotEmpty && m.attachments.every((a) => a.isImage);
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
      padding: onlyMedia ? const EdgeInsets.all(3) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? brand.primary : Palette.agentBubble,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: text.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
                  },
            child: bubble,
          ),
          if (mine)
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_clock(context, m.createdAt), style: const TextStyle(fontSize: 11, color: Palette.muted)),
                  const SizedBox(width: 4),
                  // ✓ delivered, ✓✓ the team has read it.
                  Icon(seen ? Icons.done_all : Icons.done, size: 14, color: seen ? Palette.body : Palette.muted, semanticLabel: seen ? 'Seen' : 'Delivered'),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _InBubbleCard extends StatelessWidget {
  const _InBubbleCard({required this.icon, required this.title, required this.onTap, this.hint});
  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: Palette.input,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Palette.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RoundIconButton.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: Palette.body),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Palette.text)),
                        if (hint != null) Text(hint!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: context.brand.primary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bytes behind each photo lookup once they are known, held only as long
/// as the lookup itself (the controller's): a row built again shows its
/// photo at once, never a spinner first.
final _photoBytes = Expando<Uint8List>('photo bytes');

/// A photo or file on a message. The customer's own photos are read with
/// their token (they have no public address); https files open outside.
class _AttachmentView extends StatelessWidget {
  const _AttachmentView({required this.attachment, required this.mine});
  final Attachment attachment;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final uploadId = a.uploadId;
    if (a.isImage && uploadId != null) {
      final lookup = context.messenger.fileBytes(uploadId);
      return FutureBuilder<Uint8List>(
        future: lookup,
        initialData: _photoBytes[lookup],
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null && bytes.isNotEmpty) {
            _photoBytes[lookup] = bytes;
            return _Photo(image: MemoryImage(bytes));
          }
          if (snap.hasError) return _FileChip(name: a.name, mine: mine);
          return const SizedBox(width: 200, height: 150, child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        },
      );
    }
    if (a.isImage && a.url.startsWith('https://')) return _Photo(image: NetworkImage(a.url));
    return _FileChip(
      name: a.name,
      mine: mine,
      onTap: a.url.startsWith('https://') ? () => openExternal(context, Uri.parse(a.url)) : null,
    );
  }
}

class _Photo extends StatelessWidget {
  const _Photo({required this.image});
  final ImageProvider image;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final scope = context.getInheritedWidgetOfExactType<MessengerScope>();
        showDialog<void>(
          context: context,
          // Named as the messenger's: closed with it, and with a sign-out.
          routeSettings: const RouteSettings(name: '$messengerRoutePrefix/photo'),
          builder: (_) {
            final viewer = GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(child: Image(image: image)),
            );
            return scope == null ? viewer : _GoneOnReset(controller: scope.controller, child: viewer);
          },
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260, minWidth: 120),
          child: Image(image: image, fit: BoxFit.cover),
        ),
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.name, required this.mine, this.onTap});
  final String name;
  final bool mine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fg = mine ? context.brand.onPrimary : Palette.text;
    return InkWell(
      onTap: onTap,
      // At least 44 points tall: the way to open a letter the team sends.
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: RoundIconButton.minTarget),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.attach_file, size: 16, color: fg),
              const SizedBox(width: 4),
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: fg))),
            ],
          ),
        ),
      ),
    );
  }
}

/// A message on its way, or one the server refused.
class _OutgoingBubble extends StatelessWidget {
  const _OutgoingBubble({required this.out});
  final OutgoingMessage out;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final image = out.image;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Opacity(
            opacity: out.failed ? 0.55 : 0.75,
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
              padding: image != null && out.text.isEmpty ? const EdgeInsets.all(3) : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: brand.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (image != null) _Photo(image: MemoryImage(image)),
                  if (out.text.isNotEmpty) Text(out.text, style: TextStyle(fontSize: 15, height: 1.45, color: brand.onPrimary)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 3),
          if (!out.failed)
            const Text('Sending…', style: TextStyle(fontSize: 11, color: Palette.muted))
          else
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.end,
              children: [
                Text(out.error!, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, color: Palette.error)),
                TextButton(onPressed: () => c.retry(out), child: const Text('Try again')),
                TextButton(onPressed: () => c.discard(out), child: const Text('Delete', style: TextStyle(color: Palette.muted))),
              ],
            ),
        ],
      ),
    );
  }
}

class _NewMessagesDivider extends StatelessWidget {
  const _NewMessagesDivider();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(child: Divider(color: Color(0xFFFCA5A5))),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text('New messages', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Palette.danger)),
          ),
          Expanded(child: Divider(color: Color(0xFFFCA5A5))),
        ],
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(fontSize: 12, color: Palette.error)),
      );
}

/// The dots, beside whoever is typing: the teammate's photo (their initial
/// without one), the chatbot's circle for the workflow, and a plain person
/// from a server that does not say who.
class _TypingRow extends StatefulWidget {
  const _TypingRow({required this.author});
  final TypingAuthor author;

  @override
  State<_TypingRow> createState() => _TypingRowState();
}

class _TypingRowState extends State<_TypingRow> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  double _lift(double t) {
    // 0 → 30% up, 30% → 60% down, then still: the web messenger's bounce.
    if (t < 0.3) return t / 0.3;
    if (t < 0.6) return 1 - (t - 0.3) / 0.3;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final who = widget.author;
    final name = who.name;
    final Widget face;
    if (who.isBot) {
      face = LogoAvatar(label: context.messenger.session?.productLabel ?? '', size: 22);
    } else if (who.id != null) {
      // The photo their replies show; their initial when they have none.
      face = PersonAvatar(name: name ?? '', photoPath: _teammatePhoto(who.id), size: 22);
    } else {
      face = const InitialAvatar(label: '', size: 22, icon: Icons.person_outline);
    }
    return Semantics(
      label: name == null || who.isBot ? 'Typing' : '$name is typing',
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Row(
          children: [
            // The label says who: the initial would only repeat it.
            ExcludeSemantics(child: face),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              decoration: const BoxDecoration(
                color: Palette.agentBubble,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                ),
              ),
              child: AnimatedBuilder(
                animation: _anim,
                builder: (_, __) => Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Builder(builder: (_) {
                        final lift = _lift((_anim.value - i * 0.125) % 1.0);
                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Transform.translate(
                            offset: Offset(0, -4 * lift),
                            child: Opacity(
                              opacity: 0.4 + 0.6 * lift,
                              child: Container(width: 6, height: 6, decoration: const BoxDecoration(color: Palette.faint, shape: BoxShape.circle)),
                            ),
                          ),
                        );
                      }),
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

// ==========================================================================
// Before the first message: intro and chips
// ==========================================================================

class _IntroAndChips extends StatelessWidget {
  const _IntroAndChips();

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final chips = c.chips;
    final s = c.session;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 12),
            child: Text(
              chips.isEmpty ? 'Ask us anything' : 'Ask a question, or pick one to get started',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Palette.muted),
            ),
          ),
        ),
        for (final q in chips)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _Chip(
              label: q.text,
              whatsapp: q.action == 'whatsapp',
              onTap: () {
                if (q.action == 'whatsapp') {
                  final link = whatsappChipLink(number: s?.whatsappNumber, template: q.whatsappText, productLabel: s?.productLabel ?? '');
                  if (link != null) openExternal(context, link);
                } else if (q.articleSlug != null && s?.helpBaseUrl != null) {
                  openArticle(context, q.articleSlug!, title: q.text);
                } else {
                  c.send(q.text);
                }
              },
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap, this.whatsapp = false, this.enabled = true});
  final String label;
  final VoidCallback onTap;
  final bool whatsapp;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final fg = whatsapp ? Palette.whatsappText : brand.primary;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: whatsapp ? Colors.white : brand.light,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: whatsapp ? Palette.whatsapp : brand.ring),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          customBorder: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
          // At least 44 points tall: a chip is the thing most often tapped.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: RoundIconButton.minTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (whatsapp) ...[
                    Container(width: 8, height: 8, decoration: const BoxDecoration(color: Palette.whatsapp, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                  ],
                  Flexible(child: Text(label, textAlign: TextAlign.end, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: fg))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================================================
// Workflow: buttons and a detail to collect
// ==========================================================================

class _FlowButtons extends StatelessWidget {
  const _FlowButtons({required this.buttons, required this.onTap});
  final List<FlowButton> buttons;
  final void Function(FlowButton) onTap;

  @override
  Widget build(BuildContext context) {
    final busy = context.messenger.flowBusy;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final b in buttons)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _Chip(label: b.label, enabled: !busy, onTap: () => onTap(b)),
            ),
        ],
      ),
    );
  }
}

class _CollectBox extends StatefulWidget {
  const _CollectBox({required this.prompt, required this.request});
  final ChatMessage prompt;
  final CollectRequest request;

  @override
  State<_CollectBox> createState() => _CollectBoxState();
}

class _CollectBoxState extends State<_CollectBox> {
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final ok = await context.messenger.collect(widget.prompt, _value.text);
    if (ok && mounted) _value.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final type = widget.request.inputType;
    final error = c.collectError;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Its Send is inside the field's tap region: tapping it does not
          // drop the keyboard before the answer goes.
          TextFieldTapRegion(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _value,
                    enabled: !c.flowBusy,
                    maxLength: 200,
                    onTapOutside: dismissKeyboard,
                    style: fieldText,
                    cursorColor: brand.primary,
                    keyboardType: type == 'email' ? TextInputType.emailAddress : (type == 'tel' ? TextInputType.phone : TextInputType.text),
                    autofillHints: type == 'email'
                        ? const [AutofillHints.email]
                        : type == 'tel'
                            ? const [AutofillHints.telephoneNumber]
                            : (widget.request.field == 'name' ? const [AutofillHints.name] : null),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      counterText: '',
                      isDense: true,
                      labelText: widget.request.label.isEmpty ? null : widget.request.label,
                      hintText: type == 'email' ? 'name@example.com' : (type == 'tel' ? '07700 900123' : 'Type your answer…'),
                      hintStyle: const TextStyle(color: Palette.hint),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: brand.primary, width: 1.5)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: brand.primary, foregroundColor: brand.onPrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                  onPressed: c.flowBusy ? null : _submit,
                  child: const Text('Send'),
                ),
              ],
            ),
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 4, left: 2), child: Text(error, style: const TextStyle(fontSize: 12, color: Palette.error))),
        ],
      ),
    );
  }
}

// ==========================================================================
// CSAT: the five faces, then a comment
// ==========================================================================

class CsatCard extends StatefulWidget {
  const CsatCard({super.key, required this.ratingId, required this.title});
  final String ratingId;
  final String title;

  @override
  State<CsatCard> createState() => _CsatCardState();
}

class _CsatCardState extends State<CsatCard> {
  final _comment = TextEditingController();

  static const _faces = <(int, String, String)>[
    (1, '😠', 'Terrible'),
    (2, '🙁', 'Bad'),
    (3, '😐', 'OK'),
    (4, '😃', 'Great'),
    (5, '🤩', 'Amazing'),
  ];

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final answer = c.csat[widget.ratingId];
    final rating = answer?.rating;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: Palette.border)),
      child: Column(
        children: [
          Text(
            rating == null ? widget.title : 'Thank you for your feedback',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Palette.text),
          ),
          const SizedBox(height: 10),
          Semantics(
            label: 'Your rating',
            child: Row(
              children: [
                // Five equal shares of the card, so a large text size never
                // squeezes one; a label that still does not fit shrinks
                // rather than break mid-word ("Terri-ble").
                for (final (value, emoji, label) in _faces)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => c.rate(widget.ratingId, value),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          decoration: BoxDecoration(
                            color: rating == value ? brand.light : null,
                            border: Border.all(color: rating == value ? brand.primary : Colors.transparent),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              Opacity(
                                opacity: rating == null || rating == value ? 1 : 0.35,
                                child: FittedBox(fit: BoxFit.scaleDown, child: Text(emoji, style: const TextStyle(fontSize: 26))),
                              ),
                              const SizedBox(height: 2),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(label, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 11, color: Palette.muted)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (rating != null && answer!.commentState != 'sent') ...[
            const SizedBox(height: 10),
            TextField(
              controller: _comment,
              minLines: 2,
              maxLines: 4,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
              onTapOutside: dismissKeyboard,
              style: fieldText,
              cursorColor: brand.primary,
              decoration: InputDecoration(
                hintText: 'Anything you would like to add? (optional)',
                hintStyle: const TextStyle(color: Palette.hint),
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: brand.primary, width: 1.5)),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              // Inside the field's tap region: Send is not lost to the
              // keyboard going down under the finger.
              child: TextFieldTapRegion(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: brand.primary, foregroundColor: brand.onPrimary),
                  onPressed: answer.commentState == 'sending' || _comment.text.trim().isEmpty ? null : () => c.comment(widget.ratingId, _comment.text),
                  child: const Text('Send'),
                ),
              ),
            ),
          ],
          if (rating != null && answer!.commentState == 'sent')
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                answer.comment.isEmpty ? 'We read every one.' : '“${answer.comment}” — thank you, we read every one.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Palette.muted),
              ),
            ),
          if (answer?.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: _ErrorLine(answer!.error!)),
        ],
      ),
    );
  }
}

// ==========================================================================
// "Leave your email" while nobody is online
// ==========================================================================

class _EmailBar extends StatefulWidget {
  const _EmailBar({this.compact = false});

  /// The keyboard is up on a phone: one slim line instead of the form, which
  /// otherwise took most of the thread. A tap on the line opens the form.
  final bool compact;

  @override
  State<_EmailBar> createState() => _EmailBarState();
}

class _EmailBarState extends State<_EmailBar> {
  final _email = TextEditingController();
  final _focus = FocusNode();
  bool _saving = false;
  String? _error;

  /// Opened from the slim line; closes again when its field lets go of the
  /// keyboard (the customer went back to their message).
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _email.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!mounted) return;
    setState(() {
      if (!_focus.hasFocus) _open = false;
    });
  }

  void _openForm() {
    setState(() => _open = true);
    // Once the field is on screen: the keyboard moves to it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Widget _slimLine(BrandColors brand) {
    return Semantics(
      button: true,
      label: 'Leave your email for a reply',
      excludeSemantics: true,
      // Inside the text fields' tap region: the keyboard passes from the
      // message to the email without going down and up again.
      child: TextFieldTapRegion(
        child: Material(
          color: Palette.input,
          child: InkWell(
            onTap: _openForm,
            child: Container(
              constraints: const BoxConstraints(minHeight: RoundIconButton.minTarget),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Palette.border))),
              child: Row(
                children: [
                  const Icon(Icons.mail_outline, size: 16, color: Palette.muted),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      "We're away — leave your email for a reply",
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: Palette.muted),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('Add email', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: brand.primary)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await context.messenger.leaveEmail(_email.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final saved = c.emailSavedFor;
    if (saved == null && widget.compact && !_open && !_focus.hasFocus) return _slimLine(brand);
    final away = awayParagraph(c.session?.officeHours);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(color: Palette.input, border: Border(top: BorderSide(color: Palette.border))),
      child: saved != null
          ? Text("We'll follow up at $saved",
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Palette.success))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (away.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(away, style: const TextStyle(fontSize: 13, height: 1.45, color: Palette.muted)),
                  ),
                // Save is inside the field's tap region: tapping it does not
                // drop the keyboard before the email goes.
                TextFieldTapRegion(
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _email,
                          focusNode: _focus,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _save(),
                          onTapOutside: dismissKeyboard,
                          style: fieldText,
                          cursorColor: brand.primary,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Your email for follow-up',
                            hintStyle: const TextStyle(color: Palette.hint),
                            filled: true,
                            fillColor: Colors.white,
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: brand.primary)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: brand.primary, foregroundColor: brand.onPrimary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                        onPressed: _saving ? null : _save,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: _ErrorLine(_error!)),
              ],
            ),
    );
  }
}

// ==========================================================================
// Composer
// ==========================================================================

class _Composer extends StatefulWidget {
  const _Composer();

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    // What the customer typed and did not send before closing the messenger
    // is there again. The controller keeps it only for them: a sign-out, or
    // someone else signing in, empties it.
    _text.text = context.getInheritedWidgetOfExactType<MessengerScope>()?.controller.draft ?? '';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    final c = context.messenger;
    final value = _text.text;
    if (value.trim().isEmpty) return;
    _text.clear();
    setState(() {});
    c.composerChanged(''); // what it sends was the draft
    c.send(value);
  }

  Future<void> _attach() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      // Named as the messenger's: closed with it.
      routeSettings: const RouteSettings(name: '$messengerRoutePrefix/photo-source'),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Photo library'),
              onTap: () => Navigator.of(sheet).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.of(sheet).pop(ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    XFile? picked;
    try {
      // Resized and re-encoded on the phone: well under the 10 MB limit, and
      // an iPhone's HEIC arrives as a JPEG every browser in the inbox can show.
      picked = await ImagePicker().pickImage(source: source, maxWidth: 2048, maxHeight: 2048, imageQuality: 85);
    } catch (_) {
      picked = null;
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Photos are not available — allow access in Settings and try again.')),
        );
      }
    }
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    unawaited(context.messenger.send('', image: bytes, imageName: picked.name, imageType: _imageType(picked)));
  }

  static String _imageType(XFile f) {
    final mime = f.mimeType;
    if (mime != null && mime.startsWith('image/')) return mime;
    final name = f.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    return 'image/jpeg';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final lock = c.composerLock;
    // Waiting on a button or a detail above: no composer at all, as in
    // Intercom — it comes back the moment typing is allowed.
    if (lock != null) return SizedBox(height: MediaQuery.of(context).padding.bottom);
    // Not tied to the connection: the controller takes a message while it
    // connects and sends it once it can, so the customer is never left
    // looking at a grey Send button.
    final canSend = _text.text.trim().isNotEmpty;
    // The photo and Send buttons belong to the field's tap region: tapping
    // them keeps the keyboard up, as in any chat app. A tap anywhere else —
    // the thread, the header — puts it away.
    return TextFieldTapRegion(
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 8, 10, 8 + MediaQuery.of(context).padding.bottom),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Palette.border))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Send a photo',
              onPressed: _attach,
              icon: const Icon(Icons.add_photo_alternate_outlined, color: Palette.muted),
            ),
            Expanded(
              child: TextField(
                controller: _text,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                onChanged: (v) {
                  setState(() {});
                  c.composerChanged(v);
                },
                onTapOutside: dismissKeyboard,
                style: fieldText,
                cursorColor: brand.primary,
                decoration: InputDecoration(
                  hintText: 'Type a message…',
                  // One line at any text size: a hint that wrapped held the
                  // box two lines tall for one line of text.
                  hintMaxLines: 1,
                  hintStyle: const TextStyle(color: Palette.hint),
                  isDense: true,
                  filled: true,
                  fillColor: Palette.input,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Palette.border)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Palette.border)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: brand.primary)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: 'Send',
              child: Material(
                color: canSend ? brand.primary : Palette.fill,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: canSend ? _send : null,
                  child: SizedBox(
                    width: RoundIconButton.minTarget,
                    height: RoundIconButton.minTarget,
                    child: Icon(Icons.arrow_upward, color: canSend ? brand.onPrimary : Palette.faint),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
