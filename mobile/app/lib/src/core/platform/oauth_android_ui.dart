import 'dart:io';

import 'package:flutter/services.dart';

/// Android-only helpers for OAuth browser / Custom Tab stacking issues.
class OAuthAndroidUi {
  static const MethodChannel _channel = MethodChannel('cc.seeed.voice/oauth_ui');

  /// After GitHub OAuth, Huawei/Honor often keep the browser tab on top even when
  /// [MainActivity] has resumed. Reorder our task to the foreground.
  static Future<void> bringAppToFront() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('bringToFront');
    } catch (_) {
      // Best-effort only.
    }
  }
}
