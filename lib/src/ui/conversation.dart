import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/physics.dart';
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

  /// The rows as last built: one whose message has not changed is the same
  /// widget again, which Flutter does not rebuild.
  final _cache = _RowCache();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final c = MessengerScope.read(context);
    _controller = c;
    _resets = c.resets;
    if (_live) {
      // What came in before this opened is simply there, not faded in.
      c.settleArrivals();
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
      _past = MessengerScope.read(context).loadConversation(widget.conversationId!);
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

  /// The live thread, built again whenever the controller changes: the
  /// rows come from [_cache], so only those whose message changed are built.
  Widget _liveThread(BuildContext context, MessengerController c) {
    _handOverPhotos(c);
    // What came in live is drawn this frame, faded in. After it, it is no
    // longer arriving: a rebuild, or a scroll back to it, shows it as it is.
    final drawn = c.arriving;
    if (drawn.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => c.settleArrivals(drawn));
    var mine = c.outgoing.length;
    for (final m in c.live) {
      if (m.fromVisitor) mine++;
    }
    // The first open shows Home before the open conversation is in: the
    // thread's skeleton until it is, never the opening chips flashing
    // before it; then the thread fades in over it.
    return _FadeSwitch(
      child: !c.liveLoaded && c.live.isEmpty && c.outgoing.isEmpty
          ? const ThreadSkeleton(key: ValueKey<String>('loading'))
          : _Thread(
              key: const ValueKey<String>('thread'),
              rows: _liveRows(context, c, _cache),
              sent: mine,
              received: c.live.length + c.outgoing.length - mine,
              // With less motion asked for too, as Intercom's: see [fullTime].
              glide: drawn.isNotEmpty,
            ),
    );
  }

  Widget _pastThread(BuildContext context, MessengerController c) {
    final id = widget.conversationId!;
    return FutureBuilder<ConversationDetail>(
      future: _past,
      // Opened before: what it said then, at once, while it refreshes.
      initialData: c.cachedConversation(id),
      builder: (context, snap) {
        final d = snap.data ?? c.cachedConversation(id);
        final Widget shown;
        if (d != null) {
          // The rows know the chatbot's name and colour: built again if those change.
          shown = MessengerSelector<(String, MessengerSession?)>(
            key: const ValueKey<String>('thread'),
            select: (c) => (c.brand.hex, c.session),
            builder: (context, _) => _Thread(rows: _messageRows(context, c, d.messages.where((m) => !m.isSystem).toList(), _cache, agentSeenAt: d.agentLastSeenAt)),
          );
        } else if (snap.hasError) {
          shown = Center(
            key: const ValueKey<String>('error'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This conversation could not be loaded.', style: TextStyle(color: Palette.muted)),
                TextButton(onPressed: _reloadPast, child: const Text('Try again')),
              ],
            ),
          );
        } else {
          shown = const ThreadSkeleton(key: ValueKey<String>('loading'));
        }
        return _FadeSwitch(child: shown);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Read, not watched: the page is not built again when the controller
    // changes, nor when the keyboard moves. The thread listens below; the
    // header, the footer and the composer each for what they show; only the
    // footer is told about the keyboard ([_KeyboardRoom]).
    final c = MessengerScope.read(context);
    final Widget thread = _live ? ListenableBuilder(listenable: c, builder: (context, _) => _liveThread(context, c)) : _pastThread(context, c);
    return _GoneOnReset(
      controller: c,
      child: _KeyboardRoom(
        child: MessengerSelector<String>(
          select: (c) => c.brand.hex,
          builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
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
                                  ? const _LiveFooter()
                                  : _PastFooter(conversationId: widget.conversationId!, past: _past, cached: c.cachedConversation(widget.conversationId!)),
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
        ),
      ),
    );
  }
}

/// How much room the keyboard leaves, for the footer alone. Read above the
/// Scaffold (inside it the keyboard is already taken out of the insets) by
/// this one small widget, which is built again on every frame the keyboard
/// moves; what is below it is not, and the footer only when one of these
/// changes — not the thread, whose rows read the screen's size alone.
class _KeyboardRoom extends StatelessWidget {
  const _KeyboardRoom({required this.child});
  final Widget child;

  static _Room of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_Room>()!;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // A phone with the keyboard up has little room left for the thread; one
    // on its side, almost none.
    final room = MediaQuery.sizeOf(context).height - keyboard;
    return _Room(up: keyboard > 0, cramped: keyboard > 0 && room < 600, tight: keyboard > 0 && room < 300, child: child);
  }
}

class _Room extends InheritedWidget {
  const _Room({required this.up, required this.cramped, required this.tight, required super.child});

  /// The keyboard is up.
  final bool up;

  /// Up, on a phone: the "leave your email" form is one line.
  final bool cramped;

  /// Up, on a phone on its side: not even that line fits.
  final bool tight;

  @override
  bool updateShouldNotify(_Room old) => up != old.up || cramped != old.cramped || tight != old.tight;
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

/// The thread's rows as last built, by key, and what each was built from.
/// A row whose message has not changed since is the very same widget, which
/// Flutter does not build again: a typing tick, a seen receipt or a word of
/// an AI answer rebuilds the rows it changes, not every row on screen.
/// Everything is built again when the chatbot's colour or session changes.
class _RowCache {
  var _rows = <String, ({Object? from, Widget row})>{};
  var _next = <String, ({Object? from, Widget row})>{};
  Object? _look;

  /// Starts a pass over the rows; those not asked for in it are let go.
  void begin(MessengerController c) {
    final look = (c.brand.hex, c.session);
    if (look != _look) {
      _look = look;
      _rows = <String, ({Object? from, Widget row})>{};
    }
    _next = <String, ({Object? from, Widget row})>{};
  }

  void end() {
    _rows = _next;
  }

  Widget row(String key, Object? from, Widget Function() build) {
    final had = _rows[key];
    final row = had != null && had.from == from ? had.row : build();
    _next[key] = (from: from, row: row);
    return row;
  }
}

/// The thread's rows, each under a key of its own (the message's id, the
/// local id of one on its way), so a row keeps its state — a photo already
/// fetched — when rows are added below it, instead of taking another row's.
class _Rows {
  _Rows(this.cache);
  final _RowCache cache;
  final list = <Widget>[];
  final _used = <String>{};

  /// [message]: the row is that message's (a [ChatMessage] or an
  /// [OutgoingMessage]); it fades in if the message came in live and has
  /// not been drawn yet — with less motion asked for too, as Intercom's
  /// does (see [fullTime]). [from]: what the row shows, compared with what
  /// it showed last time to tell whether it is built again.
  void add(String key, Object? from, Widget Function() row, {Object? message}) {
    // Two rows never share a key, even if the server ever sent an id twice.
    var k = key;
    for (var n = 2; !_used.add(k); n++) {
      k = '$key#$n';
    }
    // The first of a message's rows: a reply's takes the typing dots' place.
    final lead = message != null && !identical(message, _last);
    _last = message;
    // Every row is wrapped the same way, arriving or not: the row keeps its
    // place in the tree, and its state, from one build to the next.
    list.add(cache.row(k, (from, message, lead), () => KeyedSubtree(key: ValueKey<String>(k), child: _Entrance(message: message, lead: lead, child: row()))));
  }

  Object? _last;
}

/// Messages from the same author, each within five minutes of the one
/// before, are a group: their bubbles 4 points apart with tight corners
/// where they meet, the team's name, time and face once, at the last of
/// them. Groups are 16 points apart.
const _groupGap = 16.0;
const _inGroupGap = 4.0;
const _groupWithin = Duration(minutes: 5);

/// The column the team's faces sit in, beside their bubbles and the typing
/// dots alike: 28 points and a gap of 8.
const _faceSize = 28.0;
const _faceColumn = _faceSize + 8;

/// Where a bubble sits in its group.
enum _Pos { single, top, middle, bottom }

extension on _Pos {
  bool get starts => this == _Pos.single || this == _Pos.top;
  bool get ends => this == _Pos.single || this == _Pos.bottom;
}

/// The room above a bubble's row: none at the top of the thread.
double _gapAbove(_Pos pos, bool first) => first ? 0 : (pos.starts ? _groupGap : _inGroupGap);

/// The thread's bubbles in order, and whatever comes between them, put into
/// groups before they become rows: a bubble's corners, room and lines depend
/// on the bubbles either side of it.
class _Run {
  _Run(this.rows);
  final _Rows rows;
  final _parts = <({String? who, DateTime? at, bool mine, bool breaks, void Function(_Pos pos, bool status, bool first) add})>[];

  /// A bubble by [who] at [at]. [add] makes its row once its place is
  /// known; [mine]: the customer's, whose last one says whether it was seen.
  void bubble(String who, DateTime at, void Function(_Pos pos, bool status, bool first) add, {bool mine = false}) =>
      _parts.add((who: who, at: at, mine: mine, breaks: false, add: add));

  /// A row between bubbles: a divider, a CSAT card, buttons. One that
  /// [breaks] ends the group above it.
  void between(void Function() add, {bool breaks = true}) =>
      _parts.add((who: null, at: null, mine: false, breaks: breaks, add: (_, __, ___) => add()));

