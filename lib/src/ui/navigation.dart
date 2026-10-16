import 'package:flutter/material.dart';

import '../api/models.dart';
import 'article.dart';
import 'common.dart';
import 'conversation.dart';
import 'sheet.dart';
import 'text_size.dart';

/// A route for a messenger screen. It sits outside the subtree that holds the
/// scope, so the scope and theme travel with it; its name keeps it among the
/// screens "close" pops. In the messenger's sheet it is drawn in the sheet
/// (see [messengerPageRoute]).
///
/// On an iPhone it is a Cupertino route whatever transitions the app's theme
/// chose, so a swipe from the left edge steps back, as in every iOS app.
/// [instant]: there at once, without sliding in — opened as the sheet rises.
Route<void> _route(BuildContext context, String name, Widget page, {bool instant = false}) {
  final scope = MessengerScope.of(context);
  final theme = Theme.of(context);
  final sheet = MessengerSheet.maybeOf(context);
  Widget build(BuildContext _) {
    final screen = MessengerScope(
      controller: scope.controller,
      fallback: scope.fallback,
      child: Theme(data: theme, child: MessengerTextScale(child: page)),
    );
    return sheet == null ? screen : sheet.wrap(screen);
  }

  return messengerPageRoute(
    settings: RouteSettings(name: '$messengerRoutePrefix/$name'),
    builder: build,
    cupertino: theme.platform == TargetPlatform.iOS,
    sheet: sheet,
    instant: instant,
  );
}

Future<void> pushMessengerPage(BuildContext context, String name, Widget page, {bool instant = false}) =>
    Navigator.of(context).push(_route(context, name, page, instant: instant));

/// The open conversation — or a new one, when there is none yet.
Future<void> openLiveConversation(BuildContext context, {bool instant = false}) =>
    pushMessengerPage(context, 'conversation', const ConversationPage(), instant: instant);

/// From a past conversation to the live one, without stacking the two.
Future<void> replaceWithLiveConversation(BuildContext context) =>
    Navigator.of(context).pushReplacement(_route(context, 'conversation', const ConversationPage()));

/// A row of the Messages list: the live thread when it is the open one,
/// otherwise that conversation as it stands (closed ones are read-only).
Future<void> openConversation(BuildContext context, ConversationSummary c, {bool instant = false}) {
  if (c.id == context.messenger.liveId) return openLiveConversation(context, instant: instant);
  return pushMessengerPage(context, 'conversation', ConversationPage(conversationId: c.id), instant: instant);
}

Future<void> openArticle(BuildContext context, String slug, {String? title, bool instant = false}) =>
    pushMessengerPage(context, 'article', ArticlePage(slug: slug, title: title), instant: instant);
