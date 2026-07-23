import 'package:flutter_test/flutter_test.dart';
import 'package:sensecraft_voice/sensecraft_voice.dart';

void main() {
  group('DownloadStartFailureKind', () {
    test('classifies common firmware errors', () {
      expect(
        DownloadStartFailureKindX.fromAtReply({
          'ok': false,
          'msg': 'Session not found',
        }),
        DownloadStartFailureKind.sessionNotFound,
      );
      expect(
        DownloadStartFailureKindX.fromAtReply({
          'ok': false,
          'error': 'Transfer already in progress',
        }),
        DownloadStartFailureKind.transferBusy,
      );
      expect(
        DownloadStartFailureKindX.fromAtReply({
          'ok': false,
          'error': 'SD card unavailable',
        }),
        DownloadStartFailureKind.other,
      );
    });
  });

  group('DownloadStartRetryPolicy', () {
    test('default is conservative', () {
      const policy = DownloadStartRetryPolicy();
      expect(policy.maxAttempts, 1);
      expect(policy.cancelBusyTransfer, isFalse);
      expect(
          policy.shouldRetry(DownloadStartFailureKind.sessionNotFound), isTrue);
      expect(
          policy.shouldRetry(DownloadStartFailureKind.transferBusy), isFalse);
    });

    test('resilient policy retries busy transfers', () {
      const policy = DownloadStartRetryPolicy.resilient();
      expect(policy.maxAttempts, 4);
      expect(policy.cancelBusyTransfer, isTrue);
      expect(policy.shouldRetry(DownloadStartFailureKind.transferBusy), isTrue);
    });
  });

  group('RecordingException', () {
    test('includes optional code in toString', () {
      const e = RecordingException('failed', code: 'transferBusy');
      expect(e.toString(), contains('transferBusy'));
      expect(e.toString(), contains('failed'));
    });
  });
}
