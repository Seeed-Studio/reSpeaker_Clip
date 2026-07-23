import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which authentication backend the app talks to.
///
/// - [selfHosted]: legacy path. Login/register/OAuth all go to the project's
///   own Go backend at the same `baseUri`
///   used by business APIs. Tokens are HS256 JWT signed by that backend.
/// - [senseCraft]: SenseCraft unified auth (`authDomain()`). Login happens
///   against `https://sensecraft-auth.seeed.cc/authapi` (etc.), then the
///   app exchanges the SenseCraft token for a business token at
///   `POST {bizDomain}/api/v1/user/external/sensecraft/login` so existing
///   business endpoints (recordings / llm / asr / oss) remain unchanged.
///
/// See SenseCraft authapi for the auth contract.
enum AuthBackend {
  selfHosted('self_hosted'),
  senseCraft('sensecraft');

  final String storageValue;
  const AuthBackend(this.storageValue);

  static AuthBackend? tryParse(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v.isEmpty) return null;
    for (final b in AuthBackend.values) {
      if (b.storageValue == v) return b;
    }
    return null;
  }
}

/// Compile-time default, e.g. `--dart-define=AUTH_BACKEND=self_hosted`.
///
/// When unset, defaults to [AuthBackend.senseCraft] (SenseCraft unified auth).
const String _kCompileDefaultRaw =
    String.fromEnvironment('AUTH_BACKEND', defaultValue: '');

AuthBackend get compileTimeAuthBackendDefault =>
    AuthBackend.tryParse(_kCompileDefaultRaw) ?? AuthBackend.senseCraft;

/// Persists the user / dev selection of [AuthBackend].
///
/// Persists optional runtime override (e.g. for tests). The login UI no longer
/// exposes a switch; use `AUTH_BACKEND` or call [AuthBackendNotifier.setBackend].
class AuthBackendStore {
  static const _kKey = 'auth_backend';

  static AuthBackend? _cached;

  /// Preload during bootstrap to avoid an async hop on first widget build.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = AuthBackend.tryParse(prefs.getString(_kKey));
    final compileParsed = AuthBackend.tryParse(_kCompileDefaultRaw);

    // Login no longer exposes a backend switch. Drop a stale "Voice API"
    // (self_hosted) preference unless the build opts in via `AUTH_BACKEND`.
    if (compileParsed == null && stored == AuthBackend.selfHosted) {
      await prefs.remove(_kKey);
      _cached = null;
      return;
    }

    _cached = stored;
  }

  static AuthBackend? get cached => _cached;

  static Future<AuthBackend?> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AuthBackend.tryParse(prefs.getString(_kKey));
  }

  static Future<void> set(AuthBackend backend) async {
    _cached = backend;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, backend.storageValue);
  }

  static Future<void> clear() async {
    _cached = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kKey);
  }
}

/// The active [AuthBackend], reactive across the app.
///
/// Resolution order:
///   1. [AuthBackendStore.cached], else [AuthBackendStore.load] (SharedPreferences).
///   2. [compileTimeAuthBackendDefault] (`--dart-define=AUTH_BACKEND=...` when set,
///      otherwise [AuthBackend.senseCraft]).
final authBackendProvider =
    AsyncNotifierProvider<AuthBackendNotifier, AuthBackend>(AuthBackendNotifier.new);

class AuthBackendNotifier extends AsyncNotifier<AuthBackend> {
  @override
  Future<AuthBackend> build() async {
    return AuthBackendStore.cached ??
        await AuthBackendStore.load() ??
        compileTimeAuthBackendDefault;
  }

  Future<void> setBackend(AuthBackend backend) async {
    await AuthBackendStore.set(backend);
    state = AsyncData(backend);
  }
}
