import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/asr_config_repository.dart';
import '../data/llm_config_remote_repository.dart';
import '../data/prompt_template_remote_repository.dart';
import '../domain/llm_config.dart';
import '../domain/prompt_template.dart';
import '../domain/stt_config.dart';

final sttConfigsProvider = FutureProvider<List<SttConfig>>((ref) async {
  final asrRepo = await ref.watch(asrConfigRepositoryProvider.future);
  return asrRepo.fetchConfigList();
});

final llmConfigsProvider = FutureProvider<List<LlmConfig>>((ref) async {
  final remoteRepo = await ref.watch(llmConfigRemoteRepositoryProvider.future);
  return remoteRepo.fetchConfigList();
});

/// Prompt templates from API only (public + user), no local SQLite cache.
final promptTemplatesProvider =
    FutureProvider<List<PromptTemplate>>((ref) async {
  final repo = ref.watch(promptTemplateRemoteRepositoryProvider);
  return repo.fetchTemplateList();
});

bool _shouldRetryConfigList<T>(AsyncValue<List<T>> asyncValue) {
  if (asyncValue.hasError ||
      (!asyncValue.hasValue && !asyncValue.isLoading)) {
    return true;
  }
  return asyncValue.valueOrNull?.isEmpty == true;
}

/// Retry when load failed, never settled, or settled empty (public templates
/// should normally exist after a successful `/llm/prompt/public` fetch).
bool _shouldRetryPromptTemplates(AsyncValue<List<PromptTemplate>> asyncValue) {
  if (_shouldRetryConfigList(asyncValue)) return true;
  final list = asyncValue.valueOrNull;
  return list != null && list.isEmpty;
}

Future<void> ensureSttConfigsLoaded(WidgetRef ref, {bool force = false}) async {
  final current = ref.read(sttConfigsProvider);
  if (!force && !_shouldRetryConfigList(current)) {
    return;
  }
  ref.invalidate(sttConfigsProvider);
  try {
    await ref.read(sttConfigsProvider.future);
  } catch (_) {
    // Keep the provider in error state for the UI, but do not crash callers.
  }
}

Future<void> ensureLlmConfigsLoaded(WidgetRef ref, {bool force = false}) async {
  final current = ref.read(llmConfigsProvider);
  if (!force && !_shouldRetryConfigList(current)) {
    return;
  }
  ref.invalidate(llmConfigsProvider);
  try {
    await ref.read(llmConfigsProvider.future);
  } catch (_) {
    // Keep the provider in error state for the UI, but do not crash callers.
  }
}

Future<void> ensurePromptTemplatesLoaded(
  WidgetRef ref, {
  bool force = false,
}) async {
  final current = ref.read(promptTemplatesProvider);
  if (!force && !_shouldRetryPromptTemplates(current)) {
    return;
  }
  ref.invalidate(promptTemplatesProvider);
  try {
    await ref.read(promptTemplatesProvider.future);
  } catch (_) {
    // Keep the provider in error state for the UI, but do not crash callers.
  }
}
