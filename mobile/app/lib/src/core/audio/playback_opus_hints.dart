import 'dart:io';

import 'package:flutter/services.dart';

/// On some devices (notably Huawei/Honor) ExoPlayer plays Ogg-wrapped Opus poorly:
/// [setFilePath] may not throw but playback is silent. Skip Ogg remux and decode to WAV instead.
class PlaybackOpusHints {
  PlaybackOpusHints._();

  static bool _initialized = false;

  /// true: skip Ogg remux; [prepareAudioForPlayback] should use WAV.
  static bool skipOggRemux = Platform.isIOS;

  /// After play failure, force WAV (e.g. ExoPlayer UnrecognizedInputFormat).
  static void forcePreferWavOverOgg() {
    skipOggRemux = true;
  }

  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    _initialized = true;
    if (!Platform.isAndroid) return;
    try {
      const ch = MethodChannel('cc.seeed.voice/config');
      final v = await ch.invokeMethod<bool>('shouldSkipOggOpusPlayback');
      if (v == true) {
        skipOggRemux = true;
      }
    } catch (_) {
      // On channel errors prefer WAV; bad Ogg remux can make ExoPlayer reject the format.
      skipOggRemux = true;
    }
  }
}
