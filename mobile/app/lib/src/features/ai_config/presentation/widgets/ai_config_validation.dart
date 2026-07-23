import 'dart:convert';

import '../../../../core/l10n/app_localizations.dart';
import '../../domain/ai_providers.dart';

bool sttIsLocalProvider(SttProvider p) =>
    p == SttProvider.localWhisper ||
    p == SttProvider.vosk ||
    p == SttProvider.onDeviceLocalStt;

bool sttShowBaseUrl(SttProvider p) =>
    p == SttProvider.openAiWhisper ||
    p == SttProvider.googleGemini ||
    p == SttProvider.deepgram ||
    p == SttProvider.funasr ||
    p == SttProvider.vosk ||
    p == SttProvider.localWhisper;

bool sttShowApiKey(SttProvider p) =>
    p == SttProvider.aliyun ||
    p == SttProvider.openAiWhisper ||
    p == SttProvider.googleGemini ||
    p == SttProvider.deepgram ||
    p == SttProvider.baidu ||
    p == SttProvider.iflytek ||
    p == SttProvider.funasr ||
    p == SttProvider.localWhisper;

String normalizeGeminiModelNameInput(String modelName) {
  final normalized = modelName.trim().toLowerCase();
  if (normalized.startsWith('models/')) {
    return normalized.substring('models/'.length);
  }
  return normalized;
}

String? validateGeminiModelNameInput(
  String modelName, {
  AppLocalizations? l10n,
}) {
  final raw = modelName.trim();
  if (raw.isEmpty) return null;
  final normalized = normalizeGeminiModelNameInput(raw);
  final valid = _isValidGeminiModelName(normalized);
  if (valid) return null;
  return l10n?.validationGeminiModelNameInvalid ??
      'Gemini model name must look like gemini-2.5-flash';
}

bool _isValidGeminiModelName(String modelName) {
  if (!modelName.startsWith('gemini-')) return false;
  if (modelName.length <= 'gemini-'.length) return false;
  for (var i = 'gemini-'.length; i < modelName.length; i++) {
    final code = modelName.codeUnitAt(i);
    final isDigit = code >= 48 && code <= 57;
    final isLower = code >= 97 && code <= 122;
    final isAllowedPunctuation = code == 45 || code == 46;
    if (!isDigit && !isLower && !isAllowedPunctuation) {
      return false;
    }
  }
  return true;
}

String? _validateModelToken(
  String modelName, {
  AppLocalizations? l10n,
  required String providerLabel,
  required String example,
}) {
  final raw = modelName.trim();
  if (raw.isEmpty) return null;
  if (raw.contains('://') || raw.contains('\n') || raw.contains('\r')) {
    return l10n?.validationModelNameFormatInvalid(providerLabel, example) ??
        '$providerLabel model name format is invalid. Example: $example';
  }
  for (var i = 0; i < raw.length; i++) {
    final code = raw.codeUnitAt(i);
    if (code == 9 || code == 10 || code == 13 || code == 32) {
      return l10n?.validationModelNameFormatInvalid(providerLabel, example) ??
          '$providerLabel model name format is invalid. Example: $example';
    }
  }
  return null;
}

String? validateLlmModelNameInput(
  LlmProvider provider,
  String modelName, {
  AppLocalizations? l10n,
}) {
  final raw = modelName.trim();
  if (raw.isEmpty) return null;

  switch (provider) {
    case LlmProvider.googleGemini:
      return validateGeminiModelNameInput(raw, l10n: l10n);
    case LlmProvider.openRouter:
      return _validateOpenRouterModelName(raw, l10n: l10n);
    case LlmProvider.openAi:
    case LlmProvider.anthropic:
    case LlmProvider.qwen:
    case LlmProvider.deepseek:
    case LlmProvider.doubao:
    case LlmProvider.llama:
      return _validateGenericLlmModelName(
        provider,
        raw,
        l10n: l10n,
      );
  }
}

