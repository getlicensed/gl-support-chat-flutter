import 'package:shared_preferences/shared_preferences.dart';

/// Where the anonymous visitor id lives between app launches, so a customer
/// who chatted before signing in (or who never signs in) finds their
/// conversation again. One per chatbot. An interface so tests keep it in memory.
abstract class SessionStore {
  Future<String?> visitorId(String productId);
  Future<void> saveVisitorId(String productId, String visitorId);
  Future<void> forget(String productId);
}

class PrefsSessionStore implements SessionStore {
  const PrefsSessionStore();

  static String _key(String productId) => 'gl_support_chat.visitor.$productId';

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
}

class MemorySessionStore implements SessionStore {
  final Map<String, String> _ids = <String, String>{};

  @override
  Future<String?> visitorId(String productId) async => _ids[productId];

  @override
  Future<void> saveVisitorId(String productId, String visitorId) async => _ids[productId] = visitorId;

  @override
  Future<void> forget(String productId) async => _ids.remove(productId);
}
