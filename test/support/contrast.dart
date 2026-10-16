import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// The messenger's contrast, measured on what is on screen (0.4.9): every
// word, icon and field border, against what is painted behind it there —
// not against white, which is what a design assumes and a phone does not
// show. Behind is found by walking up from the mark to the first opaque
// paint, laying every see-through one between on it in order; a Stack's
// earlier children count, where they cover the mark (Home's brand band
// under its greeting); a gradient is read at the mark.

/// What a mark on screen is held to (WCAG 2.2: 1.4.6 for the words of a
/// message, 1.4.3 for other words, 1.4.11 for the rest).
enum MarkKind { message, text, icon, border, focus }

class Mark {
  Mark({required this.screen, required this.platform, required this.kind, required this.what, required this.fg, required this.bg, this.exempt});

  final String screen;
  final String platform;
  final MarkKind kind;
  final String what;
  final Color fg;
  final Color bg;

  /// Why it is not held to a target (an inactive control), or null.
  final String? exempt;

  double get ratio => contrastRatio(fg, bg);

  double get target => switch (kind) {
        MarkKind.message => 7,
        MarkKind.text => 4.5,
        _ => 3,
      };

  bool get passes => exempt != null || ratio >= target;

  @override
  String toString() => '$screen/$platform ${kind.name} "$what" ${hex(fg)} on ${hex(bg)}: ${ratio.toStringAsFixed(2)} (needs $target)';
}