String? _validateGenericLlmModelName(
  LlmProvider provider,
  String modelName, {
  AppLocalizations? l10n,
}) {
  final label = _llmProviderValidationLabel(provider);
  final example = _llmProviderValidationExample(provider);
  final tokenErr = _validateModelToken(
    modelName,
    providerLabel: label,
    example: example,
    l10n: l10n,
  );
  if (tokenErr != null) return tokenErr;
  if (provider != LlmProvider.openRouter && modelName.contains('/')) {
    return l10n?.validationModelNameFormatInvalid(label, example) ??
        '$label model name format is invalid. Example: $example';
  }
  return null;
}

String _llmProviderValidationLabel(LlmProvider provider) => switch (provider) {
      LlmProvider.openAi => 'OpenAI',
      LlmProvider.anthropic => 'Anthropic',
      LlmProvider.qwen => 'Qwen',
      LlmProvider.deepseek => 'DeepSeek',
      LlmProvider.doubao => 'Doubao',
      LlmProvider.llama => 'Llama',
      LlmProvider.googleGemini => 'Gemini',
      LlmProvider.openRouter => 'OpenRouter',
    };

String _llmProviderValidationExample(LlmProvider provider) =>
    switch (provider) {
      LlmProvider.openAi => 'gpt-4o',
      LlmProvider.anthropic => 'claude-sonnet-4-0',
      LlmProvider.qwen => 'qwen-turbo',
      LlmProvider.deepseek => 'deepseek-chat',
      LlmProvider.doubao => 'ep-xxx',
      LlmProvider.llama => 'llama3.2:3b',
      LlmProvider.googleGemini => 'gemini-2.5-flash',
      LlmProvider.openRouter => 'anthropic/claude-sonnet-4',
    };

String? _validateOpenRouterModelName(
  String modelName, {
  AppLocalizations? l10n,
}) {
  final tokenErr = _validateModelToken(
    modelName,
    providerLabel: 'OpenRouter',
    example: 'anthropic/claude-sonnet-4',
    l10n: l10n,
  );
  if (tokenErr != null) return tokenErr;
  final parts = modelName.split('/');
  final valid = parts.length >= 2 &&
      parts.every((part) => part.trim().isNotEmpty) &&
      !modelName.startsWith('/') &&
      !modelName.endsWith('/');
  if (valid) return null;
  return l10n?.validationModelNameFormatInvalid(
        'OpenRouter',
        'anthropic/claude-sonnet-4',
      ) ??
      'OpenRouter model name format is invalid. Example: anthropic/claude-sonnet-4';
}

