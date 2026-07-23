import '../../../core/l10n/app_localizations.dart';

enum SttProvider {
  /// Alibaba Cloud ASR / Tingwu (doc: `aliyun`)
  aliyun,

  /// Self-hosted FunASR (doc: `funasr`)
  funasr,

  openAiWhisper,
  googleGemini,
  deepgram,
  localWhisper,
  vosk,
  iflytek,
  tencent,
  baidu,

  /// Doubao (ByteDance) ASR (doc: `doubao`)
  doubao,
  onDeviceLocalStt,
}

extension SttProviderX on SttProvider {
  String get label => switch (this) {
        SttProvider.aliyun => '阿里云',
        SttProvider.funasr => '自建 FunASR',
        SttProvider.openAiWhisper => 'OpenAI Whisper',
        SttProvider.googleGemini => 'Google Gemini',
        SttProvider.deepgram => 'Deepgram',
        SttProvider.localWhisper => 'Local Whisper',
        SttProvider.vosk => 'Vosk',
        SttProvider.iflytek => '讯飞',
        SttProvider.tencent => '腾讯',
        SttProvider.baidu => '百度',
        SttProvider.doubao => '豆包 ASR',
        SttProvider.onDeviceLocalStt => 'On-device Local STT',
      };

  String labelFor(AppLocalizations l10n) => switch (this) {
        SttProvider.aliyun => l10n.sttProviderAliyun,
        SttProvider.funasr => l10n.sttProviderFunasr,
        SttProvider.openAiWhisper => l10n.sttProviderOpenAiWhisper,
        SttProvider.googleGemini => l10n.sttProviderGoogleGemini,
        SttProvider.deepgram => l10n.sttProviderDeepgram,
        SttProvider.localWhisper => l10n.sttProviderLocalWhisper,
        SttProvider.vosk => l10n.sttProviderVosk,
        SttProvider.iflytek => l10n.sttProviderIflytek,
        SttProvider.tencent => l10n.sttProviderTencent,
        SttProvider.baidu => l10n.sttProviderBaidu,
        SttProvider.doubao => l10n.sttProviderDoubao,
        SttProvider.onDeviceLocalStt => l10n.sttProviderOnDevice,
      };

  String get defaultBaseUrl => switch (this) {
        SttProvider.aliyun => '',
        // ASR config doc default is https://api.openai.com (not /v1)
        SttProvider.openAiWhisper => 'https://api.openai.com',
        SttProvider.googleGemini => 'https://generativelanguage.googleapis.com',
        SttProvider.deepgram => 'https://api.deepgram.com',
        SttProvider.vosk => 'http://localhost:2700',
        SttProvider.localWhisper => 'http://localhost:8080',
        _ => '',
      };

  /// Vendor code/type aligned with server ASR config doc (for vendors[].code / vendors[].type).
  ///
  /// Doc only covers some vendors; other Providers using server config need backend protocol before mapping.
  String? get asrVendorCode => switch (this) {
        SttProvider.aliyun => 'aliyun',
        SttProvider.funasr => 'funasr',
        SttProvider.openAiWhisper => 'openai_whisper',
        SttProvider.googleGemini => 'google_gemini',
        SttProvider.deepgram => 'deepgram',
        SttProvider.baidu => 'baidu',
        SttProvider.tencent => 'tencent',
        SttProvider.doubao => 'doubao',
        SttProvider.iflytek => 'iflytek',
        SttProvider.vosk => 'vosk',
        SttProvider.localWhisper => 'local_whisper',
        _ => null,
      };

  /// Per-vendor default model when app field is empty; user text overrides
  String get defaultAsrModel => switch (this) {
        SttProvider.aliyun => 'fun-asr-realtime',
        SttProvider.openAiWhisper => 'whisper-1',
        SttProvider.googleGemini => 'gemini-2.5-flash',
        SttProvider.iflytek => 'file',
        _ => '',
      };

  /// Placeholder / example for the model field (STT).
  String sttModelNameHint(AppLocalizations l10n) {
    final d = defaultAsrModel;
    if (d.isNotEmpty) return d;
    return switch (this) {
      SttProvider.baidu => l10n.hintSttBaiduModelName,
      SttProvider.tencent => l10n.hintSttTencentModelName,
      SttProvider.doubao => l10n.hintSttDoubaoModelName,
      _ => l10n.hintModelExample,
    };
  }

  /// Short note under STT model field.
  String sttModelFieldCaption(AppLocalizations l10n) => switch (this) {
        SttProvider.aliyun => l10n.hintSttAliyunModelCaption,
        _ => l10n.hintSttModelCaption,
      };
}

enum LlmProvider {
  openAi,
  anthropic,
  googleGemini,
  llama,
  doubao,
  qwen,
  deepseek,
  openRouter,
}

