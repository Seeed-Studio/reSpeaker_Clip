import 'package:flutter/foundation.dart';

@immutable
class ServerException implements Exception {
  final String message;
  /// Optional key for [AppLocalizations] (e.g. llmErrorResponseFormat).
  /// When set, UI should display the localized string for this key instead of [message].
  final String? messageKey;
  final int? bizCode;
  final String? errorKey;
  final String? details;
  final int? statusCode;
  final Object? data;

  const ServerException(
    this.message, {
    this.messageKey,
    this.bizCode,
    this.errorKey,
    this.details,
    this.statusCode,
    this.data,
  });

  @override
  String toString() =>
      'ServerException(bizCode: $bizCode, errorKey: $errorKey, statusCode: $statusCode, message: $message, details: $details, data: $data)';
}

