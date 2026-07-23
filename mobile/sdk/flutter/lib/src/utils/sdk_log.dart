/// Pluggable logger for the SenseCraft Voice SDK.
///
/// The SDK never imports a concrete logging package; the host app may inject
/// any logger (e.g. `package:logger`, `print`, or a no-op) via
/// [SdkLog.bind]. By default everything is dropped silently.
library;

/// Severity levels.
enum SdkLogLevel { debug, info, warning, error }

/// Callback the SDK calls for every log event.
///
/// Implementations should be fast and exception-safe; the SDK does not catch
/// errors thrown from the callback.
typedef SdkLogHandler = void Function(
  SdkLogLevel level,
  String message,
  Object? error,
  StackTrace? stackTrace,
);

/// Lightweight static facade used by all SDK internals.
///
/// Call [SdkLog.bind] once during app start to forward SDK logs to your
/// preferred logger; otherwise logs are silently dropped.
class SdkLog {
  static SdkLogHandler _handler = _silent;

  /// Replace the active handler. Pass `null` to silence the SDK again.
  static void bind(SdkLogHandler? handler) {
    _handler = handler ?? _silent;
  }

  static void d(String message, [Object? error, StackTrace? stackTrace]) =>
      _handler(SdkLogLevel.debug, message, error, stackTrace);

  static void i(String message, [Object? error, StackTrace? stackTrace]) =>
      _handler(SdkLogLevel.info, message, error, stackTrace);

  static void w(String message, [Object? error, StackTrace? stackTrace]) =>
      _handler(SdkLogLevel.warning, message, error, stackTrace);

  static void e(String message, [Object? error, StackTrace? stackTrace]) =>
      _handler(SdkLogLevel.error, message, error, stackTrace);

  static void _silent(
    SdkLogLevel _,
    String __,
    Object? ___,
    StackTrace? ____,
  ) {}
}
