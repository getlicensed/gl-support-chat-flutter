/// Ways to reach Get Licensed that work when the chat itself cannot load.
///
/// Shown on the "We can't open the chat right now" screen, under Try again
/// and Open in browser. None of these depends on GL Support Chat's servers:
/// an email still lands in the support mailbox, a WhatsApp message is
/// redelivered by Meta once the server is back, a phone call is a phone call.
class GLSupportChatFallback {
  const GLSupportChatFallback({
    this.email = 'we.care@get-licensed.co.uk',
    this.emailSubject = 'Support request',
    this.whatsappNumber,
    this.phoneNumber,
    this.helpUrl,
  });

  /// The support mailbox. `null` hides the row.
  final String? email;

  /// Pre-filled subject for the email.
  final String? emailSubject;

  /// The REAL WhatsApp number, international format (e.g. `447700900123`) —
  /// never Meta's test number, which cannot receive from customers. `null`
  /// (the default) hides the row.
  final String? whatsappNumber;

  /// A number customers may call. `null` hides the row.
  final String? phoneNumber;

  /// The public help centre, e.g. `https://support.get-licensed.co.uk/help`.
  final String? helpUrl;
}
