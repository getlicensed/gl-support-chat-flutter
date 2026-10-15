import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../api/models.dart';
import 'common.dart';
import 'navigation.dart';

/// One help-centre article, drawn natively. The HTML comes from the help
/// centre already sanitised (DOMPurify, the same as the public /help pages);
/// every link opens outside the messenger.
///
/// An article read before, or one of the five Home shows (fetched ahead),
/// is there at once. Otherwise three skeleton bars stand for it, and it
/// comes in with a 200 ms fade as it rises 8 points.
class ArticlePage extends StatefulWidget {
  const ArticlePage({super.key, required this.slug, this.title});

  final String slug;
  final String? title;

  static const fadeIn = Duration(milliseconds: 200);
  static const rise = 8.0;

  @override
  State<ArticlePage> createState() => _ArticlePageState();
}

class _ArticlePageState extends State<ArticlePage> {
  Future<Article>? _article;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _article ??= context.messenger.article(widget.slug);
  }

  // A block, not an arrow: setState refuses a callback that returns the Future.
  void _reload() {
    setState(() {
      _article = context.messenger.article(widget.slug);
    });
  }

  @override
  Widget build(BuildContext context) => AnnotatedRegion<SystemUiOverlayStyle>(value: statusBarStyle(darkIcons: true), child: _page(context));

  Widget _page(BuildContext context) {
    final c = context.messenger;
    final motion = !MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FutureBuilder<Article>(
          future: _article,
          initialData: c.cachedArticle(widget.slug),
          builder: (context, snap) {
            final a = snap.data;
            final title = a?.title ?? widget.title ?? '';
            final Widget body;
            if (a != null) {
              body = _ArticleBody(key: const ValueKey<String>('article'), article: a);
            } else if (snap.hasError) {
              body = Center(
                key: const ValueKey<String>('error'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This article could not be loaded.', style: TextStyle(fontSize: 14, color: Palette.muted)),
                    TextButton(onPressed: _reload, child: const Text('Try again')),
                  ],
                ),
              );
            } else {
              body = const ArticleSkeleton(key: ValueKey<String>('skeleton'));
            }
            return Column(
              children: [
                Container(
                  // The buttons' 44-point touch areas reach 5 points past
                  // their circles; the padding gives that back, so the
                  // circles sit where they always did.
                  padding: const EdgeInsets.fromLTRB(9, 5, 9, 5),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F3F4)))),
                  child: Row(
                    children: [
                      RoundIconButton(icon: Icons.chevron_left, tooltip: 'Back', size: 34, onTap: () => Navigator.of(context).maybePop()),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.text)),
                      ),
                      const SizedBox(width: 5),
                      RoundIconButton(icon: Icons.close, tooltip: 'Close', size: 34, onTap: () => closeMessenger(context)),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: motion ? ArticlePage.fadeIn : Duration.zero,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
                    transitionBuilder: (child, t) => FadeTransition(
                      opacity: t,
                      child: AnimatedBuilder(
                        animation: t,
                        child: child,
                        builder: (_, child) => Transform.translate(offset: Offset(0, ArticlePage.rise * (1 - t.value)), child: child),
                      ),
                    ),
                    child: body,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Three shimmering bars where the article will be: its title, then two
