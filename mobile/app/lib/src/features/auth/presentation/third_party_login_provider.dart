import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/third_party_login_store.dart';

/// Whether the login landing page shows the third-party login block.
/// Value is fixed at build time (see [ThirdPartyLoginStore]).
final showThirdPartyLoginProvider = Provider<bool>((ref) {
  return ThirdPartyLoginStore.showThirdPartyLogin;
});
