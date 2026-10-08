// What the messenger API sends, parsed defensively: a missing or odd field
// becomes a safe default, never an exception, so one bad row cannot take the
// whole messenger down. Shapes: the server's /widget routes (the
// messenger API).

String? _str(Object? v) => v is String ? v : null;
String _text(Object? v) => v is String ? v : '';
int _int(Object? v) => v is num ? v.toInt() : 0;
bool _bool(Object? v) => v == true;
DateTime _date(Object? v) => (v is String ? DateTime.tryParse(v)?.toLocal() : null) ?? DateTime.now();
DateTime? _dateOrNull(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;
Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _maps(Object? v) =>
    v is List ? v.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList() : <Map<String, dynamic>>[];

/// A team member's face on Home: initials, and a photo path when they have one.
class TeamFace {
  const TeamFace({required this.name, required this.initials, this.avatarPath});

  final String name;
  final String initials;

  /// Relative to the API (`/widget/avatar/<id>?v=…`).
  final String? avatarPath;

  factory TeamFace.fromJson(Map<String, dynamic> j) => TeamFace(
        name: _text(j['name']),
        initials: _str(j['initials']) ?? '?',
        avatarPath: _str(j['avatarUrl']),
      );
}

/// A chip under an empty thread: send it, open an article, or open WhatsApp.
class SuggestedQuestion {
  const SuggestedQuestion({required this.text, this.articleSlug, this.action = 'message', this.whatsappText});

  final String text;
  final String? articleSlug;

  /// `message` · `article` · `whatsapp`
  final String action;
  final String? whatsappText;

  /// Null for a row with no text — the web widget drops those too.
  static SuggestedQuestion? fromJson(Map<String, dynamic> j) {
    final text = _text(j['text']).trim();
    if (text.isEmpty) return null;
    final slug = _str(j['articleSlug']);
    return SuggestedQuestion(
      text: text,
      articleSlug: slug,
      // Older rows have no action: an article when they name one, else a message.
      action: _str(j['action']) ?? (slug != null ? 'article' : 'message'),
      whatsappText: _str(j['whatsappText']),
    );
  }
}

class OfficeHours {
  const OfficeHours({required this.open, this.opensLabel, this.awayMessage});

  final bool open;

  /// "tomorrow at 9am"
  final String? opensLabel;
  final String? awayMessage;

  factory OfficeHours.fromJson(Map<String, dynamic> j) =>
      OfficeHours(open: j['open'] != false, opensLabel: _str(j['opensLabel']), awayMessage: _str(j['awayMessage']));
}

/// POST /widget/auth — the session and everything the messenger draws before
/// any conversation: branding, greeting, team, office hours, help centre.
class MessengerSession {
  const MessengerSession({
    required this.token,
    required this.visitorId,
    required this.brandColor,
    required this.productLabel,
    this.logoUrl,
    this.welcomeGreeting,
    this.welcomeSubtitle,
    this.identified = false,
    this.identifiedName,
    this.email,
    this.team = const <TeamFace>[],
    this.officeHours,
    this.helpBaseUrl,
    this.whatsappNumber,
    this.suggestedQuestions = const <SuggestedQuestion>[],
  });

  final String token;
  final String visitorId;
  final String brandColor;

  /// The chatbot's name (else the organisation's): the bot's name, the header.
  final String productLabel;
  final String? logoUrl;
  final String? welcomeGreeting;
  final String? welcomeSubtitle;

  /// The server accepted the identity sent with this sign-in. False for an
  /// anonymous one — also the one after a refused identity.
  final bool identified;

  /// Set when a signed identity was accepted: greet by first name.
  final String? identifiedName;

  /// On record already — then the "leave your email" bar never shows.
  final String? email;
  final List<TeamFace> team;
  final OfficeHours? officeHours;
  final String? helpBaseUrl;

  /// Digits only, or null when there is no valid one.
  final String? whatsappNumber;
  final List<SuggestedQuestion> suggestedQuestions;

  factory MessengerSession.fromJson(Map<String, dynamic> j) {
    final identified = _map(j['identified']);
    final digits = _text(j['whatsappNumber']);
    final whatsapp = RegExp(r'^\d{8,15}$').hasMatch(digits) ? digits : null;
    final chips = _maps(j['suggestedQuestions'])
        .map(SuggestedQuestion.fromJson)
        .whereType<SuggestedQuestion>()
        .where((q) => q.action != 'whatsapp' || whatsapp != null)
        .take(4)
        .toList();
    final logo = _str(j['logoUrl']);
    return MessengerSession(
      token: _text(j['token']),
      visitorId: _text(j['visitorId']),
      brandColor: _str(j['brandColor']) ?? '#6366F1',
      productLabel: (_str(j['productName']) ?? '').isNotEmpty ? _text(j['productName']) : _text(j['orgName']),
      logoUrl: logo != null && RegExp(r'^https?://', caseSensitive: false).hasMatch(logo) ? logo : null,
      welcomeGreeting: _str(j['welcomeGreeting']),
      welcomeSubtitle: _str(j['welcomeSubtitle']),
      identified: j['identified'] is Map,
      identifiedName: _str(identified['name']),
      email: _str(j['email']),
      team: _maps(j['team']).take(3).map(TeamFace.fromJson).toList(),
      officeHours: j['officeHours'] is Map ? OfficeHours.fromJson(_map(j['officeHours'])) : null,
      helpBaseUrl: _str(j['helpBaseUrl'])?.replaceFirst(RegExp(r'/+$'), ''),
      whatsappNumber: whatsapp,
      suggestedQuestions: chips,
    );
  }
}

class FlowButton {
  const FlowButton(this.id, this.label);
  final String id;
  final String label;
}

class CollectRequest {
  const CollectRequest({required this.field, required this.label, required this.inputType});
  final String field;
  final String label;

  /// `text` · `email` · `tel`
  final String inputType;
}

/// What a bot message carries besides its text. Only what the customer may
/// see reaches the app (the server's allowlist, widget.ts `visitorMeta`).
class MessageMeta {
  const MessageMeta({
    this.buttons = const <FlowButton>[],
    this.lockComposer = false,
    this.collect,
    this.articleSlug,
    this.articleTitle,
    this.imageUrl,
    this.fileName,
    this.fileUrl,
    this.csatRatingId,
  });

  final List<FlowButton> buttons;
  final bool lockComposer;
  final CollectRequest? collect;
  final String? articleSlug;
  final String? articleTitle;
  final String? imageUrl;
  final String? fileName;
  final String? fileUrl;

  /// The CSAT question after a close: draw the five faces.
  final String? csatRatingId;

  bool get isPrompt => buttons.isNotEmpty || collect != null;

  static MessageMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final collect = _map(j['collect']);
    final article = _map(j['article']);
    final image = _map(j['image']);
    final file = _map(j['file']);
    final csat = _map(j['csat']);
    final web = RegExp(r'^https?://', caseSensitive: false);
    final imageUrl = _str(image['url']);
    final fileUrl = _str(file['url']);
    return MessageMeta(
      buttons: _maps(j['buttons'])
          .where((b) => _str(b['id']) != null && _str(b['label']) != null)
          .map((b) => FlowButton(_text(b['id']), _text(b['label'])))
          .toList(),
      lockComposer: _bool(j['lockComposer']),
      collect: _str(collect['field']) != null
          ? CollectRequest(
              field: _text(collect['field']),
              label: _text(collect['label']),
              inputType: _str(collect['inputType']) ?? 'text',
            )
          : null,
      articleSlug: _str(article['slug']),
      articleTitle: _str(article['title']),
      imageUrl: imageUrl != null && web.hasMatch(imageUrl) ? imageUrl : null,
      fileName: _str(file['name']),
      fileUrl: fileUrl != null && web.hasMatch(fileUrl) ? fileUrl : null,
      csatRatingId: _str(csat['ratingId']),
    );
  }
}

