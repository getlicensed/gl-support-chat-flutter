import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../api/models.dart';
import 'common.dart';

/// One help-centre article, drawn natively. The HTML comes from the help
/// centre already sanitised (DOMPurify, the same as the public /help pages);
/// every link opens outside the messenger.
class ArticlePage extends StatefulWidget {
  const ArticlePage({super.key, required this.slug, this.title});

  final String slug;
  final String? title;

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

  void _reload() => setState(() => _article = context.messenger.article(widget.slug));

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: FutureBuilder<Article>(
          future: _article,
          builder: (context, snap) {
            final a = snap.data;
            final title = a?.title ?? widget.title ?? '';
            Widget body;
            if (snap.hasError) {
              body = Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('This article could not be loaded.', style: TextStyle(fontSize: 14, color: Palette.faint)),
                    TextButton(onPressed: _reload, child: const Text('Try again')),
                  ],
                ),
              );
            } else if (a == null) {
              body = const Center(child: Text('Loading…', style: TextStyle(fontSize: 14, color: Palette.faint)));
            } else {
              final url = a.url;
              body = ListView(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
                children: [
                  Text(a.title, style: const TextStyle(fontSize: 22, height: 1.25, fontWeight: FontWeight.w700, color: Palette.text)),
                  if ((a.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(a.description!, style: const TextStyle(fontSize: 15, height: 1.5, color: Palette.muted)),
                  ],
                  const SizedBox(height: 18),
                  HtmlWidget(
                    a.html,
                    textStyle: const TextStyle(fontSize: 15, height: 1.65, color: Palette.prose),
                    onTapUrl: (href) async {
                      final uri = Uri.tryParse(href);
                      if (uri != null) await openExternal(context, uri);
                      return true;
                    },
                    customStylesBuilder: (element) {
                      switch (element.localName) {
                        case 'a':
                          return <String, String>{'color': brand.hex, 'text-decoration': 'underline'};
                        case 'h1':
                        case 'h2':
                        case 'h3':
                        case 'h4':
                          return <String, String>{'color': '#111827', 'font-weight': '600', 'margin': '22px 0 8px'};
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
                  if (url != null) ...[
                    const SizedBox(height: 18),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero),
                        onPressed: () => openExternal(context, Uri.parse(url)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('Open in the help centre', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: brand.primary)),
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
            return Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F3F4)))),
                  child: Row(
                    children: [
                      RoundIconButton(icon: Icons.chevron_left, tooltip: 'Back', size: 34, onTap: () => Navigator.of(context).maybePop()),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Palette.text)),
                      ),
                      const SizedBox(width: 10),
                      RoundIconButton(icon: Icons.close, tooltip: 'Close', size: 34, onTap: () => closeMessenger(context)),
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            );
          },
        ),
      ),
    );
  }
}
