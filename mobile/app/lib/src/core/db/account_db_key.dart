import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/presentation/auth_providers.dart';
import '../server/auth/user_profile_provider.dart';

/// Stable per-account key for SQLite (`respeaker_app_{userId}.db`) and file dirs.
///
/// Only [UserProfile.id] (> 0) is used — never email — so one user cannot
/// open two databases during profile load.
final accountDbKeyProvider = Provider<String?>((ref) {
  final session = ref.watch(authSessionProvider);
  if (!session.isLoggedIn) return null;

  final profileId = ref.watch(userProfileProvider)?.id;
  if (profileId != null && profileId > 0) {
    return profileId.toString();
  }

  return null;
});

/// Throws when logged-in but profile id is not ready yet.
String requireAccountDbKey(dynamic ref) {
  final key = ref.read(accountDbKeyProvider) as String?;
  if (key == null || key.isEmpty) {
    throw StateError(
      'Account scope unavailable: log in and wait for profile to load',
    );
  }
  return key;
}
