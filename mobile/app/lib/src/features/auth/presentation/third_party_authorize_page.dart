
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../app/router/app_router.dart';
import '../../../app/theme/app_colors.dart';
import '../../../app/theme/app_radii.dart';
import '../../../app/theme/app_typography.dart';
import '../../../core/platform/oauth_android_ui.dart';
import '../../../core/server/auth/auth_backend.dart';
import '../../../core/server/sensecraft_auth/sensecraft_auth_token_store.dart';
import '../../../core/l10n/app_localizations.dart';
import '../../../core/server/api/auth_api.dart';
import '../../../core/server/api/user_api.dart';
import '../../../core/server/auth/auth_token_store.dart';
import '../../../core/server/auth/user_profile_provider.dart';
import '../../../core/server/config/google_oauth_config.dart';
import '../../../core/server/server_error_localizer.dart';
import '../../../core/server/server_exception.dart';
import '../../../core/server/server_providers.dart' show appEnvProvider, kDefaultAppEnv;
import '../../../core/widgets/app_pill_button.dart';
import '../../ai_config/presentation/guide/ai_config_guide_helper.dart';
import '../domain/auth_session.dart';
import 'auth_providers.dart';
import 'oauth_user_cancel.dart';

class ThirdPartyAuthorizePage extends ConsumerWidget {
  final String provider;
  final bool termsAccepted;

  const ThirdPartyAuthorizePage({
    super.key,
    required this.provider,
    this.termsAccepted = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = provider.trim().toLowerCase();
    if (p == 'apple') {
      return _AppleAuthorize(provider: provider);
    }
    return _GenericAuthorize(provider: provider, termsAccepted: termsAccepted);
  }
}

bool _hasPersistedAuthTokens(WidgetRef ref) {
  final backend = ref.read(authBackendProvider).valueOrNull ??
      AuthBackendStore.cached ??
      compileTimeAuthBackendDefault;
  final bizToken = (AuthTokenStore.cached ?? '').trim();
  final scToken = (SenseCraftAuthTokenStore.cached ?? '').trim();
  final scRefresh = (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
  return backend == AuthBackend.senseCraft
      ? (scToken.isNotEmpty || scRefresh.isNotEmpty)
      : bizToken.isNotEmpty;
}

Future<void> _thirdPartyLoginWithBackend(
  BuildContext context,
  WidgetRef ref, {
  required String provider,
  required String accessToken,
  required String idToken,
  String? code,
  String? codeVerifier,
  String? redirectUri,
}) async {
  final repo = ref.read(authRepositoryProvider);
  try {
    debugPrint(
      '[AUTH] appLogin -> provider=$provider accessTokenLen=${accessToken.length} idTokenLen=${idToken.length}'
      ' codeLen=${code?.length ?? 0} verifierLen=${codeVerifier?.length ?? 0} redirect=${redirectUri ?? ""}',
    );
    final result = await repo.appLogin(
      AuthAppLoginRequest(
        provider: provider,
        accessToken: accessToken,
        idToken: idToken,
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: redirectUri,
      ),
    );
    debugPrint('[AUTH] appLogin <- ok, got jwtLen=${result.token.length} email=${result.user.email ?? ""}');
    await AuthTokenStore.saveTokens(accessToken: result.token, refreshToken: result.refreshToken);
    await ref.read(userProfileProvider.notifier).setFromLoginAndRefresh(
          UserProfile.fromAuthAppUser(result.user),
        );

    final email = (result.user.email ?? '').trim();
    ref.read(authSessionProvider.notifier).setLoggedIn(email: email, needsSetPassword: false);
    await OAuthAndroidUi.bringAppToFront();
    await AiConfigGuideHelper.navigateAfterAuthReadyRouter(ref.read(appRouterProvider));
  } catch (e) {
    if (!context.mounted) return;
    debugPrint('[AUTH] appLogin !! provider=$provider error=$e');
    final l10n = AppLocalizations.of(context)!;
    if (e is ServerException) {
      final msg = serverErrorMessage(context, e);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(l10n.loadFailed(e.toString()))));
  }
}

class _GenericAuthorize extends ConsumerStatefulWidget {
  final String provider;
  final bool termsAccepted;
  const _GenericAuthorize({
    required this.provider,
    this.termsAccepted = false,
  });