extension LlmProviderX on LlmProvider {
  String get label => switch (this) {
        LlmProvider.openAi => 'OpenAI GPT',
        LlmProvider.anthropic => 'Anthropic Claude',
        LlmProvider.googleGemini => 'Google Gemini',
        LlmProvider.llama => 'Llama',
        LlmProvider.doubao => 'Doubao',
        LlmProvider.qwen => 'Qwen',
        LlmProvider.deepseek => 'DeepSeek',
        LlmProvider.openRouter => 'OpenRouter',
      };

  String labelFor(AppLocalizations l10n) => switch (this) {
        LlmProvider.openAi => l10n.llmProviderOpenAi,
        LlmProvider.anthropic => l10n.llmProviderAnthropic,
        LlmProvider.googleGemini => l10n.llmProviderGoogleGemini,
        LlmProvider.llama => l10n.llmProviderLlama,
        LlmProvider.doubao => l10n.llmProviderDoubao,
        LlmProvider.qwen => l10n.llmProviderQwen,
        LlmProvider.deepseek => l10n.llmProviderDeepseek,
        LlmProvider.openRouter => l10n.llmProviderOpenRouter,
      };

  String get defaultBaseUrl => switch (this) {
        LlmProvider.openAi => 'https://api.openai.com/v1',
        LlmProvider.anthropic => 'https://api.anthropic.com',
        LlmProvider.googleGemini => 'https://generativelanguage.googleapis.com',
        LlmProvider.qwen => 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        LlmProvider.doubao => 'https://ark.cn-beijing.volces.com/api/v3',
        LlmProvider.deepseek => 'https://api.deepseek.com/v1',
        LlmProvider.openRouter => 'https://openrouter.ai/api/v1',
        _ => '',
      };

  /// Backend default when [modelName] is left empty.
  String get defaultLlmModel => switch (this) {
        LlmProvider.openAi => 'gpt-4o',
        LlmProvider.anthropic => 'claude-sonnet-4-0',
        LlmProvider.googleGemini => 'gemini-2.5-flash',
        LlmProvider.qwen => 'qwen-turbo',
        LlmProvider.deepseek => 'deepseek-chat',
        LlmProvider.doubao => '',
        LlmProvider.openRouter => '',
        LlmProvider.llama => '',
      };

  /// Code/type aligned with server LLM config doc
  String? get llmVendorCode => switch (this) {
        LlmProvider.openAi => 'openai',
        LlmProvider.anthropic => 'anthropic',
        LlmProvider.googleGemini => 'google_gemini',
        LlmProvider.llama => 'llama',
        LlmProvider.doubao => 'doubao',
        LlmProvider.qwen => 'qwen',
        LlmProvider.deepseek => 'deepseek',
        LlmProvider.openRouter => 'openrouter',
      };

  /// Provider-specific model placeholder (not generic gpt-4o for every vendor).
  String modelNameHint(AppLocalizations l10n) => switch (this) {
        LlmProvider.openAi => l10n.hintLlmOpenAiModelName,
        LlmProvider.anthropic => l10n.hintLlmAnthropicModelName,
        LlmProvider.googleGemini => l10n.hintLlmGoogleGeminiModelName,
        LlmProvider.qwen => l10n.hintLlmQwenModelName,
        LlmProvider.deepseek => l10n.hintLlmDeepseekModelName,
        LlmProvider.doubao => l10n.hintLlmDoubaoModelName,
        LlmProvider.openRouter => l10n.hintLlmOpenRouterModelName,
        LlmProvider.llama => l10n.hintLlmLlamaModelName,
      };

  /// Base URL placeholder; falls back to [defaultBaseUrl] when set.
  String baseUrlHint(AppLocalizations l10n) {
    final d = defaultBaseUrl.trim();
    if (d.isNotEmpty) return d;
    return l10n.hintLlmCustomBaseUrl;
  }

  /// Where to obtain the API key (placeholder in key field).
  String apiKeyHint(AppLocalizations l10n) => switch (this) {
        LlmProvider.qwen => l10n.hintLlmQwenApiKey,
        LlmProvider.deepseek => l10n.hintLlmDeepseekApiKey,
        LlmProvider.openAi => l10n.hintLlmOpenAiApiKey,
        LlmProvider.anthropic => l10n.hintLlmAnthropicApiKey,
        LlmProvider.googleGemini => l10n.hintLlmGoogleGeminiApiKey,
        LlmProvider.doubao => l10n.hintLlmDoubaoApiKey,
        LlmProvider.openRouter => l10n.hintLlmOpenRouterApiKey,
        LlmProvider.llama => l10n.hintLlmLlamaApiKey,
      };

  /// Helper text shown under the model field.
  String modelFieldCaption(AppLocalizations l10n) => switch (this) {
        LlmProvider.qwen => l10n.hintLlmQwenModelCaption,
        LlmProvider.deepseek => l10n.hintLlmDeepseekModelCaption,
        _ => l10n.hintLlmModelCaption,
      };

  /// Every LLM call must include a model / endpoint id — required everywhere.
  bool get modelNameRequired => true;
}
