import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api/models.dart';
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

  bool get _live => widget.conversationId == null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final c = context.messenger;
    _controller = c;
    if (_live) {
      // After this frame: the controller notifies, and the tree is building.
      WidgetsBinding.instance.addPostFrameCallback((_) => c.setViewingLive(true));
    } else {
      _past = c.loadConversation(widget.conversationId!);
    }
  }

  @override
  void dispose() {
    if (_live) _controller?.setViewingLive(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          _Header(live: _live),
          if (_live) const ConnectionBar(),
          Expanded(
            child: _live
                ? _Thread(rows: _liveRows(context, c))
                : FutureBuilder<ConversationDetail>(
                    future: _past,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return const Center(child: Text('This conversation could not be loaded.', style: TextStyle(color: Palette.muted)));
                      }
                      final d = snap.data;
                      if (d == null) return const Center(child: CircularProgressIndicator());
                      return _Thread(rows: _messageRows(context, c, d.messages.where((m) => !m.isSystem).toList(), agentSeenAt: d.agentLastSeenAt));
                    },
                  ),
          ),
          if (_live) const _LiveFooter() else _PastFooter(conversationId: widget.conversationId!, past: _past),
        ],
      ),
    );
  }
}

// ==========================================================================
// What the thread shows, top to bottom
// ==========================================================================

List<Widget> _liveRows(BuildContext context, MessengerController c) {
  final rows = <Widget>[];
  final label = c.session?.productLabel ?? '';
  if (c.live.isEmpty) {
    final pendingCsat = c.pendingCsatRatingId;
    if (pendingCsat != null) {
      rows.add(CsatCard(
        ratingId: pendingCsat,
        title: label.isEmpty ? 'How did we do? Rate your last conversation.' : 'How did we do? Rate your last conversation with $label.',
      ));
    }
    final preview = c.preview;
    if (preview != null) {
      rows.add(_AuthorRow(authorType: 'bot', name: label, time: c.previewShownAt ?? DateTime.now()));
      for (final m in preview.messages) {
        final meta = m.meta;
        if (m.body.trim().isNotEmpty || meta?.imageUrl != null || meta?.articleSlug != null || meta?.fileUrl != null) {
          rows.add(_Bubble(
            message: ChatMessage(id: '', conversationId: '', body: m.body, authorType: 'bot', createdAt: DateTime.now(), meta: meta),
          ));
        }
        if (meta != null && meta.buttons.isNotEmpty) {
          rows.add(_FlowButtons(buttons: meta.buttons, onTap: c.startWorkflow));
        }
      }
    } else if (c.agentTyping) {
      rows.add(const _TypingRow());
    } else {
      rows.add(const _IntroAndChips());
    }
  } else {
    rows.addAll(_messageRows(context, c, c.live, agentSeenAt: c.agentSeenAt, divider: c.dividerIndex, livePrompt: c.livePrompt));
    if (c.agentTyping) rows.add(const _TypingRow());
  }
  final notice = c.flowNotice;
  if (notice != null) rows.add(_ErrorLine(notice));
  for (final out in c.outgoing) {
    rows.add(_OutgoingBubble(out: out));
  }
  return rows;
}

