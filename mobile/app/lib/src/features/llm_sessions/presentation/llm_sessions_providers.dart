import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/llm_session_remote_repository.dart';
import '../domain/llm_session.dart';

final llmSessionsProvider = FutureProvider<List<LlmSession>>((ref) async {
  final repo = await ref.watch(llmSessionRemoteRepositoryProvider.future);
  return repo.listSessionsPreferRemote();
});