/// WCAG contrast of [fg] over [bg]; a see-through [fg] is laid on [bg] first.
double contrastRatio(Color fg, Color bg) {
  final a = Color.alphaBlend(fg, bg).computeLuminance();
  final b = bg.computeLuminance();
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

/// `#RRGGBB`, or `#AARRGGBB` when see-through. (toARGB32: Flutter 3.27 on;
/// the tests run on the Mac's Flutter, not the apps' floor.)
String hex(Color c) {
  final v = c.toARGB32();
  final rgb = (v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
  final a = v >>> 24;
  return a == 0xFF ? '#$rgb' : '#${a.toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
}

/// Every mark on screen now, as [screen] on [platform].
List<Mark> auditScreen(WidgetTester tester, {required String screen, required String platform}) {
  final view = Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  final marks = <Mark>[];

  for (final e in find.byType(RichText).evaluate()) {
    final r = e.renderObject;
    if (r is! RenderParagraph || !r.attached || !r.hasSize || r.size.isEmpty) continue;
    final rect = r.localToGlobal(Offset.zero) & r.size;
    if (!rect.overlaps(view)) continue;
    if (_opacity(e) < 0.99) continue; // a placeholder holding room, or on its way in or out
    final icon = _iconAbove(e);
    final bg = backgroundAt(e, rect.center);
    final rich = e.widget as RichText;
    if (icon != null) {
      final color = rich.text.style?.color;
      if (color == null) continue;
      marks.add(Mark(
        screen: screen,
        platform: platform,
        kind: MarkKind.icon,
        what: _iconName(icon),
        fg: color,
        bg: bg,
        exempt: _inactive(e) ? 'inactive control' : null,
      ));
      continue;
    }
    final message = _isMessage(e);
    for (final (text, color) in _runs(rich.text, null)) {
      if (_emojiOnly(text)) continue; // a picture, not ink
      marks.add(Mark(screen: screen, platform: platform, kind: message ? MarkKind.message : MarkKind.text, what: _short(text), fg: color, bg: bg));
    }
  }

  for (final e in find.byType(EditableText).evaluate()) {
    final w = e.widget as EditableText;
    final r = e.findRenderObject();
    if (r is! RenderBox || !r.hasSize || w.controller.text.isEmpty) continue;
    final color = w.style.color;
    if (color == null) continue;
    final rect = r.localToGlobal(Offset.zero) & r.size;
    marks.add(Mark(screen: screen, platform: platform, kind: MarkKind.text, what: 'typed: ${_short(w.controller.text)}', fg: color, bg: backgroundAt(e, rect.center)));
  }

  for (final e in find.byType(InputDecorator).evaluate()) {
    final w = e.widget as InputDecorator;
    final r = e.findRenderObject();
    if (r is! RenderBox || !r.hasSize) continue;
    final rect = r.localToGlobal(Offset.zero) & r.size;
    if (!rect.overlaps(view) || _opacity(e) < 0.99) continue;
    final d = w.decoration;
    final hint = d.hintText ?? d.labelText ?? 'field';
    // Outside the field: what is behind it, without its own fill.
    Element? parent;
    e.visitAncestorElements((a) {
      parent = a;
      return false;
    });
    final outside = parent == null ? null : backgroundAt(parent!, rect.center);
    final fill = d.filled == true ? (d.fillColor ?? Colors.transparent) : null;
    final enabled = d.enabled;
    final focused = w.isFocused;
    final shown = !enabled ? d.disabledBorder : (focused ? d.focusedBorder : d.enabledBorder);
    final border = shown ?? d.border;
    final side = border == null || border == InputBorder.none ? BorderSide.none : border.borderSide;
    final theme = Theme.of(e);
    Color? ink;
    var name = hint;
    if (side.style == BorderStyle.none) {
      // No line: the field's own fill is its edge.
      if (fill == null) continue;
      ink = fill;
      name = '$hint (fill, no border)';
    } else if (shown == null) {
      // A theme's default line (Material 3: outline; primary when focused).
      ink = focused ? theme.colorScheme.primary : theme.colorScheme.outline;
      name = '$hint (theme default)';
    } else {
      ink = side.color;
    }
    final behind = outside ?? Colors.white;
    var ratio = contrastRatio(ink, behind);
    var against = behind;
    // A line between two colours is read against both.
    if (fill != null && side.style != BorderStyle.none) {
      final inside = Color.alphaBlend(fill, behind);
      if (contrastRatio(ink, inside) < ratio) {
        ratio = contrastRatio(ink, inside);
        against = inside;
      }
    }
    marks.add(Mark(
      screen: screen,
      platform: platform,
      kind: focused ? MarkKind.focus : MarkKind.border,
      what: name,
      fg: ink,
      bg: against,
      exempt: enabled ? null : 'inactive control',
    ));
  }
  return marks;
}

/// What is painted behind [e] at [point]: its ancestors' paint and, at a
/// Stack, its earlier children's, laid one on another from the first that
/// is opaque. White if nothing is (the app's own screen is not ours).
Color backgroundAt(Element e, Offset point) {
  final layers = <Color>[]; // nearest the mark first
  final own = _paints(e, point);
  if (own != null) layers.add(own);
  var below = e;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Stack) {
      final earlier = <Element>[];
      var found = false;
      a.visitChildren((child) {
        if (identical(child, below)) found = true;
        if (!found) earlier.add(child);
      });
      for (final sibling in earlier.reversed) {
        final under = <Color>[];
        _collect(sibling, point, 1, under);
        layers.addAll(under.reversed);
      }
    }
    final c = _paints(a, point);
    if (c != null) layers.add(c);
    below = a;
    return true;
  });
  final opaque = layers.indexWhere((c) => _alpha(c) == 255);
  var bg = opaque < 0 ? Colors.white : layers[opaque];
  for (var i = (opaque < 0 ? layers.length : opaque) - 1; i >= 0; i--) {
    bg = Color.alphaBlend(layers[i], bg);
  }
  return bg;
}

int _alpha(Color c) => c.toARGB32() >>> 24;

/// The paint under [e]'s subtree at [point], in the order it is painted.
void _collect(Element e, Offset point, double opacity, List<Color> out) {
  final w = e.widget;
  if (w is Offstage && w.offstage) return;
  var o = opacity;
  if (w is Opacity) o *= w.opacity;
  if (w is FadeTransition) o *= w.opacity.value;
  if (o < 0.01) return;
  final c = _paints(e, point);
  if (c != null) {
    final r = e.renderObject;
    if (r is RenderBox && r.hasSize && (r.localToGlobal(Offset.zero) & r.size).contains(point)) {
      out.add(o >= 0.999 ? c : c.withAlpha((_alpha(c) * o).round()));
    }
  }
  e.visitChildren((child) => _collect(child, point, o, out));
}