/// A file on a message: the customer's own upload (`upload://<id>`, read with
/// their token) or a plain https link.
class Attachment {
  const Attachment({required this.name, required this.url, required this.contentType, this.bytes = 0});

  final String name;
  final String url;
  final String contentType;
  final int bytes;

  bool get isImage => contentType.startsWith('image/');

  /// The upload id behind `upload://<id>`, or null for a plain link.
  String? get uploadId {
    final m = RegExp(r'^upload://([0-9a-fA-F-]{36})$').firstMatch(url);
    return m?.group(1);
  }

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
        name: _str(j['name']) ?? 'file',
        url: _text(j['url']),
        contentType: _str(j['contentType']) ?? 'application/octet-stream',
        bytes: _int(j['bytes']),
      );
}

/// `visitor` · `agent` · `ai` · `bot` · `system`
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.body,
    required this.authorType,
    required this.createdAt,
    this.authorId,
    this.authorName,
    this.meta,
    this.attachments = const <Attachment>[],
  });

  String id;
  final String conversationId;
  String body;
  final String authorType;
  final String? authorId;
  final String? authorName;
  final DateTime createdAt;
  final MessageMeta? meta;
  final List<Attachment> attachments;

  bool get fromVisitor => authorType == 'visitor';
  bool get isSystem => authorType == 'system';

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        id: _text(j['id']),
        conversationId: _text(j['conversationId']),
        body: _text(j['body']),
        authorType: _str(j['authorType']) ?? 'system',
        authorId: _str(j['authorId']),
        authorName: _str(j['authorName']),
        createdAt: _date(j['createdAt']),
        meta: MessageMeta.fromJson(j['meta']),
        attachments: _maps(j['attachments']).map(Attachment.fromJson).where((a) => a.url.isNotEmpty).toList(),
      );
}

