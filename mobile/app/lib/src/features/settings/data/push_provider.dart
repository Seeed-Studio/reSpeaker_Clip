import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'push_store.dart';

/// Push enabled state (user preference)
final pushEnabledProvider = StateNotifierProvider<PushEnabledNotifier, bool>((ref) {
  return PushEnabledNotifier();
});

class PushEnabledNotifier extends StateNotifier<bool> {
  PushEnabledNotifier() : super(PushStore.cachedEnabled) {
    PushStore.loadEnabled().then((v) => state = v);
  }

  Future<void> setEnabled(bool enabled) async {
    await PushStore.setEnabled(enabled);
    state = enabled;
  }
}

/// Whether notification permission is granted (system-level)
final notificationPermissionGrantedProvider = FutureProvider<bool>((ref) async {
  try {
    final status = await Permission.notification.status;
    return status.isGranted || status.isLimited || status.isProvisional;
  } catch (_) {
    return false;
  }
});

/// Push token (reserved: after FCM integration call [PushStore.saveToken] in onTokenRefresh and report to server)
final pushTokenProvider = FutureProvider<String?>((ref) async {
  return PushStore.loadToken();
});

/// Request notification permission (call when enabling push)
Future<bool> requestNotificationPermission() async {
  try {
    final status = await Permission.notification.request();
    return status.isGranted || status.isLimited || status.isProvisional;
  } catch (_) {
    return false;
  }
}