/// lines of its first paragraph.
class ArticleSkeleton extends StatelessWidget {
  const ArticleSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading the article',
      child: Shimmer(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 28),
          child: LayoutBuilder(
            builder: (context, box) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBar(width: box.maxWidth * 0.72, height: 20),
                const SizedBox(height: 22),
                SkeletonBar(width: box.maxWidth * 0.94, height: 12),
                const SizedBox(height: 14),
                SkeletonBar(width: box.maxWidth * 0.6, height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Intercom's article buttons came over to the help centre as paragraphs
/// holding nothing but a link (71 of 228 articles): such a paragraph is
/// drawn as the button it was. Its link, or null for any other element.
/// ([element] is the HTML package's element, as the HTML widget hands it
/// over; that package is not one of ours to name.)
({String label, Uri url})? loneLink(dynamic element) {
  if (element.localName != 'p') return null;
  final links = element.querySelectorAll('a') as List<dynamic>;
  if (links.length != 1) return null;
  final link = links.single;
  final href = link.attributes['href'];
  final label = '${link.text}'.replaceAll('​', '').trim();
  if (href is! String || label.isEmpty) return null;
  // Nothing beside the link: no words, no picture.
  if ('${element.text}'.replaceAll('​', '').trim() != label) return null;
  if ((element.querySelectorAll('img') as List<dynamic>).isNotEmpty) return null;
  final url = Uri.tryParse(href.trim());
  if (url == null || !url.hasScheme) return null;
  return (label: label, url: url);
}

/// The help centre's HTML, tidied: the line break and zero-width space
/// Intercom left at the end of a paragraph or list item would draw an empty
/// line beneath it.
String tidyArticleHtml(String html) => html.replaceAll(RegExp(r'(?:<br\s*/?>|​|\s)+(?=</(?:p|li)>)', caseSensitive: false), '');

class _ArticleBody extends StatelessWidget {
  const _ArticleBody({super.key, required this.article});
  final Article article;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    final a = article;
    final url = a.url;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
      children: [
        Text(a.title, style: const TextStyle(fontSize: 22, height: 1.25, fontWeight: FontWeight.w700, color: Palette.text)),
        if ((a.description ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(a.description!, style: const TextStyle(fontSize: 15, height: 1.5, color: Palette.muted)),
        ],
        const SizedBox(height: 18),
        HtmlWidget(
          tidyArticleHtml(a.html),
          textStyle: const TextStyle(fontSize: 15, height: 1.65, color: Palette.prose),
          onTapUrl: (href) async {
            final uri = Uri.tryParse(href);
            if (uri != null) await openExternal(context, uri);
            return true;
          },
          customWidgetBuilder: (element) {
            final link = loneLink(element);
            if (link == null) return null;
            return ArticleButton(label: link.label, onTap: () => openExternal(context, link.url));
          },
          customStylesBuilder: (element) {
            switch (element.localName) {
              case 'a':
                return <String, String>{'color': brand.hex, 'text-decoration': 'underline'};
              // Smaller than the article's 22-point title, as headings
              // inside it should be (they were about 30).
              case 'h1':
                return <String, String>{'color': '#111827', 'font-weight': '700', 'font-size': '20px', 'line-height': '1.3', 'margin': '22px 0 8px'};
              case 'h2':
                return <String, String>{'color': '#111827', 'font-weight': '700', 'font-size': '18px', 'line-height': '1.35', 'margin': '20px 0 8px'};
              case 'h3':
                return <String, String>{'color': '#111827', 'font-weight': '600', 'font-size': '16px', 'line-height': '1.4', 'margin': '18px 0 6px'};
              case 'h4':
              case 'h5':
              case 'h6':
                return <String, String>{'color': '#111827', 'font-weight': '600', 'font-size': '15px', 'margin': '16px 0 6px'};
              // A list item's paragraph took a paragraph's margins: a gap
              // under every item.
              case 'p':
                return element.parent?.localName == 'li' ? <String, String>{'margin': '0'} : null;
              case 'li':
                return <String, String>{'margin': '0 0 6px'};
              case 'blockquote':
                return <String, String>{'border-left': '3px solid #e5e7eb', 'padding': '8px 14px', 'color': '#4b5563', 'margin': '0 0 12px'};
              case 'pre':
              case 'code':
                return <String, String>{'background-color': '#f3f4f6', 'font-size': '13px'};
              case 'td':
              case 'th':
                return <String, String>{'border': '1px solid #e5e7eb', 'padding': '6px 8px'};
            }
            return null;
          },
        ),
        const SizedBox(height: 28),
        ArticleReactions(slug: a.slug),
        if (url != null) ...[
          const SizedBox(height: 20),
          Center(
            child: TextButton(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                minimumSize: const Size(RoundIconButton.minTarget, RoundIconButton.minTarget),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => openExternal(context, Uri.parse(url)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Wraps rather than overflow at a large text size.
                  Flexible(child: Text('Open in the help centre', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: brand.primary))),
                  const SizedBox(width: 4),
                  Icon(Icons.open_in_new, size: 14, color: brand.primary),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A button in an article, in the brand colour: what Intercom drew for an
/// article's call to action. It opens its link outside, as every link does.
class ArticleButton extends StatelessWidget {
  const ArticleButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: brand.primary,
            foregroundColor: brand.onPrimary,
            minimumSize: const Size(RoundIconButton.minTarget, RoundIconButton.minTarget),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            // The app's typeface, as the rest of the messenger.
            textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 15, height: 1.3, fontWeight: FontWeight.w600),
          ),
          onPressed: onTap,
          child: Text(label, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

/// Under an article: "Did this answer your question?" and three faces. The
/// one tapped grows, the others fade back; another tap changes it. Kept for
/// the article while the customer is signed in, and sent to the team's
/// reports. After 😞, a way to ask the team instead.
class ArticleReactions extends StatelessWidget {
  const ArticleReactions({super.key, required this.slug});
  final String slug;

  static const faces = <(String, String, String)>[
    ('sad', '😞', 'Disappointed'),
    ('neutral', '😐', 'Neutral'),
    ('happy', '😃', 'Smiley'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.messenger;
    final brand = c.brand;
    final chosen = c.reactions[slug];
    return Container(
      padding: const EdgeInsets.only(top: 22),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: Palette.border))),
      child: Column(
        children: [
          const Text('Did this answer your question?', textAlign: TextAlign.center, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Palette.text)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final (value, emoji, label) in faces)
                _Face(
                  emoji: emoji,
                  label: label,
                  chosen: chosen == value,
                  faded: chosen != null && chosen != value,
                  onTap: () => c.react(slug, value),
                ),
            ],
          ),
          Reveal(
            shown: chosen == 'sad',
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Column(
                children: [
                  const Text('Still need help?', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Palette.muted)),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: brand.primary,
                      foregroundColor: brand.onPrimary,
                      minimumSize: const Size(RoundIconButton.minTarget, RoundIconButton.minTarget),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () => openLiveConversation(context),
                    icon: const Icon(Icons.send, size: 16),
                    label: const Text('Send us a message'),
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

/// One face to tap: 56 points square, named for a screen reader.
class _Face extends StatelessWidget {
  const _Face({required this.emoji, required this.label, required this.chosen, required this.faded, required this.onTap});

  final String emoji;
  final String label;
  final bool chosen;
  final bool faded;
  final VoidCallback onTap;

  static const time = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final time = MediaQuery.disableAnimationsOf(context) ? Duration.zero : _Face.time;
    return Semantics(
      button: true,
      selected: chosen,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 56,
          height: 56,
          child: Center(
            child: AnimatedScale(
              scale: chosen ? 1.3 : 1,
              duration: time,
              curve: Curves.easeOutBack,
              child: AnimatedOpacity(
                opacity: faded ? 0.4 : 1,
                duration: time,
                child: Text(emoji, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