String? validateSttInputs({
  required SttProvider provider,
  required String name,
  required String apiKey,
  String? apiSecret,
  String? appId,
  String? accessKeyId,
  String? accessKeySecret,
  String? region,
  String? baseUrl,
  String? modelName,
  String? modelPath,
  String? extraJson,
  AppLocalizations? l10n,
}) {
  final n = name.trim();
  if (n.isEmpty) return l10n?.validationNameRequired ?? 'name required';

  final key = apiKey.trim();
  final secret = (apiSecret ?? '').trim();
  final app = (appId ?? '').trim();
  final ak = (accessKeyId ?? '').trim();
  final sk = (accessKeySecret ?? '').trim();
  final base = (baseUrl ?? '').trim();
  final mpath = (modelPath ?? '').trim();
  final extra = (extraJson ?? '').trim();
  final model = (modelName ?? '').trim();

  // --- Per docx/ASR vendor spec (required fields first) ---
  if (provider == SttProvider.aliyun) {
    final hasDashScope = key.isNotEmpty;
    final hasTingwuAny = app.isNotEmpty || ak.isNotEmpty || sk.isNotEmpty;
    if (!hasDashScope && !hasTingwuAny) {
      return l10n?.validationAliyunCredentialRequired ??
          'Fill in DashScope API KEY, or complete Tingwu credentials.';
    }
    if (!hasDashScope && hasTingwuAny) {
      if (app.isEmpty) {
        return l10n?.validationAppIdRequired ?? 'APP ID required';
      }
      if (ak.isEmpty) {
        return l10n?.validationSecretIdRequired ?? 'SECRET ID required';
      }
      if (sk.isEmpty) {
        return l10n?.validationSecretKeyRequired ?? 'SECRET KEY required';
      }
    }
    final modelErr = _validateModelToken(
      model,
      providerLabel: 'Aliyun ASR',
      example: 'fun-asr-realtime',
      l10n: l10n,
    );
    if (modelErr != null) return modelErr;
  } else if (provider == SttProvider.funasr) {
    if (base.isEmpty) {
      return l10n?.validationBaseUrlRequired ?? 'BASE URL required';
    }
  } else if (provider == SttProvider.openAiWhisper) {
    // openai_whisper: base_url and api_key optional
  } else if (provider == SttProvider.googleGemini ||
      provider == SttProvider.deepgram) {
    if (key.isEmpty) {
      return l10n?.validationApiKeyRequired ?? 'API KEY required';
    }
    if (provider == SttProvider.googleGemini) {
      final err = validateGeminiModelNameInput(model, l10n: l10n);
      if (err != null) return err;
    }
  } else if (provider == SttProvider.baidu) {
    if (app.isEmpty) {
      return l10n?.validationAppIdRequired ?? 'APP ID required';
    }
    if (key.isEmpty) {
      return l10n?.validationApiKeyRequired ?? 'API KEY required';
    }
    if (secret.isEmpty) {
      return l10n?.validationSecretKeyRequired ?? 'SECRET KEY required';
    }
  } else if (provider == SttProvider.tencent) {
    if (ak.isEmpty) {
      return l10n?.validationSecretIdRequired ?? 'SECRET ID required';
    }
    if (sk.isEmpty) {
      return l10n?.validationSecretKeyRequired ?? 'SECRET KEY required';
    }
  } else if (provider == SttProvider.doubao) {
    if (app.isEmpty) {
      return l10n?.validationAppIdRequired ?? 'APP ID required';
    }
    if (extra.isEmpty) {
      return l10n?.validationClusterAccessTokenRequired ??
          'CLUSTER and ACCESS TOKEN required';
    }
    try {
      final m = jsonDecode(extra);
      if (m is! Map) {
        return l10n?.validationExtraJsonMustBeObject ??
            'EXTRA JSON must be an object';
      }
      final cluster = (m['cluster'] ?? '').toString().trim();
      final token = (m['access_token'] ?? '').toString().trim();
      if (cluster.isEmpty || token.isEmpty) {
        return l10n?.validationClusterAccessTokenRequired ??
            'CLUSTER and ACCESS TOKEN required';
      }
    } catch (_) {
      return l10n?.validationExtraJsonMustBeValid ??
          'EXTRA JSON must be valid JSON';
    }
  } else if (provider == SttProvider.iflytek) {
    if (app.isEmpty) {
      return l10n?.validationAppIdRequired ?? 'APP ID required';
    }
    final iflytekModel = model.toLowerCase();
    final isFile = ['file', 'lfasr', 'standard'].contains(iflytekModel);
    if (isFile) {
      if (secret.isEmpty) {
        return l10n?.validationIflytekSecretKeyForFile ??
            'SecretKey required for file transcription';
      }
    } else {
      if (key.isEmpty) {
        return l10n?.validationApiKeyRequired ?? 'API KEY required';
      }
    }
  } else if (provider == SttProvider.vosk ||
      provider == SttProvider.localWhisper) {
    if (base.isEmpty) {
      return l10n?.validationBaseUrlRequired ?? 'BASE URL required';
    }
  } else if (provider == SttProvider.onDeviceLocalStt) {
    if (mpath.isEmpty) {
      return l10n?.validationModelPathRequired ?? 'MODEL PATH required';
    }
  } else {
    if (key.isEmpty) {
      return l10n?.validationApiKeyRequiredLlc ?? 'API key required';
    }
  }

  if (sttShowBaseUrl(provider) &&
      base.isNotEmpty &&
      Uri.tryParse(base) == null) {
    return l10n?.validationInvalidBaseUrl ?? 'invalid Base URL';
  }
  return null;
}

