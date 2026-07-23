import 'package:logger/logger.dart';

class AppLog {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: false,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
  );

  static void d(String message) => _logger.d(message);
  static void i(String message) => _logger.i(message);
  static void w(String message, [Object? error, StackTrace? stackTrace]) => _logger.w(message, error: error, stackTrace: stackTrace);
  static void e(String message, [Object? error, StackTrace? stackTrace]) => _logger.e(message, error: error, stackTrace: stackTrace);
}

