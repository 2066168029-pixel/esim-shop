import 'package:flutter_test/flutter_test.dart';

/// This file used to hold the `FakeSession` shared by `apdu_test.dart` and
/// `notifications_test.dart`.
///
/// `Lpa` now takes an `EuiccSession` (APDU-level) instead of a `CardSession`
/// (Linksfield-specific), so the fake lives at the transport boundary in
/// `apdu_test.dart`, where the real card boundary is. Kept as a placeholder so
/// older branches that import it still resolve.
void main() {
  test('transport-level fakes live in apdu_test.dart now', () {
    expect(true, isTrue);
  });
}
