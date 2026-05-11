@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

/// End-to-end smoke against a running `tools/log_server` at $E2E_LOG_ENDPOINT.
/// Skipped unless both `E2E_LOG_ENDPOINT` and `E2E_LOG_TOKEN` are provided.
void main() {
  const endpoint = String.fromEnvironment('E2E_LOG_ENDPOINT');
  const token = String.fromEnvironment('E2E_LOG_TOKEN');
  final skip = endpoint.isEmpty || token.isEmpty
      ? 'Set --dart-define=E2E_LOG_ENDPOINT and E2E_LOG_TOKEN to run'
      : false;

  test('round-trip through HttpSink → log_server', () async {
    final sink = HttpSink(
      endpoint: Uri.parse('$endpoint/log'),
      token: token,
      device: {'platform': 'test'},
      app: {'version': 'e2e'},
      flushInterval: const Duration(milliseconds: 1),
    );

    sink.emit(LogRecord(
      time: DateTime.utc(2026, 5, 10, 12, 0, 0),
      level: LogLevel.error,
      message: 'e2e-roundtrip',
      tag: 'smoke',
    ));
    await sink.flush();
  }, skip: skip);
}
