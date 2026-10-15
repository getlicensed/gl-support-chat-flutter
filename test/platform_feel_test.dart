import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gl_support_chat/src/ui/conversation.dart';

import 'support/thread.dart';

// How a tap feels on each phone (0.4.8).

void main() {
  for (final (platform, factory) in <(TargetPlatform, InteractiveInkFeatureFactory)>[
    (TargetPlatform.android, InkRipple.splashFactory),
    (TargetPlatform.iOS, NoSplash.splashFactory),
  ]) {
    testWidgets('${platform.name}: the ink is ${platform == TargetPlatform.iOS ? 'none (iOS does not ripple)' : "the ripple, not Material 3's sparkle (compiled on the first tap)"}', (tester) async {
      await openThread(tester, threadServer(), platform: platform);
      expect(Theme.of(tester.element(find.byType(ConversationPage))).splashFactory, same(factory));
    });
  }
}