  void flush() {
    final parts = _parts;
    var lastMine = -1;
    for (var k = 0; k < parts.length; k++) {
      if (parts[k].mine) lastMine = k;
    }
    // The bubble each one joins on to, above and below: the nearest
    // bubble, with nothing that breaks the group between.
    int? near(int k, int step) {
      for (var j = k + step; j >= 0 && j < parts.length; j += step) {
        if (parts[j].who != null) return j;
        if (parts[j].breaks) return null;
      }
      return null;
    }

    bool joins(int? a, int? b) {
      if (a == null || b == null) return false;
      final x = parts[a];
      final y = parts[b];
      return x.who == y.who && y.at!.difference(x.at!).abs() <= _groupWithin;
    }

    for (var k = 0; k < parts.length; k++) {
      final p = parts[k];
      if (p.who == null) {
        p.add(_Pos.single, false, false);
        continue;
      }
      final starts = !joins(near(k, -1), k);
      final ends = !joins(k, near(k, 1));
      final pos = starts ? (ends ? _Pos.single : _Pos.top) : (ends ? _Pos.bottom : _Pos.middle);
      p.add(pos, k == lastMine, rows.list.isEmpty);
    }
    _parts.clear();
  }
}

/// The name a teammate, the AI or the workflow goes by in the thread.
String _authorName(ChatMessage m, String productLabel) => switch (m.authorType) {
      'bot' => productLabel.isNotEmpty ? productLabel : (m.authorName ?? 'Support'),
      'ai' => m.authorName ?? 'AI',
      _ => m.authorName ?? 'Support',
    };

List<Widget> _liveRows(BuildContext context, MessengerController c, _RowCache cache) {
  cache.begin(c);
  final rows = _Rows(cache);
  final run = _Run(rows);
  final label = c.session?.productLabel ?? '';
  if (c.live.isEmpty) {
    final pendingCsat = c.pendingCsatRatingId;
    if (pendingCsat != null) {
      final title = label.isEmpty ? 'How did we do? Rate your last conversation.' : 'How did we do? Rate your last conversation with $label.';
      run.between(() => rows.add('csat-pending:$pendingCsat', title, () => CsatCard(ratingId: pendingCsat, title: title)));
    }
    final preview = c.preview;
    if (preview != null) {
      final shownAt = c.previewShownAt ?? DateTime.now();
      for (var i = 0; i < preview.messages.length; i++) {
        final m = preview.messages[i];
        final meta = m.meta;
        if (m.body.trim().isNotEmpty || meta?.imageUrl != null || meta?.articleSlug != null || meta?.fileUrl != null) {
          run.bubble('bot', shownAt, (pos, _, first) => rows.add('preview:$i', (m, pos, first, label), () => _TeamRow(
                message: ChatMessage(id: '', conversationId: '', body: m.body, authorType: 'bot', createdAt: shownAt, meta: meta),
                pos: pos,
                name: label,
                first: first,
              )));
        }
        if (meta != null && meta.buttons.isNotEmpty) {
          run.between(() => rows.add('preview-buttons:$i', m, () => _FlowButtons(buttons: meta.buttons, onTap: c.startWorkflow)));
        }
      }
    } else if (c.typingAuthor != null) {
      final author = c.typingAuthor;
      run.between(() => rows.add('typing', (author, 0, rows.list.isEmpty), () => _TypingSlot(author: author, replies: 0, first: rows.list.isEmpty)), breaks: false);
    } else {
      // The chips fall back to the top articles: built again when those come.
      run.between(() => rows.add('intro', c.articles, () => _IntroAndChips(chips: c.chips)));
    }
  } else {
    _messageRows(context, c, c.live, cache, agentSeenAt: c.agentSeenAt, divider: c.dividerIndex, livePrompt: c.livePrompt, run: run);
    // Always there, empty while nobody types: it opens and closes in place.
    var replies = 0;
    for (final m in c.live) {
      if (!m.fromVisitor) replies++;
    }
    final author = c.typingAuthor;
    run.between(() => rows.add('typing', (author, replies), () => _TypingSlot(author: author, replies: replies)), breaks: false);
  }
  final notice = c.flowNotice;
  if (notice != null) run.between(() => rows.add('notice', notice, () => _ErrorLine(notice)));
  for (final out in c.outgoing) {
    // Its copy from the server is in the thread already, in this row.
    if (c.isTakenOver(out)) continue;
    run.bubble('visitor', out.createdAt, mine: true, (pos, _, first) {
      // On its way, or refused: its line says so, last or not.
      rows.add('out:${out.localId}', (out.error, out.image, pos, first), () => _MineRow(out: out, pos: pos, first: first, status: true), message: out);
    });
  }
  run.flush();
  cache.end();
  return rows.list;
}

List<Widget> _messageRows(
  BuildContext context,
  MessengerController c,
  List<ChatMessage> messages,
  _RowCache cache, {
  DateTime? agentSeenAt,
  int divider = -1,
  ChatMessage? livePrompt,
  _Run? run,
}) {
  final live = run != null;
  if (!live) cache.begin(c);
  final into = run ?? _Run(_Rows(cache));
  final rows = into.rows;
  final label = c.session?.productLabel ?? '';
  // A teammate who has answered has seen what came before, whatever the
  // seen receipts say.
  final lastAnswer = messages.lastIndexWhere((m) => m.authorType == 'agent');
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (i == divider) into.between(() => rows.add('divider', null, () => const _NewMessagesDivider()));
    final meta = m.meta;
    final bodyless = m.authorType == 'bot' && m.body.trim().isEmpty && m.attachments.isEmpty &&
        meta?.imageUrl == null && meta?.articleSlug == null && meta?.fileUrl == null;
    if (!bodyless) {
      if (m.fromVisitor) {
        // Written here: the row it was drawn in while on its way.
        final local = live ? c.sentAs(m) : null;
        into.bubble('visitor', m.createdAt, mine: true, (pos, status, first) {
          // Live, its line listens for the team's seen receipts itself; in a
          // past conversation it is what was fetched.
          final seenAt = live ? null : agentSeenAt;
          final answered = i < lastAnswer;
          rows.add(local != null ? 'out:$local' : 'msg:${m.id}', (m, m.id, m.body, pos, status, first, seenAt, answered),
              () => _MineRow(message: m, pos: pos, first: first, status: status, seenAt: seenAt, answered: answered, live: live), message: m);
        });
      } else {
        final name = _authorName(m, label);
        into.bubble('${m.authorType}|${m.authorId}|${m.authorName}', m.createdAt, (pos, _, first) {
          // The id and the words: an AI answer types out into the same message.
          rows.add('msg:${m.id}', (m, m.id, m.body, pos, first, name), () => _TeamRow(message: m, pos: pos, name: name, first: first), message: m);
        });
      }
    }
    final csat = meta?.csatRatingId;
    if (m.authorType == 'bot' && csat != null) into.between(() => rows.add('csat:${m.id}', csat, () => CsatCard(ratingId: csat, title: 'Tap a face'), message: m));
    if (livePrompt != null && identical(m, livePrompt)) {
      if (meta!.buttons.isNotEmpty) {
        into.between(() => rows.add('buttons:${m.id}', m, () => _FlowButtons(buttons: meta.buttons, onTap: (b) => c.choose(m, b)), message: m));
      } else if (meta.collect != null) {
        into.between(() => rows.add('collect:${m.id}', m, () => _CollectBox(prompt: m, request: meta.collect!), message: m));
      }
    }
  }
  if (live) return rows.list;
  into.flush();
  cache.end();
  return rows.list;
}

/// The rows, newest at the bottom — and the list anchored there, so it opens
/// on the latest message.
///
/// What the customer sends always comes into view. A reply comes into view
/// only for a reader already at (or near) the latest; one reading further up
/// stays exactly where they are, with a "New message" pill that takes them
/// down. A drag or a tap on the thread puts the keyboard away.
///
/// At the latest, rows that come in live do not push the thread up in one
/// jump: what is on screen stays where it was in the frame they land in —
/// even if the composer shrank in the same frame — and from there the thread
/// glides up to them ([glide]).
class _Thread extends StatefulWidget {
  const _Thread({super.key, required this.rows, this.sent = 0, this.received = 0, this.glide = false});
  final List<Widget> rows;

  /// Some of the rows came in live.
  final bool glide;

  /// The customer's own messages, sent or on their way.
  final int sent;

  /// Everyone else's: the team's, the AI's, the workflow's.
  final int received;

  @override
  State<_Thread> createState() => _ThreadState();
}

/// The dots a reply takes the place of, handed from the typing row to the
/// reply's rows in the frame the reply lands: they fade out over it.
class _Dots {
  _Dots(this.author, this.shown);
  final TypingAuthor author;

  /// How much of the typing row showed (it may have been closing).
  final double shown;

  /// The reply that took them.
  Object? by;
}

