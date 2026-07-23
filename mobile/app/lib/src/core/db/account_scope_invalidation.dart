import '../../features/ai_config/data/prompt_template_remote_repository.dart';
import '../../features/ai_config/presentation/ai_config_providers.dart';
import '../../features/llm_sessions/data/llm_session_repository.dart';
import '../../features/recordings/data/folders_repository.dart';
import '../../features/recordings/data/recordings_repository.dart';
import '../../features/recordings/presentation/folders_providers.dart';
import '../../features/recordings/presentation/recordings_controller.dart';
import 'db_provider.dart';

/// Drop cached DB handles + list UI when the logged-in account changes.
///
/// Does NOT touch the device list / BLE link: [globalDatabaseProvider] holds
/// `devices` and is account-independent, and the live connection is hardware.
void invalidateAccountScopedData(dynamic ref) {
  ref.invalidate(databaseProvider);
  ref.invalidate(recordingsRepositoryProvider);
  ref.invalidate(foldersRepositoryProvider);
  ref.invalidate(promptTemplateRemoteRepositoryProvider);
  ref.invalidate(sttConfigsProvider);
  ref.invalidate(llmConfigsProvider);
  ref.invalidate(promptTemplatesProvider);
  ref.invalidate(llmSessionRepositoryProvider);

  ref.invalidate(recordingsListProvider);
  ref.invalidate(recordingsListPagedNotifierProvider);
  ref.invalidate(recordingsFilterCountsProvider);
  ref.invalidate(recordingsRowCountProvider);
  ref.invalidate(transferringBannerRecordingProvider);
  ref.invalidate(foldersListProvider);
  ref.invalidate(validateLocalPathsProvider);
}
