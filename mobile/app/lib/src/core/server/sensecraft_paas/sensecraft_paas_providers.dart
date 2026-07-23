import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sensecraft_auth/sensecraft_auth_env.dart';
import '../server_providers.dart';
import 'firmware_api.dart';
import 'sensecraft_paas_client.dart';
import 'sensecraft_paas_env.dart';

/// SenseCAP PaaS HTTP client (portalapi).
///
/// Distinct from `senseCraftApiClientProvider` (authapi); both reuse the same
/// [SenseCraftAuthTokenStore] so user-center login flows are reflected here
/// without a separate sign-in.
final senseCraftPaasClientProvider = Provider<SenseCraftPaasClient>((ref) {
  final env = senseCraftEnvFromAppEnv(ref.watch(appEnvProvider));
  return SenseCraftPaasClient(
    baseUri: SenseCraftPaasEnv.baseUriFor(env),
    authBaseUri: SenseCraftAuthEnv.baseUriFor(env),
  );
});

/// Cloud firmware-update query + binary download.
final firmwareApiProvider = Provider<FirmwareApi>((ref) {
  return FirmwareApi(ref.watch(senseCraftPaasClientProvider));
});
