import 'package:flutter/foundation.dart';

/// The phone and app the customer is using, shown to the team on the
/// conversation ("iOS 17.4 · iPhone 15 Pro · v3.4.0 (412)") — so "which
/// version are you on?" is answered before it is asked.
///
/// The app fills it from whatever it already uses (device_info_plus,
/// package_info_plus); the package adds the platform and the app id. It is
/// display only: it is never signed and never decides who the customer is.
class GLSupportChatDevice {
  const GLSupportChatDevice({this.os, this.model, this.manufacturer, this.appVersion, this.appBuild});

  /// "iOS 17.4", "Android 14"
  final String? os;

  /// "iPhone 15 Pro", "SM-S911B"
  final String? model;

  /// "Apple", "samsung"
  final String? manufacturer;

  /// "3.4.0"
  final String? appVersion;

  /// "412"
  final String? appBuild;

  /// What the sign-in sends: the fields that are set, the platform, the app id.
  Map<String, String> toJson({String? appId}) {
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'ios',
      TargetPlatform.android => 'android',
      _ => null,
    };
    final out = <String, String>{};
    void put(String key, String? value) {
      final v = value?.trim();
      if (v != null && v.isNotEmpty) out[key] = v;
    }

    put('platform', platform);
    put('os', os);
    put('model', model);
    put('manufacturer', manufacturer);
    put('appId', appId);
    put('appVersion', appVersion);
    put('appBuild', appBuild);
    return out;
  }
}
