import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'src/bootstrap.dart';
import 'src/core/log/app_log.dart';
import 'src/core/observability/sentry_config.dart';
import 'src/core/observability/sentry_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final packageInfo = await PackageInfo.fromPlatform();
  final release = 'cc.seeed.voice@${packageInfo.version}+${packageInfo.buildNumber}';

  await SentryFlutter.init(
    (options) {
      SentryConfig.configure(options);
      if (SentryConfig.enabled) {
        options.release = release;
      }
    },
    appRunner: () async {
      SentryService.markReady();
      AppLog.i('main start');

      PlatformDispatcher.instance.onError = (error, stack) {
        AppLog.e('PlatformDispatcher error', error, stack);
        if (SentryService.active &&
            !SentryConfig.isExpectedWifiApReachabilityNoise(error, stack)) {
          unawaited(Sentry.captureException(error, stackTrace: stack));
        }
        return true;
      };

      await bootstrap();
    },
  );
}