/// A row of the Messages list (GET /widget/conversations).
class ConversationSummary {
  ConversationSummary({
    required this.id,
    required this.open,
    required this.lastMessageAt,
    this.unreadCount = 0,
    this.agentId,
    this.agentName,
    this.agentAvatarPath,
    this.lastBody,
    this.lastAuthorType,
    this.lastAuthorName,
  });

  final String id;
  bool open;
  DateTime lastMessageAt;
  int unreadCount;
  final String? agentId;
  final String? agentName;
  final String? agentAvatarPath;
  String? lastBody;
  String? lastAuthorType;
  String? lastAuthorName;

  factory ConversationSummary.fromJson(Map<String, dynamic> j) {
    final agent = _map(j['agent']);
    final last = _map(j['lastMessage']);
    return ConversationSummary(
      id: _text(j['id']),
      open: _str(j['status']) != 'closed',
      lastMessageAt: _date(j['lastMessageAt']),
      unreadCount: _int(j['unreadCount']),
      agentId: _str(agent['id']),
      agentName: _str(agent['name']),
      agentAvatarPath: _str(agent['avatarUrl']),
      lastBody: _str(last['body']),
      lastAuthorType: _str(last['authorType']),
      lastAuthorName: _str(last['authorName']),
    );
  }
}

class CsatState {
  const CsatState({required this.ratingId, this.rating, this.comment});
  final String ratingId;
  final int? rating;
  final String? comment;
}

/// GET /widget/conversations/:id
class ConversationDetail {
  const ConversationDetail({
    required this.id,
    required this.open,
    required this.messages,
    this.agentLastSeenAt,
    this.csat,
  });

  final String id;
  final bool open;
  final List<ChatMessage> messages;
  final DateTime? agentLastSeenAt;
  final CsatState? csat;

  factory ConversationDetail.fromJson(Map<String, dynamic> j) {
    final c = _map(j['conversation']);
    final csat = _map(c['csat']);
    return ConversationDetail(
      id: _text(c['id']),
      open: _str(c['status']) != 'closed',
      agentLastSeenAt: _dateOrNull(c['agentLastSeenAt']),
      csat: _str(csat['ratingId']) != null
          ? CsatState(ratingId: _text(csat['ratingId']), rating: csat['rating'] is num ? _int(csat['rating']) : null, comment: _str(csat['comment']))
          : null,
      messages: _maps(j['messages']).map(ChatMessage.fromJson).where((m) => m.id.isNotEmpty).toList(),
    );
  }
}

/// GET /widget/messages, read only for what the native screens need: which
/// conversation is the open one, its unread count, and a CSAT question left
/// from a conversation that has since closed.
class OpenConversationInfo {
  const OpenConversationInfo({this.conversationId, this.unreadCount = 0, this.pendingCsatRatingId});

  final String? conversationId;
  final int unreadCount;
  final String? pendingCsatRatingId;

  factory OpenConversationInfo.fromJson(Map<String, dynamic> j) => OpenConversationInfo(
        conversationId: _str(j['conversationId']),
        unreadCount: _int(j['unreadCount']),
        pendingCsatRatingId: _str(_map(j['csat'])['ratingId']),
      );
}

/// The opening menu of the chatbot's workflow, before a conversation exists.
class WorkflowPreview {
  const WorkflowPreview({required this.workflowId, required this.messages, required this.letCustomerType});

  final String workflowId;
  final List<({String body, MessageMeta? meta})> messages;
  final bool letCustomerType;

  static WorkflowPreview? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final messages = _maps(j['messages']).map((m) => (body: _text(m['body']), meta: MessageMeta.fromJson(m['meta']))).toList();
    final id = _str(j['workflowId']);
    if (id == null || messages.isEmpty) return null;
    return WorkflowPreview(workflowId: id, messages: messages, letCustomerType: _bool(j['letCustomerType']));
  }
}

class ArticleSummary {
  const ArticleSummary({required this.slug, required this.title, this.description});
  final String slug;
  final String title;
  final String? description;

  factory ArticleSummary.fromJson(Map<String, dynamic> j) =>
      ArticleSummary(slug: _text(j['slug']), title: _text(j['title']), description: _str(j['description']));
}

class Article {
  const Article({required this.slug, required this.title, required this.html, this.description, this.url});
  final String slug;
  final String title;
  final String html;
  final String? description;
  final String? url;

  factory Article.fromJson(Map<String, dynamic> j) => Article(
        slug: _text(j['slug']),
        title: _text(j['title']),
        html: _text(j['html']),
        description: _str(j['description']),
        url: _str(j['url']),
      );
}

/// POST /widget/uploads
class UploadedFile {
  const UploadedFile({required this.id, required this.name, required this.contentType, required this.bytes});
  final String id;
  final String name;
  final String contentType;
  final int bytes;

  factory UploadedFile.fromJson(Map<String, dynamic> j) =>
      UploadedFile(id: _text(j['id']), name: _text(j['name']), contentType: _text(j['contentType']), bytes: _int(j['bytes']));
}