/// The colour [e]'s own widget paints under its child at [point], if any.
Color? _paints(Element e, Offset point) {
  final w = e.widget;
  Rect? rect() {
    final r = e.renderObject;
    return r is RenderBox && r.hasSize && r.attached ? r.localToGlobal(Offset.zero) & r.size : null;
  }

  Color? decorated(Decoration? d) {
    if (d is BoxDecoration) return d.gradient != null ? _sample(d.gradient!, rect(), point) : d.color;
    if (d is ShapeDecoration) return d.gradient != null ? _sample(d.gradient!, rect(), point) : d.color;
    return null;
  }

  if (w is ColoredBox) return w.color;
  if (w is DecoratedBox && w.position == DecorationPosition.background) return decorated(w.decoration);
  if (w is Ink) return decorated(w.decoration);
  if (w is Material) {
    if (w.type == MaterialType.transparency) return null;
    return w.color ?? (w.type == MaterialType.card ? Theme.of(e).cardColor : Theme.of(e).canvasColor);
  }
  if (w is InputDecorator && w.decoration.filled == true) return w.decoration.fillColor;
  return null;
}

/// A gradient's colour at [point] of [rect].
Color? _sample(Gradient g, Rect? rect, Offset point) {
  if (g is! LinearGradient || rect == null) return g.colors.first;
  final begin = g.begin.resolve(TextDirection.ltr).withinRect(rect);
  final end = g.end.resolve(TextDirection.ltr).withinRect(rect);
  final axis = end - begin;
  final t = axis.distanceSquared == 0 ? 0.0 : (((point - begin).dx * axis.dx + (point - begin).dy * axis.dy) / axis.distanceSquared).clamp(0.0, 1.0);
  final stops = g.stops ?? <double>[for (var i = 0; i < g.colors.length; i++) g.colors.length == 1 ? 0 : i / (g.colors.length - 1)];
  for (var i = 0; i < stops.length - 1; i++) {
    if (t <= stops[i + 1]) {
      final span = stops[i + 1] - stops[i];
      return Color.lerp(g.colors[i], g.colors[i + 1], span == 0 ? 0 : (t - stops[i]) / span);
    }
  }
  return g.colors.last;
}

/// Every opacity above [e], multiplied.
double _opacity(Element e) {
  var o = 1.0;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Opacity) o *= w.opacity;
    if (w is FadeTransition) o *= w.opacity.value;
    if (w is Offstage && w.offstage) o = 0;
    if (w is ScaleTransition && w.scale.value == 0) o = 0; // scaled away (the tab's count at 0)
    return o > 0;
  });
  return o;
}

/// The Icon a glyph is drawn for, if it is one's.
Icon? _iconAbove(Element e) {
  Icon? found;
  var depth = 0;
  e.visitAncestorElements((a) {
    if (a.widget is Icon) found = a.widget as Icon;
    return found == null && ++depth < 6;
  });
  return found;
}

String _iconName(Icon icon) {
  final cp = icon.icon?.codePoint;
  return _iconNames[cp] ?? 'icon U+${cp?.toRadixString(16)}';
}

final _iconNames = <int?, String>{
  Icons.close.codePoint: 'close',
  Icons.chevron_left.codePoint: 'back',
  Icons.chevron_right.codePoint: 'chevron',
  Icons.send.codePoint: 'send',
  Icons.search.codePoint: 'search',
  Icons.arrow_upward.codePoint: 'send arrow',
  Icons.arrow_downward.codePoint: 'arrow down',
  Icons.add_photo_alternate_outlined.codePoint: 'photo button',
  Icons.attach_file.codePoint: 'file',
  Icons.description_outlined.codePoint: 'article',
  Icons.open_in_new.codePoint: 'open outside',
  Icons.home_outlined.codePoint: 'Home tab',
  Icons.home.codePoint: 'Home tab (selected)',
  Icons.chat_bubble_outline.codePoint: 'Messages tab',
  Icons.chat_bubble.codePoint: 'Messages tab (selected)',
  Icons.help_outline.codePoint: 'Help tab',
  Icons.help.codePoint: 'Help tab (selected)',
  Icons.mail_outline.codePoint: 'mail',
  Icons.smart_toy_outlined.codePoint: 'AI',
  Icons.person_outline.codePoint: 'person',
  Icons.forum_outlined.codePoint: 'forum',
  Icons.check.codePoint: 'check',
  Icons.text_fields.codePoint: 'text size',
  Icons.format_size.codePoint: 'text size',
};

