import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where the anonymous visitor id lives between app launches, so a customer
/// who chatted before signing in (or who never signs in) finds their
/// conversation again; and, beside it, how the chatbot looked
/// (`MessengerLook`), so the first open after a launch is in its colours.
/// One of each per chatbot. And the text size chosen with Aa, one for the
/// phone. An interface so tests keep it in memory.
abstract class SessionStore {
  Future<String?> visitorId(String productId);
  Future<void> saveVisitorId(String productId, String visitorId);
  Future<void> forget(String productId);

  /// The chatbot's look as last saved (JSON), or null.
  Future<Map<String, dynamic>?> look(String productId);
  Future<void> saveLook(String productId, Map<String, dynamic> look);

  /// The multiple of the phone's text size chosen with Aa, or null.
  Future<double?> textSize();
  Future<void> saveTextSize(double factor);
}

class PrefsSessionStore implements SessionStore {
  const PrefsSessionStore();

  static String _key(String productId) => 'gl_support_chat.visitor.$productId';
  static String _lookKey(String productId) => 'gl_support_chat.look.$productId';
  static const _textSizeKey = 'gl_support_chat.text_size';

  @override
  Future<String?> visitorId(String productId) async {
    try {
      return (await SharedPreferences.getInstance()).getString(_key(productId));
    } catch (_) {
      return null; // no storage: a new anonymous visitor, never a failure
    }
  }

  @override
  Future<void> saveVisitorId(String productId, String visitorId) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_key(productId), visitorId);
    } catch (_) {
      // the next launch is a new anonymous visitor; nothing else depends on it
    }
  }

  @override
  Future<void> forget(String productId) async {
    try {
      await (await SharedPreferences.getInstance()).remove(_key(productId));
    } catch (_) {
      // nothing stored, nothing to forget
    }
  }

  @override
  Future<Map<String, dynamic>?> look(String productId) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_lookKey(productId));
      if (raw == null) return null;
      final j = jsonDecode(raw);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } catch (_) {
      return null; // nothing usable: the default colours until it signs in
    }
  }

  @override
  Future<void> saveLook(String productId, Map<String, dynamic> look) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_lookKey(productId), jsonEncode(look));
    } catch (_) {
      // the next launch opens in the default colours; nothing depends on it
    }
  }

  @override
  Future<double?> textSize() async {
    try {
      return (await SharedPreferences.getInstance()).getDouble(_textSizeKey);
    } catch (_) {
      return null; // nothing usable: the phone's own size
    }
  }

  @override
  Future<void> saveTextSize(double factor) async {
    try {
      await (await SharedPreferences.getInstance()).setDouble(_textSizeKey, factor);
    } catch (_) {
      // kept for this launch only; the next opens at the phone's own size
    }
  }
}

class MemorySessionStore implements SessionStore {
  final Map<String, String> _ids = <String, String>{};
  final Map<String, Map<String, dynamic>> _looks = <String, Map<String, dynamic>>{};

  @override
  Future<String?> visitorId(String productId) async => _ids[productId];

  @override
  Future<void> saveVisitorId(String productId, String visitorId) async => _ids[productId] = visitorId;

  @override
  Future<void> forget(String productId) async => _ids.remove(productId);

  @override
  Future<Map<String, dynamic>?> look(String productId) async => _looks[productId];

  @override
  Future<void> saveLook(String productId, Map<String, dynamic> look) async => _looks[productId] = look;

  double? _textSize;

  @override
  Future<double?> textSize() async => _textSize;

  @override
  Future<void> saveTextSize(double factor) async => _textSize = factor;
}
