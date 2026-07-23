/// Supplies auth headers for API calls (pluggable: Bearer / API key / none).
abstract class ServerAuthProvider {
  Future<Map<String, String>> headers();
}

class NoAuthProvider implements ServerAuthProvider {
  const NoAuthProvider();

  @override
  Future<Map<String, String>> headers() async => const {};
}

class StaticBearerAuthProvider implements ServerAuthProvider {
  final String token;
  const StaticBearerAuthProvider(this.token);

  @override
  Future<Map<String, String>> headers() async => {'Authorization': 'Bearer $token'};
}