List<Widget> _messageRows(
  BuildContext context,
  MessengerController c,
  List<ChatMessage> messages, {
  DateTime? agentSeenAt,
  int divider = -1,
  ChatMessage? livePrompt,
}) {
  final rows = <Widget>[];
  final label = c.session?.productLabel ?? '';
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (i == divider) rows.add(const _NewMessagesDivider());
    if (!m.fromVisitor) {
      final prev = i == 0 ? null : messages[i - 1];
      final startsGroup = prev == null || prev.fromVisitor || prev.authorType != m.authorType || prev.authorName != m.authorName;
      if (startsGroup) {
        rows.add(_AuthorRow(
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
      rows.add(_Bubble(
        message: m,
        seen: m.fromVisitor && agentSeenAt != null && !m.createdAt.isAfter(agentSeenAt),
      ));
    }
    final csat = meta?.csatRatingId;
    if (m.authorType == 'bot' && csat != null) rows.add(CsatCard(ratingId: csat, title: 'Tap a face'));
    if (livePrompt != null && identical(m, livePrompt)) {
      if (meta!.buttons.isNotEmpty) {
        rows.add(_FlowButtons(buttons: meta.buttons, onTap: (b) => c.choose(m, b)));
      } else if (meta.collect != null) {
        rows.add(_CollectBox(prompt: m, request: meta.collect!));
      }
    }
  }
  return rows;
}

/// The rows, newest at the bottom — and the list anchored there, so it opens
/// on the latest message and a new one never drags the reader down.
class _Thread extends StatelessWidget {
  const _Thread({required this.rows});
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[rows.length - 1 - i],
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
    final status = presenceLines(c.agentsOnline, s?.officeHours);
    final hasTeam = (s?.team ?? const []).isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [brand.primary, brand.hover]),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 14, 12),
          child: Row(
            children: [
              RoundIconButton(icon: Icons.chevron_left, tooltip: 'Back', light: true, size: 32, onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 10),
              if (hasTeam) const TeamFaces(size: 30, border: 1.5) else InitialAvatar(label: s?.productLabel ?? '?', size: 34),
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
                            decoration: BoxDecoration(color: status.away ? Palette.away : const Color(0xFF4ADE80), shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            live ? status.header : 'Conversation history',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: brand.onPrimary.withAlpha(190)),
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
    final c = context.messenger;
    final sendError = c.sendError;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.showEmailBar) const _EmailBar(),
        if (sendError != null && c.outgoing.isEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(16, 6, 16, 0), child: _ErrorLine(sendError)),
        const _Composer(),
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
    } else if (authorType == 'agent' && authorId != null && RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(authorId!)) {
      avatar = PersonAvatar(name: name, photoPath: '/widget/avatar/$authorId', size: 22);
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
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Palette.faint),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text with its links tappable (never HTML).
class _RichText extends StatelessWidget {
  const _RichText(this.text, {required this.color, required this.linkColor});
  final String text;
  final Color color;
  final Color linkColor;

  @override
  Widget build(BuildContext context) {
    final runs = linkify(text);
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 15, height: 1.45, color: color),
        children: [
          for (final r in runs)
            r.isLink
                ? WidgetSpan(
                    alignment: PlaceholderAlignment.baseline,
                    baseline: TextBaseline.alphabetic,
                    child: GestureDetector(
                      onTap: () => openExternal(context, Uri.parse(r.url!)),
                      child: Text(
                        r.text,
                        style: TextStyle(fontSize: 15, height: 1.45, color: linkColor, decoration: TextDecoration.underline, decorationColor: linkColor),
                      ),
                    ),
                  )
                : TextSpan(text: r.text),
        ],
      ),
    );
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
                  Text(_clock(context, m.createdAt), style: const TextStyle(fontSize: 11, color: Palette.faint)),
                  const SizedBox(width: 4),
                  // ✓ delivered, ✓✓ the team has read it.
                  Icon(seen ? Icons.done_all : Icons.done, size: 14, color: seen ? Palette.muted : Palette.faint, semanticLabel: seen ? 'Seen' : 'Delivered'),
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
      return FutureBuilder<Uint8List>(
        future: context.messenger.fileBytes(uploadId),
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes != null && bytes.isNotEmpty) return _Photo(image: MemoryImage(bytes));
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
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(child: Image(image: image)),
        ),
      ),
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file, size: 16, color: fg),
          const SizedBox(width: 4),
          Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: fg))),
        ],
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
            const Text('Sending…', style: TextStyle(fontSize: 11, color: Palette.faint))
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

class _TypingRow extends StatefulWidget {
  const _TypingRow();

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
    return Semantics(
      label: 'Typing',
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Row(
          children: [
            const InitialAvatar(label: '', size: 22, icon: Icons.person_outline),
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
              style: const TextStyle(fontSize: 13, color: Palette.faint),
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
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _value,
                  enabled: !c.flowBusy,
                  maxLength: 200,
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
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final (value, emoji, label) in _faces)
                  InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => c.rate(widget.ratingId, value),
                    child: Container(
                      width: 54,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: rating == value ? brand.light : null,
                        border: Border.all(color: rating == value ? brand.primary : Colors.transparent),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: [
                          Opacity(opacity: rating == null || rating == value ? 1 : 0.35, child: Text(emoji, style: const TextStyle(fontSize: 26))),
                          const SizedBox(height: 2),
                          Text(label, style: const TextStyle(fontSize: 11, color: Palette.muted)),
                        ],
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
              decoration: InputDecoration(
                hintText: 'Anything you would like to add? (optional)',
                counterText: '',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: brand.primary, width: 1.5)),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: brand.primary, foregroundColor: brand.onPrimary),
                onPressed: answer.commentState == 'sending' || _comment.text.trim().isEmpty ? null : () => c.comment(widget.ratingId, _comment.text),
                child: const Text('Send'),
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
  const _EmailBar();

  @override
  State<_EmailBar> createState() => _EmailBarState();
}

class _EmailBarState extends State<_EmailBar> {
  final _email = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
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
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _save(),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Your email for follow-up',
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
    c.send(value);
  }

  Future<void> _attach() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
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
    final online = c.link == LinkState.connected;
    final canSend = lock == null && online && _text.text.trim().isNotEmpty;
    return Container(
      padding: EdgeInsets.fromLTRB(8, 8, 10, 8 + MediaQuery.of(context).padding.bottom),
      decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Palette.border))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: 'Send a photo',
            onPressed: lock == null && online ? _attach : null,
            icon: Icon(Icons.add_photo_alternate_outlined, color: lock == null && online ? Palette.muted : Palette.border),
          ),
          Expanded(
            child: TextField(
              controller: _text,
              enabled: lock == null,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              keyboardType: TextInputType.multiline,
              onChanged: (v) {
                setState(() {});
                c.composerChanged(v);
              },
              decoration: InputDecoration(
                hintText: lock ?? 'Type a message…',
                isDense: true,
                filled: true,
                fillColor: lock == null ? Palette.input : Palette.fill,
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
                  width: 42,
                  height: 42,
                  child: Icon(Icons.arrow_upward, color: canSend ? brand.onPrimary : Palette.faint),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
