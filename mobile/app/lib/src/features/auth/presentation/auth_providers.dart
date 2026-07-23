import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/account_scope_invalidation.dart';
import '../../../core/observability/sentry_service.dart';
import '../../../core/server/auth/auth_backend.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/auth/user_profile_store.dart';
import '../../../core/server/sensecraft_auth/sensecraft_api_client.dart';
import '../../../core/server/sensecraft_auth/sensecraft_auth_env.dart';
import '../../../core/server/sensecraft_auth/sensecraft_auth_token_store.dart';
import '../../../core/server/server_providers.dart';
import '../data/auth_repository.dart';
import '../data/auth_session_store.dart';
import '../data/self_hosted_auth_repository.dart';
import '../data/sensecraft_auth_repository.dart';
import '../domain/auth_session.dart';

/// SenseCraft auth HTTP client. Lives on a *different* host than
/// [apiClientProvider]; rebuilt when the user switches `appEnvProvider`.
final senseCraftApiClientProvider = Provider<SenseCraftApiClient>((ref) {
  final env = senseCraftEnvFromAppEnv(ref.watch(appEnvProvider));
  return SenseCraftApiClient(baseUri: SenseCraftAuthEnv.baseUriFor(env));
});

/// The active [AuthRepository] for the current session.
///
/// Picked by [authBackendProvider]:
/// - [AuthBackend.selfHosted] → talks to the project's Go backend directly.
/// - [AuthBackend.senseCraft]  → SenseCraft auth, then exchanges (or falls
///   back) for tokens used by [ApiClient].
///
/// While `authBackendProvider` is loading we default to the compile-time
/// fallback so UI doesn't await on cold start.
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final backend = ref.watch(authBackendProvider).valueOrNull ??
      compileTimeAuthBackendDefault;
  switch (backend) {
    case AuthBackend.selfHosted:
      return SelfHostedAuthRepository(
        emailAuthApi: ref.watch(emailAuthApiProvider),
        authApi: ref.watch(authApiProvider),
        userApi: ref.watch(userApiProvider),
      );
    case AuthBackend.senseCraft:
      return SenseCraftAuthRepository(
        senseCraftClient: ref.watch(senseCraftApiClientProvider),
        businessClient: ref.watch(apiClientProvider),
      );
  }
});

final authSessionProvider = NotifierProvider<AuthSessionController, AuthSession>(AuthSessionController.new);

class AuthSessionController extends Notifier<AuthSession> {
  /// One-shot login email preset (e.g. after change-email logout). Survives
  /// [logoutFully] because router redirect may land on `/login` before query
  /// params are applied to a reused [LoginLandingPage] state.
  static String? pendingLoginPresetEmail;

  @override
  AuthSession build() => AuthSessionStore.cached ?? AuthSession.loggedOut();

  void prepareLoginAfterEmailChange(String email) {
    final e = email.trim();
    pendingLoginPresetEmail = e.isEmpty ? null : e;
  }

  static String? consumePendingLoginPresetEmail() {
    final e = pendingLoginPresetEmail;
    pendingLoginPresetEmail = null;
    return e;
  }

  /// Email login success.
  void setLoggedIn({required String email, bool needsSetPassword = false}) {
    state = state.copyWith(isLoggedIn: true, email: email, needsSetPassword: needsSetPassword);
    unawaited(AuthSessionStore.save(state));
    unawaited(SentryService.setUser(email: email));
  }

  /// Third-party auth success (email not linked yet).
  void setThirdPartyLoggedIn() {
    state = state.copyWith(isLoggedIn: true, email: null, needsSetPassword: true);
    unawaited(AuthSessionStore.save(state));
    unawaited(SentryService.setUser());
  }

  void linkEmail(String email) {
    state = state.copyWith(email: email);
    unawaited(AuthSessionStore.save(state));
  }

  /// Update bound email (local state)
  void updateEmail(String email) {
    final e = email.trim();
    state = state.copyWith(email: e.isEmpty ? null : e);
    unawaited(AuthSessionStore.save(state));
  }

  void markPasswordDone() {
    state = state.copyWith(needsSetPassword: false);
    unawaited(AuthSessionStore.save(state));
  }

  void logout() {
    state = AuthSession.loggedOut();
    invalidateAccountScopedData(ref);
    unawaited(SentryService.clearUser());
    unawaited(AuthSessionStore.clear());
    unawaited(AuthTokenStore.clear());
    // SenseCraft token store is empty on self-hosted backend; clearing is a
    // no-op there but cheap, so always do it to stay safe across switches.
    unawaited(SenseCraftAuthTokenStore.clear());
    unawaited(ref.read(userProfileProvider.notifier).clear());
  }

