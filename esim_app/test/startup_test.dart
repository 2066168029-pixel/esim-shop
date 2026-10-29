import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:esim_app/store.dart';
import 'package:esim_app/api.dart';
import 'package:esim_app/esim_installer.dart';

/// Guards the splash-screen hang regression.
///
/// A stale token plus an unreachable backend used to leave `ready == false`
/// forever, so the app sat on the splash screen. These tests pin the contract:
/// startup must complete quickly and must not depend on network success.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('AppState becomes ready with no stored token', () async {
    final app = AppState();
    // _load() is async; give it a moment but fail fast if it never finishes.
    await _until(() => app.ready, timeout: const Duration(seconds: 3));
    expect(app.ready, isTrue);
    expect(app.isLoggedIn, isFalse);
  });

  test('AppState becomes ready even with a stale token and dead backend',
      () async {
    SharedPreferences.setMockInitialValues({
      'token': 'definitely-not-a-valid-token',
      'user': '{"id":1,"email":"stale@example.com","full_name":"Stale","is_admin":false}',
    });

    final app = AppState();
    final sw = Stopwatch()..start();
    await _until(() => app.ready, timeout: const Duration(seconds: 3));
    sw.stop();

    expect(app.ready, isTrue, reason: 'startup must not block on the network');
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    // A network failure says nothing about the token, so the cached session
    // must survive; only a 401/403 response may log the customer out.
    expect(app.user, isNotNull, reason: 'network error must not clear session');
    expect(app.isLoggedIn, isTrue);
  });

  test('API base URL never defaults to the emulator loopback', () {
    // A release build must point at a real host. 10.0.2.2 is emulator-only and
    // is the exact default that shipped a hanging build.
    expect(ApiConfig.baseUrl.contains('10.0.2.2'), isFalse);
    expect(ApiConfig.baseUrl, contains(':8100'));
  });

  test('activation code parser accepts GSMA codes and rejects junk', () {
    expect(ActivationCode.parse('LPA:1\$rsp.truphone.com\$ABC123XYZ'), isNotNull);
    expect(ActivationCode.parse('4028812345678'), isNull); // barcode digits
    expect(ActivationCode.parse('https://example.com'), isNull);
    expect(ActivationCode.parse(''), isNull);
  });
}

/// Polls [predicate] until true or [timeout] elapses.
Future<void> _until(
  bool Function() predicate, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
