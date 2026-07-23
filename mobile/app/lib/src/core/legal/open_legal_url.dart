import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../widgets/app_toasts.dart';

/// Opens [url] in an in-app browser on mobile; falls back to the default handler on desktop/web.
Future<void> openLegalUrl(BuildContext context, String url) async {
  final l10n = AppLocalizations.of(context);
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    if (context.mounted) {
      AppToasts.showError(context,
          message: l10n?.linkOpenFailed ?? 'Could not open the link.');
    }
    return;
  }

  final mode = switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => LaunchMode.inAppBrowserView,
    _ => LaunchMode.externalApplication,
  };

  final iosInAppBrowser = defaultTargetPlatform == TargetPlatform.iOS &&
      mode == LaunchMode.inAppBrowserView;

  try {
    final ok = await launchUrl(uri, mode: mode);
    // On iOS, dismissing SFSafariViewController before its initial load
    // completes is reported by url_launcher as false. That is a user
    // cancellation, not a failure to open the link.
    final dismissedBeforeLoad = !ok && iosInAppBrowser;
    if (!ok && !dismissedBeforeLoad && context.mounted) {
      AppToasts.showError(context,
          message: l10n?.linkOpenFailed ?? 'Could not open the link.');
    }
  } on PlatformException catch (_) {
    // On iOS, when SFSafariViewController is dismissed while (or before) its
    // initial load finishes, url_launcher throws a PlatformException with a
    // "failedToLoad" result even though the browser was actually presented.
    // Since this callback only fires after presentation, and Safari shows its
    // own in-page error UI, treat it as a user cancellation rather than a
    // failure to open the link.
    if (!iosInAppBrowser && context.mounted) {
      AppToasts.showError(context,
          message: l10n?.linkOpenFailed ?? 'Could not open the link.');
    }
  } catch (_) {
    if (context.mounted) {
      AppToasts.showError(context,
          message: l10n?.linkOpenFailed ?? 'Could not open the link.');
    }
  }
}