/// Stricter checks for the "Test Connection" action (must have usable credentials).
String? validateSttConnectionTest({
  required SttProvider provider,
  required String name,
  required String apiKey,
  String? apiSecret,
  String? appId,
  String? accessKeyId,
  String? accessKeySecret,
  String? region,
  String? baseUrl,
  String? modelName,
  String? modelPath,
  String? extraJson,
  AppLocalizations? l10n,
}) {
  final err = validateSttInputs(
    provider: provider,
    name: name,
    apiKey: apiKey,
    apiSecret: apiSecret,
    appId: appId,
    accessKeyId: accessKeyId,
    accessKeySecret: accessKeySecret,
    region: region,
    baseUrl: baseUrl,
    modelName: modelName,
    modelPath: modelPath,
    extraJson: extraJson,
    l10n: l10n,
  );
  if (err != null) return err;

  final key = apiKey.trim();
  final base = (baseUrl ?? '').trim();

  // Save allows optional fields for some vendors; connection test must have credentials.
  if (provider == SttProvider.openAiWhisper && key.isEmpty) {
    return l10n?.validationApiKeyRequiredLlc ?? 'API key required';
  }
  if ((provider == SttProvider.localWhisper || provider == SttProvider.vosk) &&
      base.isEmpty) {
    return l10n?.validationBaseUrlRequired ?? 'BASE URL required';
  }
  return null;
}

bool llmApiKeyIsRequired(LlmProvider p) => p != LlmProvider.llama;

bool llmBaseUrlIsRequired(LlmProvider p) => p.defaultBaseUrl.trim().isEmpty;

String? validateLlmInputs({
  required LlmProvider provider,
  required String name,
  required String apiKey,
  String? baseUrl,
  String? modelName,
  AppLocalizations? l10n,
}) {
  final n = name.trim();
  if (n.isEmpty) return l10n?.validationNameRequired ?? 'name required';

  final key = apiKey.trim();
  final base = (baseUrl ?? '').trim();
  final model = (modelName ?? '').trim();

  if (llmApiKeyIsRequired(provider) && key.isEmpty) {
    return l10n?.validationApiKeyRequiredLlc ?? 'API key required';
  }
  if (llmBaseUrlIsRequired(provider) && base.isEmpty) {
    return l10n?.validationBaseUrlRequiredLlc ?? 'Base URL required';
  }
  if (base.isNotEmpty && Uri.tryParse(base) == null) {
    return l10n?.validationInvalidBaseUrl ?? 'invalid Base URL';
  }
  if (provider.modelNameRequired && model.isEmpty) {
    if (provider == LlmProvider.doubao) {
      return l10n?.validationDoubaoModelEndpointRequired ??
          '需先在火山方舟控制台创建推理接入点，再将获得的接入点 ID 填入此处';
    }
    return l10n?.validationModelNameRequired ?? 'MODEL NAME required';
  }
  final modelErr = validateLlmModelNameInput(provider, model, l10n: l10n);
  if (modelErr != null) {
    return modelErr;
  }

  return null;
}

/// Stricter checks for the "Test Connection" action (must have usable credentials).
String? validateLlmConnectionTest({
  required LlmProvider provider,
  required String name,
  required String apiKey,
  String? accessKeyId,
  String? baseUrl,
  String? modelName,
  AppLocalizations? l10n,
}) {
  // Allow API key in the main field or Access Key ID in advanced options.
  final effectiveKey = apiKey.trim().isNotEmpty
      ? apiKey.trim()
      : (accessKeyId ?? '').trim();
  return validateLlmInputs(
    provider: provider,
    name: name,
    apiKey: effectiveKey,
    baseUrl: baseUrl,
    modelName: modelName,
    l10n: l10n,
  );
}
