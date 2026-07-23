import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../../../core/l10n/app_localizations.dart';
import '../../ai_config/domain/stt_config.dart';
import '../../ai_config/domain/ai_providers.dart';

/// User choices for transcription (STT model, language, speaker labeling), shared by
/// detail page and batch transcribe.
class TranscribeSheetSelection {
  final SttConfig? stt;
  final String language;
  final bool autoSpeaker;

  const TranscribeSheetSelection({
    required this.stt,
    required this.language,
    required this.autoSpeaker,
  });
}

/// Transcription language: when the user picks [Auto], infer `zh` / `en` from UI [locale];
/// for other system locales omit `language` (ASR auto-detects).
/// [displayHint] feeds [AsrRecognizeResult.displayText]; must match [apiLanguage] so English
/// text does not use Chinese spacing rules.
({String? apiLanguage, String? displayHint}) resolvedTranscribeLanguage(
  String selectionLanguage,
  Locale locale,
) {
  final s = selectionLanguage.trim();
  if (s == 'en') {
    return (apiLanguage: 'en', displayHint: 'en');
  }
  if (s == 'zh') {
    return (apiLanguage: 'zh', displayHint: 'zh');
  }
  // Auto (or any unknown value treated as Auto)
  final code = locale.languageCode.toLowerCase();
  if (code == 'zh') {
    return (apiLanguage: 'zh', displayHint: 'zh');
  }
  if (code == 'en') {
    return (apiLanguage: 'en', displayHint: 'en');
  }
  return (apiLanguage: null, displayHint: null);
}

bool supportsSpeakerDiarization(SttProvider provider) {
  switch (provider) {
    case SttProvider.deepgram:
    case SttProvider.tencent:
    case SttProvider.iflytek:
    case SttProvider.aliyun:
      return true;
    default:
      return false;
  }
}

const int kAsrChunkThresholdSeconds = 30 * 60;

bool configSupportsSpeakerDiarization(
  SttConfig config, {
  String language = 'Auto',
  Locale? locale,
}) {
  if (config.provider == SttProvider.funasr) {
    return _funasrConfigDeclaresSpeakerDiarization(config);
  }
  if (!supportsSpeakerDiarization(config.provider)) {
    return false;
  }
  if (config.provider == SttProvider.tencent) {
    return _tencentEngineSupportsSpeakerDiarization(
      _tencentEngineModelForLanguage(language, locale),
    );
  }
  if (config.provider != SttProvider.aliyun) {
    return true;
  }
  return (config.appId ?? '').trim().isNotEmpty &&
      (config.accessKeyId ?? '').trim().isNotEmpty &&
      (config.accessKeySecret ?? '').trim().isNotEmpty;
}

String _effectiveLanguage(String language, Locale? locale) {
  final raw = language.trim().toLowerCase();
  if (raw.isNotEmpty && raw != 'auto') {
    return raw;
  }
  final localeCode = locale?.languageCode.trim().toLowerCase();
  if (localeCode == 'en' || localeCode == 'zh') {
    return localeCode!;
  }
  return 'zh';
}

String _tencentEngineModelForLanguage(String language, Locale? locale) {
  switch (_effectiveLanguage(language, locale)) {
    case 'en':
      return '16k_en';
    case 'zh-tw':
    case 'zh-hant':
      return '16k_zh-TW';
    case 'yue':
      return '16k_yue';
    case 'ja':
      return '16k_ja';
    case 'ko':
      return '16k_ko';
    default:
      return '16k_zh';
  }
}

bool _tencentEngineSupportsSpeakerDiarization(String engineModel) {
  switch (engineModel.trim()) {
    case '8k_zh':
    case '16k_zh':
    case '16k_ms':
    case '16k_en':
    case '16k_id':
    case '16k_zh_large':
    case '16k_zh_dialect':
      return true;
    default:
      return false;
  }
}

bool _funasrConfigDeclaresSpeakerDiarization(SttConfig config) {
  final extra = _decodeExtraJsonObject(config.extraJson);
  for (final key in const [
    'supports_speaker_diarization',
    'speaker_diarization',
    'speaker_labeling',
    'diarization',
    'auto_speaker',
    'has_speaker_diarization',
  ]) {
    final value = extra[key];
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true' ||
          normalized == '1' ||
          normalized == 'yes' ||
          normalized == 'supported') {
        return true;
      }
      if (normalized == 'false' || normalized == '0' || normalized == 'no') {
        return false;
      }
    }
  }

  final declared = [
    config.modelName,
    config.modelPath,
    config.name,
  ].whereType<String>().join(' ').toLowerCase();
  return declared.contains('diar') ||
      declared.contains('speaker') ||
      declared.contains('spk') ||
      declared.contains('说话人') ||
      declared.contains('分人');
}

