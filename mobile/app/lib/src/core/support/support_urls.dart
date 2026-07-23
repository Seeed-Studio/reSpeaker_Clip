import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../widgets/app_toasts.dart';

/// Product support contact endpoints.
abstract final class SupportUrls {
  static const String contactEmail = 'techsupport@seeed.io';

  /// reSpeaker Clip product documentation.
  static const String productWiki =
      'https://wiki.seeedstudio.com/respeaker_clip';
}

/// Opens the default mail client to compose a message to [SupportUrls.contactEmail].
Future<void> openSupportEmail(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final uri = Uri(
    scheme: 'mailto',
    path: SupportUrls.contactEmail,
  );

  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppToasts.showError(
        context,
        message: l10n?.linkOpenFailed ?? 'Could not open the link.',
      );
    }
  } catch (_) {
    if (context.mounted) {
      AppToasts.showError(
        context,
        message: l10n?.linkOpenFailed ?? 'Could not open the link.',
      );
    }
  }
}
