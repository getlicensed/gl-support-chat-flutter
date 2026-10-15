import 'dart:convert';

import '../api/models.dart';

/// How a chatbot's Home looked the last time it was signed in: its colour,
/// logo, greeting and team. Drawn while the messenger signs in again, so
/// even the first open after the app starts is in the chatbot's colours and
/// not a spinner on white. Nothing about the customer, so it is kept on the
/// phone (beside the visitor id) and survives a sign-out.
class MessengerLook {
  const MessengerLook({
    required this.brandColor,
    this.logoUrl,
    this.productLabel = '',
    this.greeting,
    this.subtitle,
    this.team = const <TeamFace>[],
  });

  final String brandColor;
  final String? logoUrl;
  final String productLabel;

  /// The chatbot's own greeting, not the customer's name.
  final String? greeting;
  final String? subtitle;
  final List<TeamFace> team;

  factory MessengerLook.of(MessengerSession s) => MessengerLook(
        brandColor: s.brandColor,
        logoUrl: s.logoUrl,
        productLabel: s.productLabel,
        greeting: s.welcomeGreeting,
        subtitle: s.welcomeSubtitle,
        team: s.team,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'brandColor': brandColor,
        if (logoUrl != null) 'logoUrl': logoUrl,
        'productLabel': productLabel,
        if (greeting != null) 'greeting': greeting,
        if (subtitle != null) 'subtitle': subtitle,
        'team': <Object?>[
          for (final t in team) <String, dynamic>{'name': t.name, 'initials': t.initials, if (t.avatarPath != null) 'avatarUrl': t.avatarPath},
        ],
      };

  /// What was stored, or null for anything unusable: a look is a nicety,
  /// never a reason to fail.
  static MessengerLook? fromJson(Object? json) {
    if (json is! Map) return null;
    final brand = json['brandColor'];
    if (brand is! String || brand.isEmpty) return null;
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    final logo = text(json['logoUrl']);
    final team = json['team'];
    return MessengerLook(
      brandColor: brand,
      logoUrl: logo != null && RegExp(r'^https?://', caseSensitive: false).hasMatch(logo) ? logo : null,
      productLabel: text(json['productLabel']) ?? '',
      greeting: text(json['greeting']),
      subtitle: text(json['subtitle']),
      team: team is List ? team.whereType<Map>().take(3).map((t) => TeamFace.fromJson(Map<String, dynamic>.from(t))).toList() : const <TeamFace>[],
    );
  }

  /// The same look as [other]: nothing to write again.
  bool same(MessengerLook? other) => other != null && jsonEncode(toJson()) == jsonEncode(other.toJson());
}