  /// Same as [logout] but awaits persistence so the next navigation/redirect
  /// cannot observe stale SenseCraft or business JWTs still on disk/memory.
  Future<void> logoutFully() async {
    state = AuthSession.loggedOut();
    invalidateAccountScopedData(ref);
    await SentryService.clearUser();
    await Future.wait([
      AuthSessionStore.clear(),
      AuthTokenStore.clear(),
      SenseCraftAuthTokenStore.clear(),
      UserProfileStore.clear(),
    ]);
    await ref.read(userProfileProvider.notifier).clear();
  }
}

// ---------------- Email login page state ----------------

class EmailLoginUiState {
  final String email;
  final String code;
  final bool agreed;
  final bool sending;
  final bool verifying;
  final int secondsLeft; // resend countdown
  final String? error;

  const EmailLoginUiState({
    required this.email,
    required this.code,
    required this.agreed,
    required this.sending,
    required this.verifying,
    required this.secondsLeft,
    required this.error,
  });

  factory EmailLoginUiState.initial() => const EmailLoginUiState(
        email: '',
        code: '',
        agreed: false,
        sending: false,
        verifying: false,
        secondsLeft: 0,
        error: null,
      );

  EmailLoginUiState copyWith({
    String? email,
    String? code,
    bool? agreed,
    bool? sending,
    bool? verifying,
    int? secondsLeft,
    String? error,
  }) {
    return EmailLoginUiState(
      email: email ?? this.email,
      code: code ?? this.code,
      agreed: agreed ?? this.agreed,
      sending: sending ?? this.sending,
      verifying: verifying ?? this.verifying,
      secondsLeft: secondsLeft ?? this.secondsLeft,
      error: error,
    );
  }
}

final emailLoginControllerProvider =
    NotifierProvider<EmailLoginController, EmailLoginUiState>(EmailLoginController.new);

class EmailLoginController extends Notifier<EmailLoginUiState> {
  Timer? _timer;

  @override
  EmailLoginUiState build() {
    ref.onDispose(() {
      _timer?.cancel();
      _timer = null;
    });
    return EmailLoginUiState.initial();
  }

  void setEmail(String v) => state = state.copyWith(email: v.trim(), error: null);
  void setCode(String v) => state = state.copyWith(code: v.trim(), error: null);
  void setAgreed(bool v) => state = state.copyWith(agreed: v, error: null);

  bool get canSendCode => !state.sending && state.secondsLeft == 0 && _isValidEmail(state.email);
  bool get canVerify =>
      !state.verifying && state.agreed && _isValidEmail(state.email) && _isValidCode(state.code);

  Future<void> sendCode() async {
    if (!canSendCode) return;
    state = state.copyWith(sending: true, error: null);
    try {
      final repo = ref.read(authRepositoryProvider);
      // This controller backs the email *login* screen only (code → session).
      await repo.sendEmailCode(
        email: state.email,
        scene: EmailCodeScene.login,
      );
      _startCountdown(60);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  Future<String> verifyCodeAndLogin() async {
    if (!canVerify) {
      throw StateError('VERIFY_REQUIRED'); // Will be localized in UI layer
    }
    state = state.copyWith(verifying: true, error: null);
    try {
      final result = await ref.read(authRepositoryProvider).verifyEmailCode(
            email: state.email,
            code: state.code,
            scene: EmailCodeScene.login,
          );
      if (result == null) {
        throw StateError('Email login verify returned no session');
      }
      final email = (result.user.email?.trim().isNotEmpty == true)
          ? result.user.email!.trim()
          : state.email;
      ref.read(authSessionProvider.notifier).setLoggedIn(email: email);
      return email;
    } catch (e) {
      state = state.copyWith(error: e.toString());
      unawaited(SentryService.captureLoginFailure(e, method: 'email_code'));
      rethrow;
    } finally {
      state = state.copyWith(verifying: false);
    }
  }

  void _startCountdown(int seconds) {
    _timer?.cancel();
    state = state.copyWith(secondsLeft: seconds);
    var currentSeconds = seconds;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      currentSeconds--;
      if (currentSeconds <= 0) {
        t.cancel();
        _timer = null;
        state = state.copyWith(secondsLeft: 0);
      } else {
        state = state.copyWith(secondsLeft: currentSeconds);
      }
    });
  }

  static bool _isValidEmail(String email) {
    // Simple check; backend can do full validation.
    return email.contains('@') && email.contains('.') && email.length <= 200;
  }

  static bool _isValidCode(String code) {
    final ok = RegExp(r'^\d{6}$').hasMatch(code);
    return ok;
  }
}

