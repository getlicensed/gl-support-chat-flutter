import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../api/models.dart';
import 'article.dart';
import 'common.dart';
import 'conversation.dart';

/// A route for a messenger screen. It sits outside the subtree that holds the
/// scope, so the scope and theme travel with it; its name keeps it among the
/// screens "close" pops.
///
/// On an iPhone it is a Cupertino route whatever transitions the app's theme
/// chose, so a swipe from the left edge steps back, as in every iOS app.
Route<void> _route(BuildContext context, String name, Widget page) {
  final scope = MessengerScope.of(context);
  final theme = Theme.of(context);
  final settings = RouteSettings(name: '$messengerRoutePrefix/$name');
  Widget build(BuildContext _) => MessengerScope(
        controller: scope.controller,
        fallback: scope.fallback,
        child: Theme(data: theme, child: page),
      );
  if (theme.platform == TargetPlatform.iOS) return CupertinoPageRoute<void>(settings: settings, builder: build);
  return MaterialPageRoute<void>(settings: settings, builder: build);
}

Future<void> pushMessengerPage(BuildContext context, String name, Widget page) =>
    Navigator.of(context).push(_route(context, name, page));

/// The open conversation — or a new one, when there is none yet.
Future<void> openLiveConversation(BuildContext context) =>
    pushMessengerPage(context, 'conversation', const ConversationPage());

/// From a past conversation to the live one, without stacking the two.
Future<void> replaceWithLiveConversation(BuildContext context) =>
    Navigator.of(context).pushReplacement(_route(context, 'conversation', const ConversationPage()));

/// A row of the Messages list: the live thread when it is the open one,
/// otherwise that conversation as it stands (closed ones are read-only).
Future<void> openConversation(BuildContext context, ConversationSummary c) {
  if (c.id == context.messenger.liveId) return openLiveConversation(context);
  return pushMessengerPage(context, 'conversation', ConversationPage(conversationId: c.id));
}

Future<void> openArticle(BuildContext context, String slug, {String? title}) =>
    pushMessengerPage(context, 'article', ArticlePage(slug: slug, title: title));
