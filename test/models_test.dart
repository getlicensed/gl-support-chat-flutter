import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/api/models.dart';

// What the API sends, parsed defensively: one odd row never takes the
// messenger down.
void main() {
  test('the session: chips, WhatsApp number, logo and team are checked', () {
    final s = MessengerSession.fromJson(<String, dynamic>{
      'token': 'jwt',
      'visitorId': 'v1',
      'productName': '',
      'orgName': 'Get Licensed',
      'brandColor': '#112233',
      'logoUrl': 'javascript:alert(1)',
      'whatsappNumber': '12',
      'suggestedQuestions': <Object?>[
        <String, dynamic>{'text': '  Renew my licence  ', 'articleSlug': 'renew'},
        <String, dynamic>{'text': ''},
        <String, dynamic>{'text': 'Book on WhatsApp', 'action': 'whatsapp'},
        'not a map',
      ],
      'team': <Object?>[
        <String, dynamic>{'name': 'A', 'initials': 'A'},
        <String, dynamic>{'name': 'B', 'initials': 'B'},
        <String, dynamic>{'name': 'C', 'initials': 'C'},
        <String, dynamic>{'name': 'D', 'initials': 'D'},
      ],
    });
    expect(s.productLabel, 'Get Licensed', reason: 'the organisation when the chatbot has no name');
    expect(s.logoUrl, isNull, reason: 'only http(s) logos');
    expect(s.whatsappNumber, isNull, reason: 'too short to be a number');
    expect(s.suggestedQuestions.map((q) => q.text), <String>['Renew my licence'], reason: 'empty rows and WhatsApp chips without a number are dropped');
    expect(s.suggestedQuestions.single.action, 'article', reason: 'an old row with a slug is an article chip');
    expect(s.team.length, 3);
  });

  test('a message: meta and files the customer may see', () {
    final m = ChatMessage.fromJson(<String, dynamic>{
      'id': 'm1',
      'conversationId': 'c1',
      'body': 'Pick one',
      'authorType': 'bot',
      'createdAt': '2026-10-06T10:00:00.000Z',
      'meta': <String, dynamic>{
        'buttons': <Object?>[
          <String, dynamic>{'id': 'b1', 'label': 'Book'},
          <String, dynamic>{'id': 'b2'},
        ],
        'lockComposer': true,
        'image': <String, dynamic>{'url': 'file:///etc/passwd'},
        'csat': <String, dynamic>{'ratingId': 'r1'},
      },
      'attachments': <Object?>[
        <String, dynamic>{'name': 'licence.jpg', 'url': 'upload://11111111-2222-3333-4444-555555555555', 'contentType': 'image/jpeg', 'bytes': 10},
        <String, dynamic>{'name': 'x', 'url': ''},
      ],
    });
    expect(m.meta!.buttons.map((b) => b.label), <String>['Book'], reason: 'a button without a label is skipped');
    expect(m.meta!.lockComposer, isTrue);
    expect(m.meta!.isPrompt, isTrue);
    expect(m.meta!.imageUrl, isNull, reason: 'only http(s) pictures');
    expect(m.meta!.csatRatingId, 'r1');
    expect(m.attachments.single.uploadId, '11111111-2222-3333-4444-555555555555');
    expect(m.attachments.single.isImage, isTrue);
    expect(m.createdAt.isUtc, isFalse, reason: 'shown in the phone’s time');
  });

  test('odd values become safe defaults, not exceptions', () {
    final m = ChatMessage.fromJson(<String, dynamic>{'id': 7, 'body': null, 'createdAt': 'yesterday', 'meta': 'x'});
    expect(m.id, '');
    expect(m.body, '');
    expect(m.authorType, 'system', reason: 'unknown authors are never drawn');
    expect(m.meta, isNull);
    final c = ConversationSummary.fromJson(<String, dynamic>{'id': 'c', 'status': 'snoozed', 'unreadCount': 'many'});
    expect(c.open, isTrue);
    expect(c.unreadCount, 0);
    expect(WorkflowPreview.fromJson(<String, dynamic>{'workflowId': 'w', 'messages': <Object?>[]}), isNull, reason: 'a menu with no messages is no menu');
  });

  test('a conversation with its CSAT state', () {
    final d = ConversationDetail.fromJson(<String, dynamic>{
      'conversation': <String, dynamic>{
        'id': 'c1',
        'status': 'closed',
        'csat': <String, dynamic>{'ratingId': 'r1', 'rating': 4, 'comment': null},
      },
      'messages': <Object?>[
        <String, dynamic>{'id': 'a', 'authorType': 'agent', 'body': 'Hi'},
        <String, dynamic>{'body': 'no id'},
      ],
    });
    expect(d.open, isFalse);
    expect(d.csat!.rating, 4);
    expect(d.messages.length, 1);
  });
}