  @override
  ConsumerState<_GenericAuthorize> createState() => _GenericAuthorizeState();
}

class _GenericAuthorizeState extends ConsumerState<_GenericAuthorize>
    with WidgetsBindingObserver {
  bool _githubOAuthInFlight = false;
  bool _oauthLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_recoverGithubUiIfAlreadyLoggedIn());
    }
  }

  /// Deep link may finish login in the background while the browser stays on top.
  Future<void> _recoverGithubUiIfAlreadyLoggedIn() async {
    if (!_githubOAuthInFlight) return;
    final session = ref.read(authSessionProvider);
    if (!session.isLoggedIn || !_hasPersistedAuthTokens(ref)) return;
    _githubOAuthInFlight = false;
    await OAuthAndroidUi.bringAppToFront();
    await AiConfigGuideHelper.navigateAfterAuthReadyRouter(ref.read(appRouterProvider));
  }

  Future<void> _onAuthorizePressed(BuildContext context, WidgetRef ref) async {
    if (_oauthLoading) return;
    setState(() => _oauthLoading = true);
    try {
      await _runThirdPartyAuth(context, ref);
    } finally {
      if (mounted) setState(() => _oauthLoading = false);
    }
  }

  // Google: Web client ID → `GoogleSignIn.initialize(serverClientId: …)` and
  // SenseCraft `id_token.aud`. Override: `--dart-define=GOOGLE_SERVER_CLIENT_ID=…`.
  // Env mapping: prod/release → PROD web; test/dev/local → DEV web (see [googleWebClientIdForAppEnv]).
  static const String _googleServerClientIdOverride =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID', defaultValue: '');

  static const String _githubClientId = String.fromEnvironment(
    'GITHUB_CLIENT_ID',
    // GitHub App / OAuth App client id (must match the app whose Callback URL
    // lists `sensecraftvoice://oauth-callback`). Empty by default so GitHub
    // login stays disabled until you inject your own client id via
    // `--dart-define=GITHUB_CLIENT_ID=...`
    defaultValue: '',
  );
  /// Must match GitHub App / OAuth App callback URL, Android
  /// `CallbackActivity` intent-filter, and iOS `CFBundleURLSchemes`.
  /// Lowercase scheme only: `flutter_web_auth_2` rejects uppercase in
  /// [FlutterWebAuth2.authenticate] `callbackUrlScheme` (`^[a-z][a-z\d+.-]*$`); RFC 3986 also normalizes schemes to lowercase.
  static const String _githubCallbackScheme = 'sensecraftvoice';
  static const String _githubRedirectUri = 'sensecraftvoice://oauth-callback';

  String _providerIconAsset(String provider) {
    final p = provider.trim().toLowerCase();
    switch (p) {
      case 'apple':
        return 'assets/png/apple.png';
      case 'google':
        return 'assets/png/google.png';
      case 'github':
      default:
        return 'assets/png/github.png';
    }
  }

  /// Detects the google_sign_in_ios `invalid_grant` failure that happens when a
  /// cached Google credential was expired/revoked and restorePreviousSignIn is
  /// triggered internally — surfaced as
  /// `PlatformException(org.openid.appauth.oauth_token: -10, invalid_grant ...)`.
  /// See flutter/packages#11349. Recovery is to clear the session and retry.
  bool _isGoogleInvalidGrantError(Object e) {
    if (e is PlatformException) {
      final code = e.code.toLowerCase();
      final msg = (e.message ?? '').toLowerCase();
      final details = (e.details?.toString() ?? '').toLowerCase();
      return code.contains('appauth') ||
          msg.contains('invalid_grant') ||
          details.contains('invalid_grant');
    }
    return false;
  }

  Future<String> _resolveGoogleServerClientId(WidgetRef ref) async {
    final override = _googleServerClientIdOverride.trim();
    if (override.isNotEmpty) return override;

    final env = ref.read(appEnvProvider).valueOrNull ?? kDefaultAppEnv;
    return googleWebClientIdForAppEnv(env);
  }

  Future<void> _runThirdPartyAuth(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    if (!widget.termsAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.agreeToTermsRequired)),
      );
      if (context.canPop()) context.pop();
      return;
    }
    final p = widget.provider.trim().toLowerCase();
    if (p == 'google') {
      try {
        final serverClientId = await _resolveGoogleServerClientId(ref);
        debugPrint(
          '[AUTH] google serverClientId.len=${serverClientId.length} '
          'prefix=${serverClientId.length > 24 ? serverClientId.substring(0, 24) : serverClientId}…',
        );
        final scopes = <String>['email', 'profile', 'openid'];
        final google = GoogleSignIn.instance;
        if (serverClientId.isNotEmpty) {
          await google.initialize(serverClientId: serverClientId);
        } else {
          await google.initialize();
        }

        // authenticate() / authorizationForScopes() use restorePreviousSignIn
        // internally, which on iOS throws
        // `PlatformException(org.openid.appauth.oauth_token: -10, invalid_grant)`
        // when the cached Google credential was expired/revoked (the known
        // google_sign_in_ios bug — flutter/packages#11349). On that error we
        // clear the stale cached session and retry one fresh interactive
        // sign-in.
        Future<(String, String)> acquireTokens() async {
          debugPrint('[AUTH] google authenticate(scopeHint=$scopes)…');
          final acc = await google.authenticate(scopeHint: scopes);
          debugPrint('[AUTH] google authenticate ok email=${acc.email}');

          debugPrint('[AUTH] google authorizationForScopes / authorizeScopes…');
          final GoogleSignInClientAuthorization authz =
              await acc.authorizationClient.authorizationForScopes(scopes) ??
                  await acc.authorizationClient.authorizeScopes(scopes);

          return (
            authz.accessToken.trim(),
            (acc.authentication.idToken ?? '').trim(),
          );
        }

        String accessToken;
        String idToken;
        try {
          (accessToken, idToken) = await acquireTokens();
        } catch (e) {
          if (!_isGoogleInvalidGrantError(e)) rethrow;
          debugPrint(
            '[AUTH] google invalid_grant on cached credential — clearing '
            'session and retrying a fresh sign-in',
          );
          try {
            await google.signOut();
          } catch (_) {}
          (accessToken, idToken) = await acquireTokens();
        }
        debugPrint(
          '[AUTH] google tokens accessLen=${accessToken.length} idTokenLen=${idToken.length}',
        );

        if (accessToken.isEmpty || idToken.isEmpty) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                serverClientId.isEmpty
                    ? l10n.googleSignInNoTokenAndroid
                    : '${l10n.googleSignInNoTokenGeneric} (access=${accessToken.isEmpty}, id=${idToken.isEmpty})',
              ),
            ),
          );
          return;
        }
        if (!context.mounted) return;
        await _thirdPartyLoginWithBackend(
          context,
          ref,
          provider: p,
          accessToken: accessToken,
          idToken: idToken,
        );
      } on GoogleSignInException catch (e) {
        debugPrint(
          '[AUTH] google GoogleSignInException code=${e.code} '
          'desc=${e.description} details=${e.details}',
        );
        if (!context.mounted) return;
        if (isOAuthUserCancelled(e)) return;
        if (e.code == GoogleSignInExceptionCode.uiUnavailable) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.googleSignInFailedCode(e.code.name))),
          );
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.googleSignInFailedCode(e.code.name))),
        );
      } catch (e, st) {
        debugPrint('[AUTH] google unexpected error=$e\n$st');
        if (!context.mounted) return;
        if (isOAuthUserCancelled(e)) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.googleSignInFailed(e.toString()))),
        );
      }
      return;
    }

    if (p == 'apple') {
      // Apple: use native sign-in to obtain identityToken + authorizationCode.
      //
      // NOTE: On iOS, error 1000 + AKAuthenticationError -7026 is usually
      // caused by missing/invalid "Sign in with Apple" capability or provisioning.
      try {
        final available = await SignInWithApple.isAvailable();
        if (!available) {
          if (!context.mounted) return;
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.appleSignInNotSupported)),
          );
          return;
        }

        final credential = await SignInWithApple.getAppleIDCredential(
          scopes: [AppleIDAuthorizationScopes.email],
        );
        final idToken = (credential.identityToken ?? '').trim();
        final accessToken = (credential.authorizationCode).trim();
        if (accessToken.isEmpty || idToken.isEmpty) {
          if (!context.mounted) return;
          final l10n = AppLocalizations.of(context)!;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.appleSignInNoToken)),
          );
          return;
        }
        if (!context.mounted) return;
        await _thirdPartyLoginWithBackend(context, ref, provider: p, accessToken: accessToken, idToken: idToken);
        return;
      } on SignInWithAppleAuthorizationException catch (e) {
        if (!context.mounted) return;
        if (e.code == AuthorizationErrorCode.canceled) return;
        final l10n = AppLocalizations.of(context)!;
        final msg = switch (e.code) {
          AuthorizationErrorCode.notHandled => l10n.appleSignInNotHandled,
          AuthorizationErrorCode.notInteractive => l10n.appleSignInNotInteractive,
          AuthorizationErrorCode.credentialExport => l10n.appleSignInCredentialExport,
          AuthorizationErrorCode.credentialImport => l10n.appleSignInCredentialImport,
          AuthorizationErrorCode.matchedExcludedCredential => l10n.appleSignInMatchedExcluded,
          AuthorizationErrorCode.failed => l10n.appleSignInFailed,
          AuthorizationErrorCode.invalidResponse => l10n.appleSignInInvalidResponse,
          AuthorizationErrorCode.unknown => l10n.appleSignInUnknown,
          AuthorizationErrorCode.canceled => l10n.appleSignInCanceled,
        };
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        return;
      } catch (e) {
        if (!context.mounted) return;
        if (isOAuthUserCancelled(e)) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.appleSignInError(e.toString()))),
        );
        return;
      }
    }

    if (p == 'github') {
      if (_githubClientId.trim().isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.githubSignInNotConfigured)),
        );
        return;
      }
      try {
        _githubOAuthInFlight = true;
        debugPrint('[AUTH] github start authorize, clientId=${_githubClientId.substring(0, 4)}... scheme=$_githubCallbackScheme redirect=$_githubRedirectUri');
        final r = await _githubOAuthPkce(clientId: _githubClientId, l10n: l10n);
        debugPrint('[AUTH] github pkce result codeLen=${r.code.length} verifierLen=${r.verifier.length}');
        // Always authorization code flow; backend exchanges with GitHub
        if (!context.mounted) return;
        await _thirdPartyLoginWithBackend(
          context,
          ref,
          provider: p,
          accessToken: '',
          idToken: '',
          code: r.code,
          codeVerifier: r.verifier.isEmpty ? null : r.verifier,
          redirectUri: _githubRedirectUri,
        );
        _githubOAuthInFlight = false;
        return;
      } catch (e) {
        _githubOAuthInFlight = false;
        if (!context.mounted) return;
        debugPrint('[AUTH] github !! $e');
        if (isOAuthUserCancelled(e)) {
          await _recoverGithubUiIfAlreadyLoggedIn();
          return;
        }
        final msg = e.toString().trim().isEmpty
            ? l10n.githubSignInFailedShort
            : e.toString();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        return;
      }
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.oauthUnsupportedProvider)));
  }

  static String _randomString(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// GitHub authorization-code flow in the system browser, then deep-link back into the app.
  ///
  /// We do **not** send PKCE (`code_challenge`) today — GitHub's native app flow still works
  /// with a public OAuth App when the backend exchanges `code` using the app's client_secret.
  /// The returned verifier is always empty; kept in the return type so callers can pass
  /// [AuthAppLoginRequest.codeVerifier] unchanged if we add PKCE later.
  static Future<({String code, String verifier})> _githubOAuthPkce({
    required String clientId,
    required AppLocalizations l10n,
  }) async {
    final state = _randomString(24);
    const scope = 'read:user user:email';

    final authUri = Uri.https('github.com', '/login/oauth/authorize', {
      'client_id': clientId,
      'redirect_uri': _githubRedirectUri,
      'scope': scope,
      'state': state,
    });

    // This launches an external browser / SFSafariViewController, and returns the callback URL.
    debugPrint('[AUTH] github open browser: $authUri');
    final resultUrl = await FlutterWebAuth2.authenticate(
      url: authUri.toString(),
      callbackUrlScheme: _githubCallbackScheme,
      options: const FlutterWebAuth2Options(
        // Prefer Chrome Custom Tabs on Android (Huawei stock browser often
        // shows "Open App" without delivering the callback intent reliably).
        customTabsPackageOrder: [
          'com.android.chrome',
          'com.chrome.beta',
          'com.microsoft.emmx',
          'org.mozilla.firefox',
        ],
      ),
    );
    debugPrint('[AUTH] github callback url: $resultUrl');

    final cb = Uri.parse(resultUrl);
    final returnedState = cb.queryParameters['state'] ?? '';
    if (returnedState != state) {
      throw StateError(l10n.oauthGitHubStateMismatch);
    }
    final code = cb.queryParameters['code'];
    if (code == null || code.trim().isEmpty) {
      throw StateError(l10n.oauthGitHubMissingCode);
    }
    final trimmedCode = code.trim();
    debugPrint('[AUTH] github got code len=${trimmedCode.length}');

    // No PKCE: return code only (empty verifier for existing callers)
    return (code: trimmedCode, verifier: '');
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthSession>(authSessionProvider, (prev, next) {
      if (_githubOAuthInFlight && next.isLoggedIn && _hasPersistedAuthTokens(ref)) {
        _githubOAuthInFlight = false;
        unawaited(() async {
          await OAuthAndroidUi.bringAppToFront();
          await AiConfigGuideHelper.navigateAfterAuthReadyRouter(ref.read(appRouterProvider));
        }());
      }
    });

    final l10n = AppLocalizations.of(context)!;
    final primaryLabel = l10n.oauthAllowAccess;
    final iconAsset = _providerIconAsset(widget.provider);
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      body: Stack(
        children: [
          SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.r28),
                  border: Border.all(color: AppColors.borderLight),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _LogoChip(
                          compact: true,
                          child: const _AppIconSquare(size: 40),
                        ),
                        const SizedBox(width: 14),
                        Icon(Icons.swap_horiz, color: AppColors.textTertiary.withValues(alpha: 0.8)),
                        const SizedBox(width: 14),
                        _LogoChip(
                          compact: true,
                          child: Image.asset(iconAsset, width: 30, height: 30, fit: BoxFit.contain),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: const TextStyle(
                            fontSize: AppTypography.s18,
                          height: 1.25,
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w500,
                        ),
                        children: [
                          TextSpan(
                            text: l10n.oauthPartnerProductName,
                            style: const TextStyle(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.w500,
                                fontSize: AppTypography.s18),
                          ),
                          TextSpan(
                            text: l10n.oauthWantsAccessAfterBrand,
                            style: const TextStyle(
                                color: AppColors.textSecondary,
                                fontWeight: FontWeight.w500,
                                fontSize: AppTypography.s18),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.oauthReTerminalSyncDescription,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: AppTypography.s12,
                        height: 1.35,
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 18),
                    _PermissionsCard(provider: widget.provider, l10n: l10n),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.verified_user_outlined,
                            size: 16, color: AppColors.textTertiary),
                        const SizedBox(width: 8),
                        Text(
                          l10n.oauthSecureIndustrialTunnel,
                          style: const TextStyle(
                            fontSize: AppTypography.s12,
                            color: AppColors.textTertiary,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    AppPrimaryPillButton(
                      label: primaryLabel,
                      height: 56,
                      onPressed: _oauthLoading ? null : () => _onAuthorizePressed(context, ref),
                      textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
                    ),
                    const SizedBox(height: 12),
                    AppOutlinedPillButton(
                      label: l10n.cancel,
                      height: 56,
                      onPressed: _oauthLoading
                          ? null
                          : () {
                        final router = GoRouter.of(context);
                        if (router.canPop()) {
                          router.pop();
                        } else {
                          router.go('/login');
                        }
                      },
                      foregroundColor: AppColors.textSecondary,
                      borderColor: AppColors.borderLight,
                      textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: AppTypography.s16),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
          if (_oauthLoading)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: Material(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.r18),
                    elevation: 8,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 36,
                            height: 36,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            l10n.signingIn,
                            style: const TextStyle(
                              fontSize: AppTypography.s16,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AppleAuthorize extends ConsumerWidget {
  final String provider;
  const _AppleAuthorize({required this.provider});

  Future<void> _runAppleAuth(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final available = await SignInWithApple.isAvailable();
      if (!available) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.appleSignInNotSupported)),
        );
        return;
      }

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
      );
      final idToken = (credential.identityToken ?? '').trim();
      final accessToken = credential.authorizationCode.trim();
      if (accessToken.isEmpty || idToken.isEmpty) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.appleSignInNoToken)),
        );
        return;
      }
      if (!context.mounted) return;
      await _thirdPartyLoginWithBackend(
        context,
        ref,
        provider: 'apple',
        accessToken: accessToken,
        idToken: idToken,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (!context.mounted) return;
      if (e.code == AuthorizationErrorCode.canceled) return;
      final msg = switch (e.code) {
        AuthorizationErrorCode.notHandled => l10n.appleSignInNotHandled,
        AuthorizationErrorCode.notInteractive => l10n.appleSignInNotInteractive,
        AuthorizationErrorCode.credentialExport => l10n.appleSignInCredentialExport,
        AuthorizationErrorCode.credentialImport => l10n.appleSignInCredentialImport,
        AuthorizationErrorCode.matchedExcludedCredential => l10n.appleSignInMatchedExcluded,
        AuthorizationErrorCode.failed => l10n.appleSignInFailed,
        AuthorizationErrorCode.invalidResponse => l10n.appleSignInInvalidResponse,
        AuthorizationErrorCode.unknown => l10n.appleSignInUnknown,
        AuthorizationErrorCode.canceled => l10n.appleSignInCanceled,
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    } catch (e) {
      if (!context.mounted) return;
      if (isOAuthUserCancelled(e)) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.appleSignInError(e.toString()))),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.appBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton(
                onPressed: () {
                  final router = GoRouter.of(context);
                  if (router.canPop()) {
                    router.pop();
                  } else {
                    router.go('/login');
                  }
                },
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: const Color(0xFF1677FF),
                  textStyle: const TextStyle(fontSize: AppTypography.s18, fontWeight: FontWeight.w500),
                ),
                child: Text(l10n.cancel),
              ),
              const SizedBox(height: 18),
              const Center(child: _AppIconSquare(size: 56)),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  l10n.appleOauthPageTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: AppTypography.s22,
                    height: 1.18,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                  l10n.appleOauthPageSubtitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: AppTypography.s12,
                    height: 1.35,
                    color: AppColors.textTertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              Center(
                child: SignInWithAppleButton(
                  onPressed: () => _runAppleAuth(context, ref),
                  style: SignInWithAppleButtonStyle.black,
                  height: 56,
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogoChip extends StatelessWidget {
  final Widget child;
  final bool compact;
  const _LogoChip({required this.child, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: compact ? 54 : 64,
      height: compact ? 54 : 64,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Center(
        child: compact ? child : Padding(padding: const EdgeInsets.all(10), child: child),
      ),
    );
  }
}

class _AppIconSquare extends StatelessWidget {
  final double size;
  const _AppIconSquare({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.brandPrimary,
        borderRadius: BorderRadius.circular(AppRadii.r14),
      ),
      child: const Icon(Icons.terminal, color: Colors.white),
    );
  }
}

class _PermissionsCard extends StatelessWidget {
  final String provider;
  final AppLocalizations l10n;
  const _PermissionsCard({required this.provider, required this.l10n});

  @override
  Widget build(BuildContext context) {
    final p = provider.trim().toLowerCase();
    final items = p == 'github'
        ? [
            _PermItem(
              icon: Icons.person_outline,
              title: l10n.oauthGithubPermReadProfileTitle,
              subtitle: l10n.oauthGithubPermReadProfileSubtitle,
            ),
            _PermItem(
              icon: Icons.mail_outline,
              title: l10n.oauthGithubPermEmailTitle,
              subtitle: l10n.oauthGithubPermEmailSubtitle,
            ),
          ]
        : [
            _PermItem(
              icon: Icons.check_circle_outline,
              title: l10n.oauthPermViewProfileTitle,
              subtitle: l10n.oauthPermViewProfileSubtitle,
            ),
            _PermItem(
              icon: Icons.check_circle_outline,
              title: l10n.oauthPermManageHwTitle,
              subtitle: l10n.oauthPermManageHwSubtitle,
            ),
          ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceSubtle,
        borderRadius: BorderRadius.circular(AppRadii.r18),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            items[i],
            if (i != items.length - 1) const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

class _PermItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _PermItem({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: AppColors.brandPrimary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: AppTypography.s16, fontWeight: FontWeight.w500, color: AppColors.textPrimary),
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle( height: 1.3, fontSize: AppTypography.s12, color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}