/// A control that cannot be used now (Send with nothing typed, the photo
/// button while the workflow waits): exempt, as WCAG has it.
bool _inactive(Element e) {
  var inactive = false;
  var depth = 0;
  e.visitAncestorElements((a) {
    final w = a.widget;
    // The composer while the workflow waits: nothing in it can be used.
    if (w.runtimeType.toString() == '_LockedComposer') {
      inactive = true;
      return false;
    }
    if (w is InkWell) {
      inactive = w.onTap == null;
      return false;
    }
    if (w is ButtonStyleButton) {
      inactive = !w.enabled;
      return false;
    }
    return ++depth < 40;
  });
  return inactive;
}

/// The words of a message: in a bubble, and not a card or file in it.
bool _isMessage(Element e) {
  var inBubble = false;
  var other = false;
  e.visitAncestorElements((a) {
    final type = a.widget.runtimeType.toString();
    if (type == '_InBubbleCard' || type == '_FileChip' || type == '_AttachmentView') other = true;
    if (type == '_BubbleBox') {
      inBubble = true;
      return false;
    }
    return true;
  });
  return inBubble && !other;
}

/// Each run of [span] with words, and its colour.
List<(String, Color)> _runs(InlineSpan span, TextStyle? parent) {
  final out = <(String, Color)>[];
  if (span is! TextSpan) return out;
  final style = parent == null ? span.style : parent.merge(span.style);
  final text = span.text;
  final color = style?.color;
  if (text != null && text.trim().isNotEmpty && color != null) out.add((text, color));
  for (final child in span.children ?? const <InlineSpan>[]) {
    out.addAll(_runs(child, style));
  }
  return out;
}

bool _emojiOnly(String s) => s.runes.every((r) => r == 0x20 || r == 0xFE0F || r == 0x200D || r >= 0x1F000 || (r >= 0x2600 && r <= 0x27BF));

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.length <= 38 ? one : '${one.substring(0, 36)}…';
}

/// The marks as a Markdown table: one row for each mark that differs in
/// what it is, its colours or its kind, worst first within a screen.
String contrastTable(List<Mark> marks, {String title = ''}) {
  final rows = <String, ({Mark mark, Set<String> platforms})>{};
  for (final m in marks) {
    final key = '${m.screen}|${m.kind.name}|${m.what}|${hex(m.fg)}|${hex(m.bg)}';
    final had = rows[key];
    if (had == null) {
      rows[key] = (mark: m, platforms: <String>{m.platform});
    } else {
      had.platforms.add(m.platform);
    }
  }
  final screens = <String>[];
  for (final m in marks) {
    if (!screens.contains(m.screen)) screens.add(m.screen);
  }
  final b = StringBuffer();
  if (title.isNotEmpty) b.writeln('## $title\n');
  final failing = marks.where((m) => !m.passes).length;
  b.writeln('${marks.length} marks measured, $failing under their target.\n');
  b.writeln('| Screen | Kind | What | Ink | Behind | Ratio | Needs | | Platforms |');
  b.writeln('|---|---|---|---|---|---:|---:|---|---|');
  for (final s in screens) {
    final here = rows.values.where((r) => r.mark.screen == s).toList()
      ..sort((a, b) {
        final pass = (a.mark.passes ? 1 : 0) - (b.mark.passes ? 1 : 0);
        if (pass != 0) return pass;
        return (a.mark.ratio / a.mark.target).compareTo(b.mark.ratio / b.mark.target);
      });
    for (final r in here) {
      final m = r.mark;
      final verdict = m.exempt != null ? 'exempt (${m.exempt})' : (m.passes ? 'ok' : '**FAILS**');
      b.writeln('| ${m.screen} | ${m.kind.name} | ${m.what.replaceAll('|', '\\|')} | ${hex(m.fg)} | ${hex(m.bg)} | ${m.ratio.toStringAsFixed(2)} | ${m.target} | $verdict | ${(r.platforms.toList()..sort()).join(', ')} |');
    }
  }
  return b.toString();
}

/// Writes [text] to [path], making its folder.
void writeReport(String path, String text) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(text);
}
