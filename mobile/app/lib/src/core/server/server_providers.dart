import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/auth_api.dart';
import 'api/asr_api.dart';
import 'api/email_auth_api.dart';
import 'api/llm_api.dart';
import 'api/stt_api.dart';
import 'api/user_api.dart';
import 'auth/auth_token_store.dart';
import 'auth/server_auth_provider.dart';
import 'http/api_client.dart';
import 'server_config.dart';

/// Unified server-layer providers (baseUrl/token can later be wired to Settings/login state)

/// LAN API base when login/env is **dev** (Go backend `listen: 8099` on this Mac).
/// Override with `--dart-define=API_BASE_URL=http://...` when your Wi‑Fi IP changes.
const String kDevLanApiBaseUrl = 'http://127.0.0.1:8099/';

/// Default env at compile time (--dart-define=APP_ENV=xxx when building)
const String kDefaultAppEnv =
    String.fromEnvironment('APP_ENV', defaultValue: 'release');

/// API Host configuration:
///
/// - Compile time: `--dart-define=APP_ENV=dev|test|release` (default: release)
/// - Manual override (highest priority): `--dart-define=API_BASE_URL=http://...`
const String _kApiBaseUrlOverride = String.fromEnvironment('API_BASE_URL', defaultValue: '');
const String _kRefreshTokenPath = String.fromEnvironment('REFRESH_TOKEN_PATH', defaultValue: '/api/v1/user/refresh');

/// Business REST API host (recordings, STT, LLM, …). This stays on the Voice
/// service until the backend moves. Authentication URLs are **not** tied to this
/// table when the SenseCraft auth backend is selected (see auth feature
/// `authRepositoryProvider`).
String _baseUrlForEnv(String env) {
  final e = env.trim().toLowerCase();
  switch (e) {
    case 'prod':
    case 'production':
    case 'release':
      return 'https://sensecraft-voice.seeed.cc/';
    case 'test':
    case 'testing':
    case 'qa':
    case 'uat':
      return 'https://test.example.com/';
    case 'dev':
    case 'debug':
    case 'local':
    default:
      return kDevLanApiBaseUrl;
  }
}

/// Server environment; defaults to [kDefaultAppEnv] (`release` unless overridden at compile time).
final appEnvProvider = AsyncNotifierProvider<AppEnvNotifier, String?>(AppEnvNotifier.new);

class AppEnvNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async => kDefaultAppEnv;
}

/// SenseCraft portal + auth ([SenseCraftPaasEnv] / [SenseCraftAuthEnv]) must use
/// the same logical env as login. While [appEnvProvider] is loading, use
/// [kDefaultAppEnv] so we match [serverConfigProvider].
String senseCraftEnvFromAppEnv(AsyncValue<String?> appEnvAsync) {
  return appEnvAsync.when(
    data: (v) {
      final s = v?.trim() ?? '';
      if (s.isEmpty) return kDefaultAppEnv;
      return s;
    },
    loading: () => kDefaultAppEnv,
    error: (_, __) => kDefaultAppEnv,
  );
}

final serverConfigProvider = Provider<ServerConfig>((ref) {
  final override = _kApiBaseUrlOverride.trim();
  if (override.isNotEmpty) {
    var base = override;
    if (!base.startsWith('http://') && !base.startsWith('https://')) base = 'http://$base';
    return ServerConfig(
      baseUri: Uri.parse(base.endsWith('/') ? base : '$base/'),
      refreshTokenPath: _kRefreshTokenPath,
    );
  }
  final envOverride = ref.watch(appEnvProvider).valueOrNull;
  final effectiveEnv = envOverride ?? kDefaultAppEnv;
  var base = _baseUrlForEnv(effectiveEnv).trim();
  if (base.isEmpty) base = kDevLanApiBaseUrl;
  if (!base.startsWith('http://') && !base.startsWith('https://')) {
    base = 'http://$base';
  }
  return ServerConfig(
    baseUri: Uri.parse(base.endsWith('/') ? base : '$base/'),
    refreshTokenPath: _kRefreshTokenPath,
  );
});

final serverAuthProvider = Provider<ServerAuthProvider>((ref) {
  // Attach Bearer token if exists.
  return _CachedBearerAuthProvider();
});

class _CachedBearerAuthProvider implements ServerAuthProvider {
  @override
  Future<Map<String, String>> headers() async {
    final t = AuthTokenStore.cached;
    if (t == null || t.trim().isEmpty) return const {};
    return {'Authorization': 'Bearer $t'};
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final cfg = ref.watch(serverConfigProvider);
  final auth = ref.watch(serverAuthProvider);
  return ApiClient(config: cfg, auth: auth);
});

final authApiProvider = Provider<AuthApi>((ref) => AuthApi(ref.watch(apiClientProvider)));
final emailAuthApiProvider = Provider<EmailAuthApi>((ref) => EmailAuthApi(ref.watch(apiClientProvider)));
final userApiProvider = Provider<UserApi>((ref) => UserApi(ref.watch(apiClientProvider)));
final sttApiProvider = Provider<SttApi>((ref) => SttApi(ref.watch(apiClientProvider)));
final llmApiProvider = Provider<LlmApi>((ref) => LlmApi(ref.watch(apiClientProvider)));
final asrApiProvider = Provider<AsrApi>((ref) => AsrApi(ref.watch(apiClientProvider)));

