import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// True when the user dismissed the system OAuth sheet (Cancel / Close), not a real failure.
bool isOAuthUserCancelled(Object e) {
  if (e is GoogleSignInException) {
    return e.code == GoogleSignInExceptionCode.canceled ||
        e.code == GoogleSignInExceptionCode.interrupted;
  }
  if (e is SignInWithAppleAuthorizationException) {
    return e.code == AuthorizationErrorCode.canceled;
  }
  if (e is PlatformException) {
    final code = e.code.toLowerCase();
    if (code == 'canceled' ||
        code == 'cancelled' ||
        code.contains('cancel')) {
      return true;
    }
    final msg = (e.message ?? '').toLowerCase();
    if (msg.contains('cancel') || msg.contains('取消')) {
      return true;
    }
  }
  return false;
}