class _ThreadState extends State<_Thread> with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  late final _physics = _KeepPlace(this);

  /// The rows built right now, by key: where each is laid out.
  final _slots = <Key, _SlotState>{};

  /// A row on screen before an update — how far its top sat above the
  /// bottom of the view, as drawn; how tall it was; the row just above it,
  /// whose foot is its top; and the view's height then — for the one layout
  /// that follows.
  ({Key key, double above, double extent, Key? upper, double view})? _anchor;

  /// The update brought rows in live at the latest: the frame that draws
  /// them starts the glide from where the anchor holds the thread.
  bool _landing = false;

  /// The glide down to the latest: how far the thread is drawn below its
  /// place there, on a critically damped spring. In the frame a row lands
  /// it starts from where the thread was, with the speed it already had: a
  /// second reply while the first glides carries it on, never from rest.
  late final AnimationController _glide = AnimationController.unbounded(vsync: this, animationBehavior: AnimationBehavior.preserve)
    ..addListener(_onGlide)
    ..addStatusListener(_onGlideStatus);

  /// The glide moves the scroll offset as well as the shift; not once the
  /// reader's finger has the thread.
  bool _glideScrolls = true;

  /// Fingers on the thread now: while there are, a glide leaves the scroll
  /// offset to them.
  int _fingers = 0;

  /// A finger came onto the thread on its way to the latest (a glide, or
  /// rows landing under it): where it then was. While the finger stays,
  /// nothing moves under it; once it lets go, the thread goes on down —
  /// unless the finger took the reader up the thread meanwhile.
  double? _heldUnderFinger;

  /// Rows landed under the finger: if the reader went up meanwhile, the
  /// pill says so.
  bool _landedUnderFinger = false;

  /// What scrolling cannot take of the glide (a thread shorter than the
  /// screen does not scroll): the rows are drawn this much lower (higher,
  /// below 0). Drawn only: nothing is laid out again.
  double _shift = 0;
  _RenderShifted? _shifted;

  /// The dots a reply is taking the place of, for this frame.
  _Dots? _dots;

  /// The time, for the "2m" under bubbles: ticked every 15 seconds, so a
  /// label is never more than that behind; only those labels listen.
  final _now = ValueNotifier<DateTime>(DateTime.now());
  late final Timer _clock;

  /// Replies that arrived while the reader was up the thread.
  int _unseen = 0;

  /// What the pill last said: kept while it fades away.
  int _pillCount = 1;

  /// How far from the latest still counts as reading it, in logical pixels.
  static const _near = 120.0;

  /// The glide's spring: from rest most of the way in 150 ms, settled by
  /// 300, never past the latest and back.
  static final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 600, ratio: 1);
  static final _omega = math.sqrt(600.0);
  static const _tolerance = Tolerance(distance: 0.1, velocity: 5);

  bool get _gliding => _glide.isAnimating && _glideScrolls;

  bool get _atLatest => !_scroll.hasClients || _gliding || _scroll.offset <= _near;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _clock = Timer.periodic(const Duration(seconds: 15), (_) => _now.value = DateTime.now());
  }

  @override
  void dispose() {
    _clock.cancel();
    _now.dispose();
    _scroll.dispose();
    _glide.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_unseen > 0 && _scroll.offset <= _near) setState(() => _unseen = 0);
  }

  @override
  void didUpdateWidget(_Thread old) {
    super.didUpdateWidget(old);
    final atLatest = _atLatest;
    if (!atLatest) {
      _holdPlace(widget.rows);
    } else if (widget.glide && (widget.sent > old.sent || widget.received > old.received)) {
      // At the latest, with rows coming in live: those on screen stay where
      // they are in this frame, the new ones below them, out of view; the
      // glide to them starts in the same frame (see [_paintShift]).
      _holdPlace(widget.rows, before: old.rows);
      if (_anchor != null) {
        _landing = true;
        // The list is its own repaint boundary: ask for the paint that
        // starts the glide.
        _shifted?.markNeedsPaint();
      }
    }
    if (widget.sent > old.sent) {
      _unseen = 0;
      if (!_landing) _toLatest();
    } else if (widget.received > old.received) {
      if (atLatest) {
        if (!_landing) _toLatest();
      } else {
        _unseen += widget.received - old.received;
      }
    }
  }

  /// A reader keeps their place through the update. The list is reversed: a
  /// row added below moves every other row to a new index, and the list
  /// would lay them out a little off where they were (and an answer typing
  /// out below would push them up). So: note a row on screen now, and in the
  /// layout that follows set the scroll offset so that it is where it was
  /// ([_KeepPlace]).
  ///
  /// The row is one that is still among [rows]. With [before] (the rows
  /// before the update) it is also above every new row: the new rows then
  /// come in below it.
  void _holdPlace(List<Widget> rows, {List<Widget>? before}) {
    if (!_scroll.hasClients) return;
    final index = <Key, int>{
      for (var i = 0; i < rows.length; i++)
        if (rows[i].key != null) rows[i].key!: i,
    };
    var limit = rows.length;
    if (before != null) {
      final had = <Key?>{for (final r in before) r.key};
      for (var i = 0; i < rows.length; i++) {
        if (!had.contains(rows[i].key)) {
          limit = i;
          break;
        }
      }
    }
    final pixels = _scroll.position.pixels;
    final view = _scroll.position.viewportDimension;
    ({Key key, double above, double extent, Key? upper, double view})? found;
    for (final slot in _slots.values) {
      final i = index[slot.widget.key];
      if (i == null || i >= limit) continue;
      final at = slot.layoutOffset;
      if (at == null || at < pixels || at > pixels + view) continue;
      // Its top, as drawn: a row that loses its last line (the status
      // under the customer's message before, a name under the team's)
      // keeps its words where they were.
      final extent = slot.extent;
      final above = at + extent - pixels - _shift;
      if (found == null || above < found.above) {
        found = (key: slot.widget.key!, above: above, extent: extent, upper: i > 0 ? rows[i - 1].key : null, view: view);
      }
    }
    if (found == null) return;
    _anchor = found;
    // For this update's layout only: a later one is the reader scrolling.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchor = null;
      // Not drawn after all (the list was not painted): straight down.
      if (_landing && mounted) _toLatest();
      _landing = false;
    });
  }

  /// How far below its place at the latest the thread must be drawn for
  /// [_anchor] to be where it was: the scroll offset, and past what
  /// scrolling can reach, a shift. The view's change counts: the composer
  /// shrinking as it sends grows the view by its lines in the same frame,
  /// and the rows keep their place on the screen, not above its foot.
  double? _held(ScrollMetrics now) {
    final anchor = _anchor;
    if (anchor == null) return null;
    final at = _slots[anchor.key]?.layoutOffset;
    if (at == null) return null;
    // Its top now: the foot of the row above it (a row's own height cannot
    // be asked for in the middle of the list's layout), else where its own
    // height put it.
    final upper = anchor.upper;
    final top = (upper == null ? null : _slots[upper]?.layoutOffset) ?? at + anchor.extent;
    return top - anchor.above - (now.viewportDimension - anchor.view);
  }

  /// The scroll offset that keeps [_anchor] where it was, or [pixels].
  double _keptPixels(ScrollMetrics now, double pixels) {
    final kept = _held(now);
    if (kept == null) return pixels;
    if (kept < now.minScrollExtent) return now.minScrollExtent;
    if (kept > now.maxScrollExtent) return now.maxScrollExtent;
    return kept;
  }

  /// At each paint of the list. In the frame rows land, the rows on screen
  /// that scrolling could not keep in place are drawn where they were, and
  /// the glide starts from there.
  double _paintShift() {
    if (_landing && _scroll.hasClients) {
      _landing = false;
      final held = _held(_scroll.position);
      if (held != null) {
        _shift = held - _scroll.position.pixels;
        if (_fingers > 0) _heldUnderFinger = _scroll.position.pixels;
        _glideFrom(held);
      }
    }
    return _shift;
  }

  /// Glide from [from] (how far below its place the thread is drawn) to
  /// the latest. The speed it had carries on, and what came in adds a
  /// push of its own, so it moves from the first frame after.
  void _glideFrom(double from) {
    if (_fingers > 0) {
      // A finger on the thread: nothing moves under it until it lets go.
      _glide.stop();
      _heldUnderFinger = _scroll.position.pixels;
      _landedUnderFinger = true;
      return;
    }
    final now = _glide.isAnimating ? _glide.value : 0.0;
    final speed = _glide.isAnimating ? _glide.velocity : 0.0;
    _glideScrolls = true;
    _glide.animateWith(SpringSimulation(_spring, from, 0, speed - 0.5 * _omega * (from - now), tolerance: _tolerance));
  }

  void _onGlide() {
    if (!_scroll.hasClients) return;
    final d = _glide.value;
    if (!_glideScrolls) {
      // The finger has the scroll: the spring runs on the shift alone.
      _setShift(d);
      return;
    }
    final position = _scroll.position;
    final pixels = d.clamp(position.minScrollExtent, position.maxScrollExtent);
    if (pixels != position.pixels) position.jumpTo(pixels);
    _setShift(d - pixels);
  }

  void _onGlideStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed && status != AnimationStatus.dismissed) return;
    // Settled within a tenth of a point: exactly at the latest.
    if (_glideScrolls && _scroll.hasClients && _scroll.offset != 0 && _scroll.offset.abs() < 1) _scroll.jumpTo(0);
    _setShift(0);
  }

  void _setShift(double shift) {
    if (shift == _shift) return;
    _shift = shift;
    _shifted?.markNeedsPaint();
  }

  /// A finger on the thread: it is the reader's now. The glide leaves the
  /// scroll offset where it is; what was drawn shifted eases on into place.
  void _fingerDown(PointerDownEvent _) {
    _fingers++;
    if (!_gliding || !_scroll.hasClients) return;
    _glide.stop();
    _heldUnderFinger = _scroll.offset;
  }

  /// The last finger let go. If it came onto the thread on its way down
  /// and the reader is still about where it was, the thread goes on down;
  /// if they went up meanwhile, what was drawn shifted eases into place
  /// alone, and rows that landed under the finger bring the pill.
  void _fingerUp() {
    if (_fingers > 0) _fingers--;
    final held = _heldUnderFinger;
    if (_fingers > 0 || held == null) return;
    _heldUnderFinger = null;
    final landed = _landedUnderFinger;
    _landedUnderFinger = false;
    if (!_scroll.hasClients) return;
    if (_scroll.offset - held <= _near) {
      _toLatest();
      return;
    }
    if (_shift != 0) {
      _glideScrolls = false;
      _glide.animateWith(SpringSimulation(_spring, _shift, 0, 0, tolerance: _tolerance));
    }
    if (landed) setState(() => _unseen++);
  }

  /// Once the new rows are laid out: down to the latest (the list is
  /// reversed, so that is offset 0), on the glide's spring, with less
  /// motion asked for too, as Intercom's thread is (see [fullTime]); from
  /// far up it jumps, rather than scroll through the whole history.
  void _toLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final from = _scroll.offset;
      if (from <= 0 && _shift == 0) return;
      if (from > _scroll.position.viewportDimension * 2) {
        _glide.stop();
        _setShift(0);
        _scroll.jumpTo(0);
      } else {
        _glideFrom(from + _shift);
      }
    });
  }

  /// The reply in [message] takes the place of the typing dots: they are
  /// handed to its first row, to fade out over it. Null for any other row.
  _Dots? _dotsFor(Object? message) {
    final d = _dots;
    if (d == null || message is! ChatMessage || message.fromVisitor) return null;
    d.by ??= message;
    return identical(d.by, message) ? d : null;
  }

  /// The typing row closed at once for a reply: its dots go to the reply.
  void _dotsTaken(TypingAuthor author, double shown) {
    _dots = _Dots(author, shown);
    WidgetsBinding.instance.addPostFrameCallback((_) => _dots = null);
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
        // Its own layer: the glide repaints the thread, not the header and composer.
        Positioned.fill(
          child: RepaintBoundary(
            child: Listener(
              onPointerDown: _fingerDown,
              onPointerUp: (_) => _fingerUp(),
              onPointerCancel: (_) => _fingerUp(),
              child: _Shifted(thread: this, child: _Now(clock: _now, child: list)),
            ),
          ),
        ),
        // It fades in and out over 200 ms rather than blink.
        Positioned(
          left: 0,
          right: 0,
          bottom: 10,
          child: Center(
            child: Reveal(
              shown: _unseen > 0,
              size: false,
              child: _NewMessagePill(
                count: _unseen > 0 ? _pillCount = _unseen : _pillCount,
                onTap: () {
                  setState(() => _unseen = 0);
                  _toLatest();
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws the thread [_ThreadState._paintShift] lower, inside its own box, and
/// takes taps where it is drawn. A paint offset, not a layout.
class _Shifted extends SingleChildRenderObjectWidget {
  const _Shifted({required this.thread, required super.child});
  final _ThreadState thread;

  @override
  _RenderShifted createRenderObject(BuildContext context) => _RenderShifted(thread);

  @override
  void updateRenderObject(BuildContext context, _RenderShifted renderObject) {}
}

class _RenderShifted extends RenderProxyBox {
  _RenderShifted(this.thread);
  final _ThreadState thread;
  final _clip = LayerHandle<ClipRectLayer>();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    thread._shifted = this;
  }

  @override
  void detach() {
    if (identical(thread._shifted, this)) thread._shifted = null;
    super.detach();
  }

  @override
  void dispose() {
    _clip.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final dy = thread._paintShift();
    final child = this.child;
    if (child == null) return;
    if (dy == 0) {
      _clip.layer = null;
      context.paintChild(child, offset);
      return;
    }
    _clip.layer = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (context, offset) => context.paintChild(child, offset + Offset(0, dy)),
      oldLayer: _clip.layer,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
        offset: Offset(0, thread._shift),
        position: position,
        hitTest: (result, position) => super.hitTestChildren(result, position: position),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    // Matrix4's translate is spelt differently across Flutter versions.
    transform.multiply(Matrix4.translationValues(0, thread._shift, 0));
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
  /// In the tree. The list lets go of a row it no longer lays out (pushed
  /// out of range by taller rows) in the middle of a layout, a while before
  /// disposing it; it has no place to ask for then.
  bool _active = true;

  @override
  void initState() {
    super.initState();
    widget.slots[widget.key!] = this;
  }

  @override
  void activate() {
    super.activate();
    _active = true;
    widget.slots[widget.key!] = this;
  }

  @override
  void deactivate() {
    _active = false;
    if (identical(widget.slots[widget.key!], this)) widget.slots.remove(widget.key!);
    super.deactivate();
  }

  @override
  void dispose() {
    if (identical(widget.slots[widget.key!], this)) widget.slots.remove(widget.key!);
    super.dispose();
  }

  /// The row's box in the list, while it is laid out.
  RenderBox? get _item {
    if (!_active || !mounted) return null;
    RenderObject? r = context.findRenderObject();
    while (r != null) {
      if (r.parentData is SliverMultiBoxAdaptorParentData) return r is RenderBox ? r : null;
      r = r.parent;
    }
    return null;
  }

  /// Where the row is laid out along the thread (0 at the latest: its
  /// foot), or null while it is not laid out.
  double? get layoutOffset => (_item?.parentData as SliverMultiBoxAdaptorParentData?)?.layoutOffset;

  /// How tall it is laid out.
  double get extent {
    final item = _item;
    return item != null && item.hasSize ? item.size.height : 0;
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
        child: Pressable(
          shape: const StadiumBorder(),
          onBrand: true,
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
  Widget build(BuildContext context) => MessengerSelector<(String, MessengerSession?, int?, bool)>(
        select: (c) => (c.brand.hex, c.session, c.agentsOnline, c.connected),
        builder: (context, _) => _bar(context),
      );

  Widget _bar(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final s = c.session;
    // The controller knows of nobody online while it connects or reconnects
    // (agentsOnline is null then), so the line says "Active now" only once
    // the connection is up and the server has said someone is.
    final status = presenceLines(c.agentsOnline, s?.officeHours);
    final team = s?.team ?? const <TeamFace>[];
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
              // The team given, not read: built again only with the session.
              if (team.isNotEmpty) TeamFaces(size: 30, border: 1.5, team: team) else LogoAvatar(label: s?.productLabel ?? '?', size: 34),
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
  const _LiveFooter();

  @override
  Widget build(BuildContext context) {
    final room = _KeyboardRoom.of(context);
    return MessengerSelector<(bool, String?, bool, String?, MessengerSession?, String)>(
      select: (c) => (c.showEmailBar, c.sendError, c.outgoing.isEmpty, c.emailSavedFor, c.session, c.brand.hex),
      builder: (context, _) {
        final c = context.messenger;
        final sendError = c.sendError;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // With the keyboard up on a phone the "leave your email" form is
            // one line; on its side, not even that (it is there again once
            // the keyboard goes down).
            Reveal(shown: c.showEmailBar && !room.tight, child: _EmailBar(compact: room.cramped)),
            if (sendError != null && c.outgoing.isEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: _ErrorLine(sendError)),
            // Flexible: in the little room of a phone on its side it is the
            // composer that gives way.
            const Flexible(child: _Composer()),
          ],
        );
      },
    );
  }
}

class _PastFooter extends StatelessWidget {
  const _PastFooter({required this.conversationId, required this.past, this.cached});
  final String conversationId;
  final Future<ConversationDetail>? past;
  final ConversationDetail? cached;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    // While the CSAT comment is being typed the footer steps aside: the box
    // and its Send need the room. Kept built, so it comes back whole, not a
    // frame without its line.
    return Offstage(
      offstage: _KeyboardRoom.of(context).up,
      child: FutureBuilder<ConversationDetail>(
        future: past,
        initialData: cached,
        builder: (context, snap) => _footer(context, brand, (snap.data ?? cached)?.open == false),
      ),
    );
  }

  Widget _footer(BuildContext context, BrandColors brand, bool closed) => Container(
          width: double.infinity,
          padding: EdgeInsets.fromLTRB(16, 14, 16, 14 + MediaQuery.paddingOf(context).bottom),
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
}

// ==========================================================================
// Messages
// ==========================================================================

/// A teammate's photo, by their user id: the path is only built from a
/// well-formed id. Null without one.
String? _teammatePhoto(String? userId) =>
    userId != null && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(userId) ? '/widget/avatar/$userId' : null;

/// The face beside a group of the team's bubbles: the teammate's photo
/// (their initial without one), the chatbot's circle for the workflow — as
/// Intercom shows the brand beside the bot — and a robot for the AI.
Widget _teamFace(String authorType, String name, String? authorId) {
  if (authorType == 'ai') return InitialAvatar(label: name, size: _faceSize, icon: Icons.smart_toy_outlined);
  if (authorType == 'bot') return LogoAvatar(label: name, size: _faceSize);
  final photo = authorType == 'agent' ? _teammatePhoto(authorId) : null;
  if (photo != null) return PersonAvatar(name: name, photoPath: photo, size: _faceSize);
  return InitialAvatar(label: name, size: _faceSize);
}

/// The time now, for the "2m" under bubbles: the thread ticks it so they
/// stay true, and only they are built again for it.
class _Now extends InheritedWidget {
  const _Now({required this.clock, required super.child});
  final ValueListenable<DateTime> clock;

  @override
  bool updateShouldNotify(_Now old) => !identical(clock, old.clock);
}

/// How long ago [at] was — "Just now", "2m" — after [prefix], kept true as
/// the minutes pass.
class _Ago extends StatelessWidget {
  const _Ago({super.key, required this.at, required this.style, this.prefix = ''});
  final DateTime at;
  final String prefix;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    Widget line(BuildContext _, Object? __, Widget? ___) =>
        Text('$prefix${agoLabel(at, DateTime.now())}', maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    final clock = context.getInheritedWidgetOfExactType<_Now>()?.clock;
    return clock == null ? line(context, null, null) : ValueListenableBuilder<DateTime>(valueListenable: clock, builder: line);
  }
}

/// The small print under a group or a message: names, times, "Seen".
const _smallPrint = TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Palette.muted);

/// One of the team's messages — a teammate's, the AI's, the workflow's — in
/// its group: its bubble beside the face column, which shows the face at
/// the group's last bubble; under that bubble, the name and how long ago.
class _TeamRow extends StatelessWidget {
  const _TeamRow({required this.message, required this.pos, required this.name, this.first = false});

  final ChatMessage message;
  final _Pos pos;
  final String name;

  /// The first row of the thread: no room above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final m = message;
    final last = pos.ends;
    Widget bubble = _Bubble(message: m, pos: pos);
    // A reply that takes the typing dots' place: they fade out over its
    // bubble, the same shape in the same place, as it fades in.
    final over = context.getInheritedWidgetOfExactType<_DotsHandover>();
    if (over != null) {
      bubble = Stack(
        clipBehavior: Clip.none,
        children: [
          bubble,
          Positioned(
            left: 0,
            top: 0,
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: over.progress,
                  builder: (_, __) {
                    final t = over.progress.value;
                    return t >= 1 ? const SizedBox.shrink() : Opacity(opacity: (over.shown * (1 - t)).clamp(0.0, 1.0), child: const _DotsBubble());
                  },
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Padding(
      padding: EdgeInsets.only(top: _gapAbove(pos, first)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SizedBox(width: _faceSize, height: last ? _faceSize : 0, child: last ? _teamFace(m.authorType, name, m.authorId) : null),
              const SizedBox(width: _faceColumn - _faceSize),
              Flexible(child: bubble),
            ],
          ),
          if (last)
            Padding(
              padding: const EdgeInsets.only(left: _faceColumn + 2, top: 4),
              child: _Ago(prefix: '$name · ', at: m.createdAt, style: _smallPrint),
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

/// A message's bubble: the team's, the AI's, the workflow's — inside
/// [_TeamRow] — or, inside [_MineRow], the customer's own.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, this.pos = _Pos.single});

  final ChatMessage message;
  final _Pos pos;

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
    // A photo alone is the bubble, edge to edge: no band of colour under it.
    final onlyMedia = text.isEmpty && m.attachments.isNotEmpty && m.attachments.every((a) => a.isImage);
    // Each part, and the room above it: none above the first, so nothing
    // trails under the last.
    final parts = <(double, Widget)>[
      if (bot && meta?.imageUrl != null) (8, _BotImage(url: meta!.imageUrl!)),
      for (final a in m.attachments) (6, _AttachmentView(attachment: a, mine: mine, framed: !onlyMedia)),
      // A long press copies the words. On the words alone: over the whole
      // bubble it held back the taps of a card or a photo in it.
      if (text.isNotEmpty)
        (6, GestureDetector(
          onLongPress: () {
            HapticFeedback.lightImpact();
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Copied')));
          },
          child: _RichText(text, color: fg, linkColor: mine ? fg : brand.primary),
        )),
      if (bot && meta?.articleSlug != null && context.messenger.session?.helpBaseUrl != null)
        (8, _InBubbleCard(
          icon: Icons.description_outlined,
          title: meta!.articleTitle ?? 'Help article',
          hint: 'Read article',
          onTap: () => openArticle(context, meta.articleSlug!, title: meta.articleTitle ?? 'Help article'),
        )),
      if (bot && meta?.fileUrl != null)
        (8, _InBubbleCard(
          icon: Icons.attach_file,
          title: meta!.fileName ?? 'File',
          onTap: () => openExternal(context, Uri.parse(meta.fileUrl!)),
        )),
    ];
    final children = <Widget>[
      for (var i = 0; i < parts.length; i++) ...[
        if (i > 0) SizedBox(height: parts[i].$1),
        parts[i].$2,
      ],
    ];
    return _BubbleBox(mine: mine, pos: pos, tight: onlyMedia, children: children);
  }
}

/// A bubble's corners: 20, and 4 on the author's side where it meets the
/// bubble above or below in its group — and at the foot of a lone bubble
/// or a group's first, where the next would join.
BorderRadius _corners(bool mine, _Pos pos) {
  const round = Radius.circular(20);
  const tight = Radius.circular(4);
  final top = pos.starts ? round : tight;
  final foot = pos == _Pos.bottom ? round : tight;
  return mine
      ? BorderRadius.only(topLeft: round, topRight: top, bottomRight: foot, bottomLeft: round)
      : BorderRadius.only(topLeft: top, topRight: round, bottomRight: round, bottomLeft: foot);
}

/// A bubble's shape and colour: the brand colour on the right for the
/// customer, grey on the left for everyone else, its corners by its place
/// in its group. [tight]: photos alone, edge to edge, cut to the corners.
class _BubbleBox extends StatelessWidget {
  const _BubbleBox({required this.mine, required this.children, this.pos = _Pos.single, this.tight = false});
  final bool mine;
  final _Pos pos;
  final bool tight;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
      padding: tight ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      clipBehavior: tight ? Clip.antiAlias : Clip.none,
      decoration: BoxDecoration(color: mine ? brand.primary : Palette.agentBubble, borderRadius: _corners(mine, pos)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// One of the customer's own messages, in its group: its bubble and, under
/// the last of them (or one on its way, or refused), one line — "Sending…"
/// only if it takes a while, then "Not seen yet · Just now", then "Seen ·
/// 2m"; or "Failed to send · Retry". The same row from the moment it is
/// written to the server's copy (the copy takes its key), so the bubble
/// never flickers and the line under it fades from one to the next. The
/// bubble is whole at once: never dimmed while it goes.
class _MineRow extends StatelessWidget {
  const _MineRow({this.message, this.out, this.pos = _Pos.single, this.first = false, this.status = false, this.seenAt, this.answered = false, this.live = false})
      : assert((message == null) != (out == null));

  /// The server's copy, once there is one.
  final ChatMessage? message;

  /// The message on its way, or one the server refused.
  final OutgoingMessage? out;
  final _Pos pos;

  /// The first row of the thread: no room above it.
  final bool first;

  /// The line under it: the customer's last message, or one not yet sent.
  final bool status;

  /// When the team last read the conversation, in a past one.
  final DateTime? seenAt;

  /// A teammate has written since: it was seen.
  final bool answered;

  /// In the live conversation: "Seen" follows the controller's
  /// [MessengerController.agentSeenAt] itself.
  final bool live;

  static const statusFade = Duration(milliseconds: 150);

  /// What a refused message says when the server gave no reason of its own.
  static const _noReason = 'Something went wrong — please try again.';

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final m = message;
    final o = out;
    final Widget bubble;
    Widget? line;
    String? reason;
    if (m != null) {
      bubble = _Bubble(message: m, pos: pos);
      bool seenBy(DateTime? at) => answered || at != null && !m.createdAt.isAfter(at);
      Widget said(bool seen) => _Ago(key: const ValueKey<String>('sent'), prefix: seen ? 'Seen · ' : 'Not seen yet · ', at: m.createdAt, style: _smallPrint);
      // A seen receipt redraws the line, not the row.
      if (status) line = live ? MessengerSelector<bool>(key: const ValueKey<String>('sent'), select: (c) => seenBy(c.agentSeenAt), builder: (_, seen) => said(seen)) : said(seenBy(seenAt));
    } else {
      final image = o!.image;
      bubble = AnimatedOpacity(
        // Refused: dimmed beside the reason, softly — with less motion asked
        // for too (see [fullTime]).
        opacity: o.failed ? 0.55 : 1,
        duration: fullTime(statusFade),
        child: _BubbleBox(
          mine: true,
          pos: pos,
          tight: image != null && o.text.isEmpty,
          children: [
            // Kept: the photo is the same picture under the server's copy.
            if (image != null) _Photo(image: _memory(image), framed: o.text.isNotEmpty),
            if (image != null && o.text.isNotEmpty) const SizedBox(height: 6),
            if (o.text.isNotEmpty) Text(o.text, style: TextStyle(fontSize: 15, height: 1.45, color: brand.onPrimary)),
          ],
        ),
      );
      if (!o.failed) {
        _buzzed[o] = null;
        line = const _SendingLine(key: ValueKey<String>('sending'));
      } else {
        // A light tap of the phone as it fails, once a failure.
        if (_buzzed[o] == null) {
          _buzzed[o] = true;
          HapticFeedback.lightImpact();
        }
        // The server's own sentence ("wait 9s", "too long") says why.
        reason = o.error == _noReason ? null : o.error;
        // Wraps rather than overflow, at a large text size.
        line = Wrap(
          key: const ValueKey<String>('failed'),
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Failed to send ·', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Palette.error)),
            _LineButton(label: 'Retry', color: Palette.error, onTap: () => c.retry(o)),
            const Text('·', style: _smallPrint),
            _LineButton(label: 'Delete', color: Palette.muted, onTap: () => c.discard(o)),
          ],
        );
      }
    }
    // Even with less motion asked for, as Intercom's: see [fullTime].
    final fade = fullTime(statusFade);
    final said = line;
    return Padding(
      padding: EdgeInsets.only(top: _gapAbove(pos, first)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          bubble,
          if (reason != null)
            Padding(padding: const EdgeInsets.only(top: 4, right: 2), child: Text(reason, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, color: Palette.error))),
          // The line under it is one line tall whatever it says, from
          // "Sending…" to "Seen": nothing below moves as it changes. Not
          // sized to its words as they change, which cut the new words
          // (":54 PM") while the width eased; the old fade out over the new
          // as wide as the wider of the two, right-aligned. When a newer
          // message takes it, it closes over 200 ms rather than drop the
          // bubble above it by its height in one frame.
          Reveal(
            shown: said != null,
            child: said == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 4, right: 2),
                    child: Stack(
                      alignment: Alignment.centerRight,
                      children: [
                        const _StatusLineHeight(),
                        AnimatedSwitcher(
                          duration: fade,
                          layoutBuilder: (current, previous) => Stack(alignment: Alignment.centerRight, children: [...previous, if (current != null) current]),
                          child: said,
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The messages on their way whose failure the phone has said, by a tap.
final _buzzed = Expando<bool>('failure said');

/// A word to tap in a status line ("Retry"): the line's size, with the
/// room around it taking the tap too.
class _LineButton extends StatelessWidget {
  const _LineButton({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(RoundIconButton.minTarget, RoundIconButton.minTarget),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        child: Text(label),
      );
}

/// Holds a status line's height, at any text size: one line of its small
/// print.
class _StatusLineHeight extends StatelessWidget {
  const _StatusLineHeight();

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(child: Opacity(opacity: 0, child: Text('Hg', style: _smallPrint)));
}

/// "Sending…" under a message on its way — only once it has taken longer
/// than [wait]: most go through before that, and a word that flashes up and
/// is gone reads as something wrong. Its line's room is kept meanwhile, so
/// nothing moves when it shows.
class _SendingLine extends StatefulWidget {
  const _SendingLine({super.key});

  static const wait = Duration(milliseconds: 600);

  @override
  State<_SendingLine> createState() => _SendingLineState();
}

class _SendingLineState extends State<_SendingLine> {
  Timer? _wait;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _wait = Timer(_SendingLine.wait, () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        // Even with less motion asked for, as Intercom's: see [fullTime].
        duration: fullTime(_MineRow.statusFade),
        child: const Text('Sending…', style: _smallPrint),
      );
}

/// A picture the workflow sends: in a 4:3 box from the start, on a light
/// grey, so the thread does not jump when it loads; it fades in, whole.
class _BotImage extends StatelessWidget {
  const _BotImage({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(
          color: Palette.fill,
          child: Image.network(url, fit: BoxFit.contain, frameBuilder: fadeIn(), errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        ),
      ),
    );
  }
}

/// A thread still to come: bubbles at the foot of the screen, shimmering,
/// the team's on the left beside a face and the customer's on the right —
/// not a spinner — so what comes takes the place of something its shape.
class ThreadSkeleton extends StatelessWidget {
  const ThreadSkeleton({super.key});

  /// Each bubble: on the customer's side or not, its share of the width,
  /// its height.
  static const _bubbles = <(bool, double, double)>[
    (false, 0.62, 58),
    (true, 0.46, 40),
    (false, 0.52, 40),
    (true, 0.34, 40),
  ];

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading the conversation',
      child: ExcludeSemantics(
        child: Shimmer(
          // A list that does not scroll, from the foot up: in a short
          // space (a phone on its side, the keyboard up) the top ones go.
          child: LayoutBuilder(
            builder: (context, box) => ListView(
              reverse: true,
              primary: false,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              children: [
                for (var i = _bubbles.length - 1; i >= 0; i--)
                  Padding(
                    padding: EdgeInsets.only(top: i == 0 ? 0 : _groupGap),
                    child: Row(
                      mainAxisAlignment: _bubbles[i].$1 ? MainAxisAlignment.end : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (!_bubbles[i].$1) ...[
                          const SkeletonBar(width: _faceSize, height: _faceSize),
                          const SizedBox(width: _faceColumn - _faceSize),
                        ],
                        SkeletonBar(width: (box.maxWidth - 32) * _bubbles[i].$2, height: _bubbles[i].$3),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The thread's first load, a past conversation's: what comes fades in
/// over what stood for it, in 200 ms.
class _FadeSwitch extends StatelessWidget {
  const _FadeSwitch({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        // Even with less motion asked for, as Intercom's: see [fullTime].
        duration: fullTime(const Duration(milliseconds: 200)),
        layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
        child: child,
      );
}

class _InBubbleCard extends StatelessWidget {
  const _InBubbleCard({required this.icon, required this.title, required this.onTap, this.hint});
  final IconData icon;
  final String title;
  final String? hint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Its own Material: the ripple is drawn on it, over the bubble's grey.
    return Material(
      color: Palette.input,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Palette.border)),
      child: Pressable(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
    );
  }
}

/// The bytes behind each photo lookup once they are known, held only as long
/// as the lookup itself (the controller's): a row built again shows its
/// photo at once, never an empty box first.
final _photoBytes = Expando<Uint8List>('photo bytes');

/// One picture for each photo's bytes, so the one shown while it was on its
/// way and the server's copy share the image Flutter has already decoded.
final _memoryImages = Expando<MemoryImage>('photo image');

MemoryImage _memory(Uint8List bytes) => _memoryImages[bytes] ??= MemoryImage(bytes);

/// A photo or file on a message. The customer's own photos are read with
/// their token (they have no public address); https files open outside.
/// [framed]: inside a bubble with words, rounded on its own; alone, the
/// bubble is cut to it.
class _AttachmentView extends StatelessWidget {
  const _AttachmentView({required this.attachment, required this.mine, this.framed = true});
  final Attachment attachment;
  final bool mine;
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final uploadId = a.uploadId;
    // The customer's own photos keep the 4:3 box they were drawn in on their
    // way, so the server's copy taking the row never changes its shape.
    final size = !mine && a.width != null && a.height != null ? Size(a.width!.toDouble(), a.height!.toDouble()) : null;
    if (a.isImage && uploadId != null) {
      final lookup = context.messenger.fileBytes(uploadId);
      return FutureBuilder<Uint8List>(
        future: lookup,
        initialData: _photoBytes[lookup],
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null && bytes.isNotEmpty) {
            _photoBytes[lookup] = bytes;
            return _Photo(image: _memory(bytes), size: size, framed: framed);
          }
          if (snap.hasError) return _FileChip(name: a.name, mine: mine);
          // Its box, grey, while the bytes come: the same box the photo fills.
          return _Photo(size: size, framed: framed);
        },
      );
    }
    if (a.isImage && a.url.startsWith('https://')) return _Photo(image: NetworkImage(a.url), size: size, framed: framed);
    return _FileChip(
      name: a.name,
      mine: mine,
      onTap: a.url.startsWith('https://') ? () => openExternal(context, Uri.parse(a.url)) : null,
    );
  }
}

/// A photo in the thread: one box from the start, whatever the photo — its
/// own shape when the server says it, else 4:3 — grey until the picture has
/// loaded, which then fades in over it in 150 ms. Nothing around it moves
/// when it does. Decoded at the size it is drawn; the whole picture only in
/// the viewer a tap opens.
class _Photo extends StatelessWidget {
  const _Photo({this.image, this.size, this.framed = true});

  /// Null while its bytes are on their way: the box alone.
  final ImageProvider? image;

  /// The photo's size in pixels, when known before it loads.
  final Size? size;

  /// Rounded on its own (beside words); without, the bubble around it is.
  final bool framed;

  static const width = 240.0;
  static const radius = 16.0;
  static const fade = Duration(milliseconds: 150);

  /// Its shape: the photo's own, kept between a tall 3:4 and a wide 2:1.
  double get _aspect {
    final s = size;
    if (s == null || s.width <= 0 || s.height <= 0) return 4 / 3;
    return (s.width / s.height).clamp(0.75, 2.0);
  }

  void _view(BuildContext context, ImageProvider image) {
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
  }

  @override
  Widget build(BuildContext context) {
    final image = this.image;
    // Decoded to the box's width in the phone's pixels, not the photo's
    // own (up to 2048 wide): less to decode, and to hold.
    final pixels = (width * MediaQuery.devicePixelRatioOf(context)).round();
    Widget box = SizedBox(
      width: width,
      height: (width / _aspect).roundToDouble(),
      child: ColoredBox(
        color: Palette.fill,
        child: image == null ? null : Image(image: ResizeImage(image, width: pixels), fit: BoxFit.cover, frameBuilder: fadeIn(fade), gaplessPlayback: true),
      ),
    );
    if (framed) box = ClipRRect(borderRadius: BorderRadius.circular(radius), child: box);
    if (image == null) return box;
    // The press over the picture, on a Material of its own laid on top:
    // drawn under it, a ripple would be hidden by the photo.
    return Stack(
      children: [
        box,
        Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: Pressable(
              onTap: () => _view(context, image),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
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
    // Its own Material: the ripple shows over the bubble's colour, in the
    // chip's rounded shape.
    return Material(
      type: MaterialType.transparency,
      child: Pressable(
        onTap: onTap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onBrand: mine,
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

/// A row of the thread. One that has just come in live fades in with a
/// small rise, as in Intercom; every other row (history, a reopen, a
/// catch-up) is simply there. Decided once, when the row is first built, by
/// asking the controller then — not by what the row was given at the last
/// build, which may be from before its message was drawn: a rebuild, a
/// scroll back to it, a reply first reached from up the thread, or the same
/// message under a new key (an AI answer taking its real id) never plays
/// it. Its name, bubble and buttons come in together. Opacity and a
/// translation only: nothing is laid out again while it plays. What the
/// customer sends rises without the fade: it is whole from the first frame.
///
/// A reply that comes while the typing dots show takes their place: its
/// rows fade in over 120 ms where they are, without the rise, while the
/// dots fade out over the first of them — never a frame with neither.
class _Entrance extends StatefulWidget {
  const _Entrance({required this.message, required this.child, this.lead = false});

  /// The row's message; null for a row that is no message's.
  final Object? message;

  /// The first of its message's rows.
  final bool lead;
  final Widget child;

  static const time = Duration(milliseconds: 200);

  /// How long a reply takes over from the dots.
  static const crossFade = Duration(milliseconds: 120);

  /// How far below its place it starts, in logical pixels.
  static const rise = 7.0;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance> with SingleTickerProviderStateMixin {
  AnimationController? _in;
  Animation<double>? _t;

  /// Decided once, as the rest: the customer's own message rises unfaded,
  /// and keeps the same tree when the server's copy takes its row over.
  bool _fade = true;
  bool _rise = true;

  /// The dots this row comes in over, fading out as it fades in.
  _Dots? _dots;

  @override
  void initState() {
    super.initState();
    final message = widget.message;
    final c = context.getInheritedWidgetOfExactType<MessengerScope>()?.controller;
    if (message == null || c == null || !c.isArriving(message)) return;
    final dots = context.findAncestorStateOfType<_ThreadState>()?._dotsFor(message);
    // Its whole time even with less motion asked for, as Intercom's: see
    // [fullTime].
    final a = AnimationController(vsync: this, duration: dots != null ? _Entrance.crossFade : _Entrance.time, animationBehavior: AnimationBehavior.preserve)
      ..forward();
    _in = a;
    _fade = message is! OutgoingMessage;
    _rise = dots == null;
    if (widget.lead) _dots = dots;
    _t = CurvedAnimation(parent: a, curve: dots != null ? Curves.easeOut : Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _in?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _t;
    if (t == null) return widget.child;
    final dots = _dots;
    // The reply's first row draws the dots over its bubble ([_TeamRow]),
    // fading out as the row fades in.
    final row = dots == null ? widget.child : _DotsHandover(shown: dots.shown, progress: t, child: widget.child);
    return FadeTransition(opacity: _fade ? t : kAlwaysCompleteAnimation, child: _rise ? _Rise(t, child: row) : row);
  }
}

/// The typing dots a reply's first row takes over: how much of them showed,
/// and the reply's fade, which they fade out against.
class _DotsHandover extends InheritedWidget {
  const _DotsHandover({required this.shown, required this.progress, required super.child});
  final double shown;
  final Animation<double> progress;

  @override
  bool updateShouldNotify(_DotsHandover old) => false;
}

class _Rise extends AnimatedWidget {
  const _Rise(Animation<double> t, {required this.child}) : super(listenable: t);
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    return Transform.translate(offset: Offset(0, _Entrance.rise * (1 - t)), child: child);
  }
}

/// The typing row's place at the foot of the thread. It opens — fades in and
/// grows — when someone starts typing. When they stop it holds for 600 ms
/// (a teammate's "stopped typing" comes just before their message), then
/// closes over 300 ms, quickly at first and gently at the end. A reply
/// takes its place: the row closes at once and the reply fades in over the
/// dots as they fade out ([_Entrance]), so the thread does not shrink and
/// then grow again, nor show a frame with neither. For a reader up the
/// thread the change is at once (the thread keeps the reader's place
/// through it); with less motion asked for it plays, as Intercom's does
/// (see [fullTime]).
class _TypingSlot extends StatefulWidget {
  const _TypingSlot({required this.author, required this.replies, this.first = false});

  /// Who is typing; null while nobody is.
  final TypingAuthor? author;

  /// Everyone else's messages so far: one more is the reply.
  final int replies;

  /// The first row of the thread: no room above it.
  final bool first;

  static const open = Duration(milliseconds: 200);
  static const hold = Duration(milliseconds: 600);
  static const close = Duration(milliseconds: 300);

  @override
  State<_TypingSlot> createState() => _TypingSlotState();
}

class _TypingSlotState extends State<_TypingSlot> with SingleTickerProviderStateMixin {
  late final AnimationController _open = AnimationController(
    vsync: this,
    duration: _TypingSlot.open,
    // Closing, the first 600 ms hold the row as it is: time for the reply.
    reverseDuration: _TypingSlot.hold + _TypingSlot.close,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final Animation<double> _shown = CurvedAnimation(
    parent: _open,
    curve: Curves.easeOutCubic,
    // Played backwards: quick at first, gentle into place.
    reverseCurve: Interval(0, _TypingSlot.close.inMilliseconds / (_TypingSlot.hold + _TypingSlot.close).inMilliseconds, curve: Curves.easeInCubic),
  );

  /// Who the row shows: kept while it closes.
  TypingAuthor? _who;

  @override
  void initState() {
    super.initState();
    _who = widget.author;
    if (_who == null) return;
    _open.forward();
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  /// The thread around it, if the reader is at (or near) the latest, where
  /// the row is in view — or on the way there.
  _ThreadState? get _thread => context.findAncestorStateOfType<_ThreadState>();
  bool get _animate => _thread?._atLatest ?? true;

  @override
  void didUpdateWidget(_TypingSlot old) {
    super.didUpdateWidget(old);
    final who = widget.author;
    if (who != null) {
      _who = who;
      if (!_animate) {
        _open.value = 1;
      } else if (_open.value < 1 && _open.status != AnimationStatus.forward) {
        _open.forward();
      }
    } else if (_open.value > 0) {
      final reply = widget.replies > old.replies;
      final shown = _who;
      if (reply && _animate && shown != null) {
        // The reply takes the place: it comes in over the dots as they go.
        _thread?._dotsTaken(shown, _shown.value);
        _open.value = 0;
      } else if (!_animate || reply) {
        _open.value = 0;
      } else if (_open.status != AnimationStatus.reverse) {
        _open.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final who = _who;
    final row = who == null ? null : _TypingRow(author: who, first: widget.first);
    return AnimatedBuilder(
      animation: _open,
      builder: (_, __) {
        // Closed: nothing at all, and the dots stop.
        if (row == null || _open.isDismissed) return const SizedBox.shrink();
        // SizeTransition's own alignment is spelt differently before and
        // after Flutter 3.41: the clip and the factor by hand work on both.
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _shown.value.clamp(0.0, 1.0),
            child: FadeTransition(opacity: _shown, child: row),
          ),
        );
      },
    );
  }
}

/// The dots, beside whoever is typing, in the column the team's faces use
/// (so a reply that takes their place shows the face where it was): the
/// teammate's photo (their initial without one), the chatbot's circle for
/// the workflow, and a plain person from a server that does not say who.
class _TypingRow extends StatelessWidget {
  const _TypingRow({required this.author, this.first = false});
  final TypingAuthor author;

  /// The first row of the thread: no room above it.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final who = author;
    final name = who.name;
    final Widget face;
    if (who.isBot) {
      face = LogoAvatar(label: context.messenger.session?.productLabel ?? '', size: _faceSize);
    } else if (who.id != null) {
      // The photo their replies show; their initial when they have none.
      face = PersonAvatar(name: name ?? '', photoPath: _teammatePhoto(who.id), size: _faceSize);
    } else {
      face = const InitialAvatar(label: '', size: _faceSize, icon: Icons.person_outline);
    }
    return Semantics(
      label: name == null || who.isBot ? 'Typing' : '$name is typing',
      child: Padding(
        padding: EdgeInsets.only(top: first ? 0 : _groupGap),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // The label says who: the initial would only repeat it.
            ExcludeSemantics(child: SizedBox(width: _faceSize, height: _faceSize, child: face)),
            const SizedBox(width: _faceColumn - _faceSize),
            const _DotsBubble(),
          ],
        ),
      ),
    );
  }
}

/// Three dots in a bubble one line of a message tall — a one-line reply
/// takes its place exactly. Each dot is 8 points, 4 apart, and fades from
/// full to 30% and back every 1200 ms, 200 ms after the one before.
class _DotsBubble extends StatefulWidget {
  const _DotsBubble();

  static const dot = 8.0;
  static const apart = 4.0;
  static const period = Duration(milliseconds: 1200);
  static const after = Duration(milliseconds: 200);

  @override
  State<_DotsBubble> createState() => _DotsBubbleState();
}

class _DotsBubbleState extends State<_DotsBubble> with SingleTickerProviderStateMixin {
  late final AnimationController _beat = AnimationController(vsync: this, duration: _DotsBubble.period)..repeat();

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  /// 1 at the start of a beat, 0.3 half-way, 1 again at its end.
  static double _opacity(double t) => 0.3 + 0.7 * (0.5 + 0.5 * math.cos(2 * math.pi * t));

  @override
  Widget build(BuildContext context) {
    final lag = _DotsBubble.after.inMilliseconds / _DotsBubble.period.inMilliseconds;
    return _BubbleBox(
      mine: false,
      children: [
        Stack(
          alignment: Alignment.centerLeft,
          children: [
            // One line of a message: the bubble's height at any text size.
            const ExcludeSemantics(child: Opacity(opacity: 0, child: Text('Hg', style: TextStyle(fontSize: 15, height: 1.45)))),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 3; i++) ...[
                  if (i > 0) const SizedBox(width: _DotsBubble.apart),
                  FadeTransition(
                    opacity: _beat.drive(_Beat(i * lag)),
                    child: Container(
                      width: _DotsBubble.dot,
                      height: _DotsBubble.dot,
                      decoration: const BoxDecoration(color: Palette.muted, shape: BoxShape.circle),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// One dot's beat: [_DotsBubbleState._opacity], [lag] of a beat late. (Not
/// a Curve: a curve must start at 0 and end at 1.)
class _Beat extends Animatable<double> {
  const _Beat(this.lag);
  final double lag;

  @override
  double transform(double t) => _DotsBubbleState._opacity((t - lag) % 1.0);
}

// ==========================================================================
// Before the first message: intro and chips
// ==========================================================================

class _IntroAndChips extends StatelessWidget {
  const _IntroAndChips({required this.chips});

  /// The chatbot's own, else its top articles ([MessengerController.chips]).
  final List<SuggestedQuestion> chips;

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
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

  static const corners = BorderRadius.only(
    topLeft: Radius.circular(16),
    topRight: Radius.circular(16),
    bottomLeft: Radius.circular(16),
    bottomRight: Radius.circular(4),
  );

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final fg = whatsapp ? Palette.whatsappText : brand.primary;
    // Dimmed while a choice is on its way, softly rather than in a frame.
    return AnimatedOpacity(
      opacity: enabled ? 1 : 0.55,
      // Even with less motion asked for, as Intercom's: see [fullTime].
      duration: fullTime(Reveal.time),
      child: Material(
        color: whatsapp ? Colors.white : brand.light,
        shape: RoundedRectangleBorder(side: BorderSide(color: whatsapp ? Palette.whatsapp : brand.ring), borderRadius: _Chip.corners),
        // The press in the chip's own shape, its tight corner too; a light
        // tick of the phone, as a choice made.
        child: Pressable(
          onTap: enabled
              ? () {
                  HapticFeedback.selectionClick();
                  onTap();
                }
              : null,
          shape: const RoundedRectangleBorder(borderRadius: _Chip.corners),
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
  Widget build(BuildContext context) => MessengerSelector<bool>(select: (c) => c.flowBusy, builder: _buttons);

  Widget _buttons(BuildContext context, bool busy) {
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
  Widget build(BuildContext context) => MessengerSelector<(bool, String?)>(select: (c) => (c.flowBusy, c.collectError), builder: (context, _) => _box(context));

  Widget _box(BuildContext context) {
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
  Widget build(BuildContext context) => MessengerSelector<(int?, String?, String?, String?)>(
        select: (c) {
          // The answer is changed in place: what it says, not the object.
          final a = c.csat[widget.ratingId];
          return (a?.rating, a?.commentState, a?.comment, a?.error);
        },
        builder: (context, _) => _card(context),
      );

  Widget _card(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final answer = c.csat[widget.ratingId];
    final rating = answer?.rating;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: Palette.border)),
      // A Material of its own over the card's white: the ripple under a
      // face was drawn on the page's, under the white, and never showed.
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.all(14),
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
                    // The faces behave as the article's do: the one chosen grows
                    // a little, the others turn grey and fade back.
                    for (final (value, emoji, label) in _faces)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Pressable(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              c.rate(widget.ratingId, value);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: ChoiceFace(emoji: emoji, chosen: rating == value, faded: rating != null && rating != value, size: 26),
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
        ),
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
          child: Pressable(
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

  /// A line more or less, eased.
  static const grow = Duration(milliseconds: 150);

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

  /// Moves on at each Send. Send empties the box, and it is one line again
  /// in the same frame, not eased down: the message lands in that frame and
  /// the thread keeps every row where it was on the screen, then glides —
  /// easing the box down under it as well dipped the thread before it rose.
  /// A new easing box (its key) takes its first size as it is; the box
  /// itself moves into it whole ([_boxKey]), the keyboard and all.
  int _sends = 0;
  final _boxKey = GlobalKey();

  void _send() {
    final c = context.messenger;
    final value = _text.text;
    if (value.trim().isEmpty) return;
    _text.clear();
    setState(() => _sends++);
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
  Widget build(BuildContext context) => MessengerSelector<(String?, String)>(select: (c) => (c.composerLock, c.brand.hex), builder: (context, _) => _box(context));

  Widget _box(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final lock = c.composerLock;
    // Waiting on a button or a detail above (or for the thread to load): a
    // composer that cannot be typed in, saying why, the height of the real
    // one — the thread does not jump when typing is allowed.
    if (lock != null) return _LockedComposer(hint: lock);
    // Not tied to the connection: the controller takes a message while it
    // connects and sends it once it can, so the customer is never left
    // looking at a grey Send button.
    final canSend = _text.text.trim().isNotEmpty;
    // The photo and Send buttons belong to the field's tap region: tapping
    // them keeps the keyboard up, as in any chat app. A tap anywhere else —
    // the thread, the header — puts it away.
    final box = Container(
        padding: EdgeInsets.fromLTRB(8, 8, 10, 8 + MediaQuery.paddingOf(context).bottom),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Palette.border))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _PhotoButton(onTap: _attach),
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
                decoration: _composerDecoration(brand, 'Type a message…'),
              ),
            ),
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: 'Send',
              // Its own Material, the circle painted on it as Ink: Android's
              // ripple shows over the circle, not under the composer's white.
              child: Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: RoundIconButton.minTarget,
                  height: RoundIconButton.minTarget,
                  child: Pressable(
                    onTap: canSend ? _send : null,
                    shape: const CircleBorder(),
                    inner: const Size.square(_SendCircle.size),
                    onBrand: canSend,
                    child: _SendCircle(ready: canSend, brand: brand),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    // A line more or less as they type: the box eases to its height from
    // the bottom up, so the thread above moves over 150 ms, not 46 points
    // in one frame — with less motion asked for too, as Intercom's (see
    // [fullTime]). Emptied by Send, it is one line at once ([_sends]).
    return TextFieldTapRegion(
      child: AnimatedSize(
        key: ValueKey<int>(_sends),
        duration: fullTime(_Composer.grow),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: KeyedSubtree(key: _boxKey, child: box),
      ),
    );
  }
}

/// The photo button beside the message box: 48 points, its press in a
/// 40-point circle, one recogniser (its name has no long press to wait for).
class _PhotoButton extends StatelessWidget {
  const _PhotoButton({required this.onTap});

  /// Null while typing waits on something above: greyed, and takes nothing.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: 'Send a photo',
        child: Tooltip(
          message: 'Send a photo',
          triggerMode: TooltipTriggerMode.manual,
          excludeFromSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox.square(
              dimension: 48,
              child: Pressable(
                onTap: onTap,
                shape: const CircleBorder(),
                inner: const Size.square(40),
                child: Icon(Icons.add_photo_alternate_outlined, color: onTap == null ? Palette.faint : Palette.muted),
              ),
            ),
          ),
        ),
      );
}

/// Send: a 36-point circle in its 44-point target — grey while there is
/// nothing to send, the brand colour once there is, turning over 180 ms.
class _SendCircle extends StatelessWidget {
  const _SendCircle({required this.ready, required this.brand});
  final bool ready;
  final BrandColors brand;

  static const size = 36.0;
  static const turn = Duration(milliseconds: 180);

  @override
  Widget build(BuildContext context) => Center(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: ready ? 1 : 0),
          // Even with less motion asked for: see [fullTime].
          duration: fullTime(turn),
          curve: Curves.easeOut,
          builder: (_, t, __) => Ink(
            width: size,
            height: size,
            decoration: BoxDecoration(color: Color.lerp(Palette.fill, brand.primary, t), shape: BoxShape.circle),
            child: Icon(Icons.arrow_upward, size: 20, color: Color.lerp(Palette.faint, brand.onPrimary, t)),
          ),
        ),
      );
}

/// The message box's look, for the real composer and the locked one alike.
InputDecoration _composerDecoration(BrandColors brand, String hint, {bool enabled = true}) => InputDecoration(
      hintText: hint,
      // One line at any text size: a hint that wrapped held the box two
      // lines tall for one line of text.
      hintMaxLines: 1,
      hintStyle: const TextStyle(color: Palette.hint),
      isDense: true,
      filled: true,
      fillColor: Palette.input,
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Palette.border)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Palette.border)),
      disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: const BorderSide(color: Palette.border)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: brand.primary)),
    );

/// The composer while typing waits on something above — a button to
/// choose, a detail to give, the thread to load: the same box, saying what
/// it waits for, that takes nothing. Not a text field: no keyboard, no focus.
class _LockedComposer extends StatelessWidget {
  const _LockedComposer({required this.hint});
  final String hint;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final theme = Theme.of(context);
    // The text a TextField would type in, so the box is the same height.
    final style = (theme.useMaterial3 ? theme.textTheme.bodyLarge : theme.textTheme.titleMedium)!.merge(fieldText);
    return ExcludeFocus(
      child: Container(
        padding: EdgeInsets.fromLTRB(8, 8, 10, 8 + MediaQuery.paddingOf(context).bottom),
        decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Palette.border))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const _PhotoButton(onTap: null),
            Expanded(
              child: InputDecorator(
                decoration: _composerDecoration(brand, hint, enabled: false),
                baseStyle: style,
                isEmpty: true,
                child: Text(' ', style: style, maxLines: 1),
              ),
            ),
            const SizedBox(width: 6),
            ExcludeSemantics(
              child: Material(
                type: MaterialType.transparency,
                child: SizedBox(
                  width: RoundIconButton.minTarget,
                  height: RoundIconButton.minTarget,
                  child: _SendCircle(ready: false, brand: brand),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
