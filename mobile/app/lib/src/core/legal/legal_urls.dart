import 'package:flutter/widgets.dart';

/// SenseCraft unified legal URLs — opened via [openLegalUrl].
///
/// Routing (product spec):
/// - Base: `https://sensecraft.seeed.cc/legal/`
/// - App UI **Chinese** (`languageCode == zh`): `.../zh/...`
/// - **All other** locales (en / ja / de / system fallback, etc.): `.../en/...`
abstract final class LegalUrls {
  static const String _base = 'https://sensecraft.seeed.cc/legal';

  /// `zh` for Chinese interface; `en` for everything else.
  static String _langSegment(Locale locale) =>
      locale.languageCode == 'zh' ? 'zh' : 'en';

  static String _segmentFor(BuildContext context) =>
      _langSegment(Localizations.localeOf(context));

  /// Privacy policy — `/privacy`
  static String privacyPolicy(BuildContext context) =>
      '$_base/${_segmentFor(context)}/privacy';

  /// Terms of service — `/terms`
  static String userAgreement(BuildContext context) =>
      '$_base/${_segmentFor(context)}/terms';

  /// Open-source licenses — not in the zh/en routing table yet; keep historical URL.
  static const String openSourceLicenses =
      'https://sensecraftai.seeed.cc/open-source-licenses';
}
