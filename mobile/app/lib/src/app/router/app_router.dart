import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/app_localizations.dart';
import '../../features/home/presentation/home_shell_page.dart';
import '../../features/device/presentation/device_page.dart';
import '../../features/device/presentation/device_details_page.dart';
import '../../features/device/presentation/firmware_update_page.dart';
import '../../features/device/presentation/wifi_transfer_page.dart';
import '../../features/recordings/presentation/recordings_page.dart';
import '../../features/recordings/presentation/recordings_search_page.dart';
import '../../features/recordings/presentation/recording_detail_page.dart';
import '../../features/recordings/presentation/recording_trim_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/settings/presentation/personal_information_page.dart';
import '../../features/settings/presentation/language_page.dart';
import '../../features/settings/presentation/help_feedback_page.dart';
import '../../features/settings/presentation/follow_us_page.dart';
import '../../features/settings/presentation/delete_account_page.dart';
import '../../features/settings/presentation/change_password_page.dart';
import '../../features/settings/presentation/permissions_page.dart';
import '../../features/settings/presentation/change_email_page.dart';
import '../../features/ai_config/presentation/ai_config_page.dart';
import '../../features/ai_config/presentation/guide/ai_config_guide_flow_page.dart';
import '../../features/ai_config/presentation/guide/ai_config_guide_helper.dart';
import '../../features/ai_config/presentation/llm_configs_page.dart';
import '../../features/ai_config/presentation/prompt_templates_page.dart';
import '../../features/ai_config/presentation/stt_configs_page.dart';
import '../../features/auth/presentation/login_landing_page.dart';
import '../../features/auth/presentation/email_login_page.dart';
import '../../features/auth/presentation/password_login_page.dart';
import '../../features/auth/presentation/forgot_password_page.dart';
import '../../features/auth/presentation/set_password_page.dart';
import '../../features/auth/presentation/link_identity_page.dart';
import '../../features/auth/presentation/third_party_authorize_page.dart';
import '../../features/auth/presentation/register_email_page.dart';
import '../../features/auth/presentation/register_verify_code_page.dart';
import '../../features/auth/presentation/auth_providers.dart';
import '../../core/server/auth/auth_backend.dart';
import '../../core/server/auth/auth_token_store.dart';
import '../../core/server/sensecraft_auth/sensecraft_auth_token_store.dart';

/// Auth switch: when true, unauthenticated users go to login.
const bool kAuthEnabled = true;

class _RouterRefreshNotifier extends ChangeNotifier {
  void refresh() => notifyListeners();
}