Map<String, dynamic> _decodeExtraJsonObject(String? extraJson) {
  final raw = (extraJson ?? '').trim();
  if (raw.isEmpty) return const <String, dynamic>{};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {
    // Ignore malformed extra JSON; configs without an explicit flag stay disabled.
  }
  return const <String, dynamic>{};
}

SttConfig? pickPreferredSttConfig(
  List<SttConfig> configs, {
  required bool autoSpeaker,
  required String language,
  Locale? locale,
}) {
  if (configs.isEmpty) return null;
  if (autoSpeaker) {
    final lang = language.trim().toLowerCase();
    final diarizationCandidates = configs
        .where((config) => configSupportsSpeakerDiarization(
              config,
              language: language,
              locale: locale,
            ))
        .toList();
    if (diarizationCandidates.isEmpty) {
      return configs.first;
    }
    diarizationCandidates.sort((a, b) {
      int score(SttConfig c) {
        if (lang == 'en') {
          switch (c.provider) {
            case SttProvider.deepgram:
              return 0;
            case SttProvider.tencent:
              return 1;
            case SttProvider.iflytek:
              return 2;
            case SttProvider.funasr:
              return 3;
            default:
              return 9;
          }
        }
        switch (c.provider) {
          case SttProvider.iflytek:
            return (c.modelName ?? '').trim().toLowerCase() == 'file' ? 0 : 1;
          case SttProvider.tencent:
            return 2;
          case SttProvider.aliyun:
            return 3;
          case SttProvider.funasr:
            return 4;
          case SttProvider.deepgram:
            return 5;
          default:
            return 9;
        }
      }

      final cmp = score(a).compareTo(score(b));
      if (cmp != 0) return cmp;
      return a.sortIndex.compareTo(b.sortIndex);
    });
    return diarizationCandidates.first;
  }
  final lang = language.trim().toLowerCase();
  final candidates = [...configs];
  candidates.sort((a, b) {
    int score(SttConfig c) {
      if (lang == 'en') {
        switch (c.provider) {
          case SttProvider.deepgram:
            return 0;
          case SttProvider.openAiWhisper:
          case SttProvider.googleGemini:
          case SttProvider.localWhisper:
            return 1;
          default:
            return 9;
        }
      }
      switch (c.provider) {
        case SttProvider.iflytek:
          return (c.modelName ?? '').trim().toLowerCase() == 'file' ? 0 : 1;
        case SttProvider.baidu:
          return 2;
        case SttProvider.tencent:
          return 3;
        case SttProvider.aliyun:
        case SttProvider.funasr:
          return 4;
        case SttProvider.doubao:
          return 5;
        case SttProvider.openAiWhisper:
        case SttProvider.googleGemini:
          return 6;
        case SttProvider.deepgram:
          return 7;
        default:
          return 9;
      }
    }

    final cmp = score(a).compareTo(score(b));
    if (cmp != 0) return cmp;
    return a.sortIndex.compareTo(b.sortIndex);
  });
  return candidates.first;
}

({SttConfig? config, bool autoSpeaker, String? notice}) resolveSttExecution(
  TranscribeSheetSelection selection,
  List<SttConfig> availableConfigs,
  AppLocalizations l10n,
  Locale? locale,
) {
  final selected = selection.stt ??
      pickPreferredSttConfig(
        availableConfigs,
        autoSpeaker: selection.autoSpeaker,
        language: selection.language,
        locale: locale,
      );
  if (selected == null) {
    return (config: null, autoSpeaker: false, notice: null);
  }
  final effectiveAutoSpeaker = selection.autoSpeaker &&
      configSupportsSpeakerDiarization(
        selected,
        language: selection.language,
        locale: locale,
      );
  String? notice;
  if (selection.autoSpeaker && !effectiveAutoSpeaker) {
    notice = l10n.speakerModeFallbackNormal(selected.provider.labelFor(l10n));
  }
  return (
    config: selected,
    autoSpeaker: effectiveAutoSpeaker,
    notice: notice,
  );
}