final appRouterProvider = Provider<GoRouter>((ref) {
  // Important: do not watch session here, or auth change would rebuild GoRouter and reset current page to initialLocation.
  final refresh = _RouterRefreshNotifier();
  ref.onDispose(refresh.dispose);
  ref.listen(authSessionProvider, (_, __) => refresh.refresh());
  ref.listen(authBackendProvider, (_, __) => refresh.refresh());
  ref.listen(aiConfigGuideDoneProvider, (_, __) => refresh.refresh());
  // SenseCraft token store bumps on save/clear (e.g. background refresh
  // failure clears it). Listen so the redirect guard reruns and kicks the
  // user back to /login the moment their SC session implicitly dies.
  void onScTokenChange() => refresh.refresh();
  SenseCraftAuthTokenStore.changeNotifier.addListener(onScTokenChange);
  ref.onDispose(() =>
      SenseCraftAuthTokenStore.changeNotifier.removeListener(onScTokenChange));

  return GoRouter(
    // Entry: go to recordings (Files) home; redirect to login if not logged in
    initialLocation: '/recordings',
    refreshListenable: refresh,
    redirect: (context, state) {
      if (!kAuthEnabled) return null;

      final session = ref.read(authSessionProvider);

      // In SenseCraft mode every `/api/v1/user/*` call needs a SenseCraft
      // access token in the Authorization header (legacy `portalApiRequest`
      // contract), and the business JWT can NOT substitute for it — auth
      // and business backends sign different tokens. So if the SC token
      // store is empty we treat the session as logged-out, even when the
      // exchanged business JWT is still cached. This forces a fresh SC
      // login so [SenseCraftAuthTokenStore] gets populated, instead of
      // silently letting user-center calls hit the gateway anonymously
      // (which the gateway reports as 10009 "Lack of necessary parameters").
      //
      // Refresh-token-only is treated as "has token": the next protected
      // request will trigger [SenseCraftApiClient]'s pre-flight refresh and
      // mint a new access token without bouncing through /login.
      final backend = ref.read(authBackendProvider).valueOrNull ??
          AuthBackendStore.cached ??
          compileTimeAuthBackendDefault;
      final bizToken = (AuthTokenStore.cached ?? '').trim();
      final scToken = (SenseCraftAuthTokenStore.cached ?? '').trim();
      final scRefresh =
          (SenseCraftAuthTokenStore.refreshTokenCached ?? '').trim();
      final hasToken = backend == AuthBackend.senseCraft
          ? (scToken.isNotEmpty || scRefresh.isNotEmpty)
          : bizToken.isNotEmpty;

      final loc = state.uri.toString();
      final isAuthRoute = loc.startsWith('/login') ||
          loc.startsWith('/register') ||
          loc.startsWith('/link-identity') ||
          loc.startsWith('/set-password');

      if (!session.isLoggedIn || !hasToken) {
        // Not logged in: only allow auth-related pages
        return isAuthRoute ? null : '/login';
      }

      // Logged in but must finish onboarding (link email / set password).
      if (session.needsSetPassword) {
        // If third-party login has no email yet, force to link-identity first.
        if (session.email == null) {
          // Allow navigation to link-identity or login pages
          if (loc.startsWith('/link-identity') || loc.startsWith('/login')) {
            return null;
          }
          return '/link-identity';
        }
        // Email exists (email login or linked), now can set password (or skip).
        // Allow user to continue email register/login during onboarding (switch account, add email, etc.).
        if (loc.startsWith('/set-password') ||
            loc.startsWith('/link-identity') ||
            loc.startsWith('/login') ||
            loc.startsWith('/register')) {
          return null;
        }
        return '/set-password';
      }

      // First login: STT/LLM setup guide (any auth method).
      // Prefer [AiConfigGuideHelper.cachedDone]: [markDone] sets it synchronously
      // before [aiConfigGuideDoneProvider] reloads, so skip would otherwise bounce back here.
      final guideDone = ref.read(aiConfigGuideDoneProvider);
      final needsGuide = !AiConfigGuideHelper.cachedDone &&
          guideDone.hasValue &&
          guideDone.value == false;
      if (needsGuide && !loc.startsWith('/ai-config/guide')) {
        return '/ai-config/guide';
      }

      // Logged in and ready: prevent going back to auth screens.
      if (isAuthRoute) {
        return needsGuide ? '/ai-config/guide' : '/recordings';
      }

      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) {
          final emailParam = state.uri.queryParameters['email'];
          final preset = (emailParam ?? '').trim().isEmpty ? null : emailParam!.trim();
          final rawChanged = (state.uri.queryParameters['email_changed'] ?? '').toLowerCase();
          final showEmailChangedToast = rawChanged == '1' || rawChanged == 'true';
          return LoginLandingPage(
            key: ValueKey('login-${preset ?? ''}-$showEmailChangedToast'),
            presetEmail: preset,
            showEmailChangedToast: showEmailChangedToast,
          );
        },
      ),
      GoRoute(
        path: '/login/email',
        redirect: (context, state) {
          final email = (state.uri.queryParameters['email'] ?? '').trim();
          return email.isEmpty ? '/login' : null;
        },
        builder: (context, state) {
          final email = (state.uri.queryParameters['email'] ?? '').trim();
          final rawSent = (state.uri.queryParameters['code_sent'] ?? '').toLowerCase();
          final codeAlreadySent = rawSent == '1' || rawSent == 'true';
          return EmailLoginPage(email: email, codeAlreadySent: codeAlreadySent);
        },
      ),
      GoRoute(
        path: '/login/password',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          return PasswordLoginPage(presetEmail: email);
        },
      ),
      GoRoute(
        path: '/login/forgot-password',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          return ForgotPasswordPage(presetEmail: email);
        },
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          return RegisterEmailPage(presetEmail: email);
        },
      ),
      GoRoute(
        path: '/register/verify',
        builder: (context, state) {
          final email = (state.uri.queryParameters['email'] ?? '').trim();
          final rawEntry = state.uri.queryParameters['entry'] ?? 'landing';
          final backTarget = rawEntry == 'register'
              ? RegisterVerifyBackTarget.registerEmail
              : RegisterVerifyBackTarget.landing;
          return RegisterVerifyCodePage(email: email, backTarget: backTarget);
        },
      ),
      GoRoute(
        path: '/login/authorize',
        builder: (context, state) {
          final provider = state.uri.queryParameters['provider'] ?? 'apple';
          // Apple login now triggers system auth directly on login page, no intermediate page.
          if (provider.trim().toLowerCase() == 'apple') {
            return const LoginLandingPage();
          }
          final agreed = state.uri.queryParameters['agreed'] == '1';
          return ThirdPartyAuthorizePage(
            provider: provider,
            termsAccepted: agreed,
          );
        },
      ),
      GoRoute(
        path: '/link-identity',
        builder: (context, state) {
          final provider = state.uri.queryParameters['provider'] ?? 'apple';
          return LinkIdentityPage(provider: provider);
        },
      ),
      GoRoute(
        path: '/set-password',
        builder: (context, state) {
          final purpose = state.uri.queryParameters['purpose'];
          final email = state.uri.queryParameters['email'];
          final code = state.uri.queryParameters['code'];
          final registerCodeRaw = state.uri.queryParameters['registerCode']?.trim();
          final String? registerCode =
              registerCodeRaw == null || registerCodeRaw.isEmpty ? null : registerCodeRaw;
          final verifyEntry = state.uri.queryParameters['verifyEntry'];
          return SetPasswordPage(
            purpose: purpose,
            emailOverride: email,
            resetCode: code,
            registerCode: registerCode,
            registerVerifyEntry: verifyEntry,
          );
        },
      ),
      // AI config guide after first login: outside Shell to avoid bottom TabBar interference
      GoRoute(
        path: '/ai-config/guide',
        builder: (context, state) => const AiConfigGuideFlowPage(),
      ),
      ShellRoute(
        builder: (context, state, child) {
          return HomeShellPage(child: child);
        },
        routes: [
          GoRoute(
            path: '/devices',
            pageBuilder: (context, state) => const NoTransitionPage(child: DevicePage()),
          ),
          GoRoute(
            path: '/recordings',
            pageBuilder: (context, state) => const NoTransitionPage(child: RecordingsPage()),
          ),
          GoRoute(
            path: '/recordings/search',
            builder: (context, state) => const RecordingsSearchPage(),
          ),
          GoRoute(
            path: '/recordings/:id',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return RecordingDetailPage(recordingId: id);
            },
          ),
          GoRoute(
            path: '/recordings/:id/trim',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return RecordingTrimPage(recordingId: id);
            },
          ),
          GoRoute(
            path: '/device/:id',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return DeviceDetailsPage(deviceId: id);
            },
          ),
          GoRoute(
            path: '/device/:id/firmware',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return FirmwareUpdatePage(deviceId: id);
            },
          ),
          GoRoute(
            path: '/device/:id/wifi-transfer',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              final sessionId = state.uri.queryParameters['session'];
              final recordingId = state.uri.queryParameters['recording'];
              return WifiTransferPage(
                deviceId: id,
                sessionId: sessionId,
                recordingId: recordingId,
              );
            },
          ),
          GoRoute(
            path: '/ai-config',
            pageBuilder: (context, state) => const NoTransitionPage(child: AiConfigPage()),
          ),
          GoRoute(
            path: '/ai-config/stt',
            builder: (context, state) => const SttConfigsPage(),
          ),
          GoRoute(
            path: '/ai-config/llm',
            builder: (context, state) => const LlmConfigsPage(),
          ),
          GoRoute(
            path: '/ai-config/templates',
            builder: (context, state) => const PromptTemplatesPage(),
          ),
          GoRoute(
            path: '/ai-config/templates/new',
            builder: (context, state) => const PromptTemplateCreatePage(),
          ),
          GoRoute(
            path: '/ai-config/templates/:id',
            builder: (context, state) {
              final id = state.pathParameters['id'] ?? '';
              return PromptTemplateDetailPage(templateId: id);
            },
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => const NoTransitionPage(child: SettingsPage()),
          ),
          GoRoute(
            path: '/settings/personal',
            builder: (context, state) => const PersonalInformationPage(),
          ),
          GoRoute(
            path: '/settings/change-email',
            builder: (context, state) => const ChangeEmailPage(),
          ),
          GoRoute(
            path: '/settings/permissions',
            builder: (context, state) => const PermissionsPage(),
          ),
          GoRoute(
            path: '/settings/language',
            builder: (context, state) => const LanguagePage(),
          ),
          GoRoute(
            path: '/settings/help-feedback',
            builder: (context, state) => const HelpFeedbackPage(),
          ),
          GoRoute(
            path: '/settings/follow-us',
            builder: (context, state) => const FollowUsPage(),
          ),
          GoRoute(
            path: '/settings/delete-account',
            builder: (context, state) => const DeleteAccountPage(),
          ),
          GoRoute(
            path: '/settings/change-password',
            builder: (context, state) => const ChangePasswordPage(),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) {
      final l10n = AppLocalizations.of(context)!;
      return Scaffold(
        appBar: AppBar(title: Text(l10n.pageNotFound)),
        body: Center(child: Text(state.error.toString())),
      );
    },
  );
});

