import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('detectLinks reads no phone', () {
    expectLinks(
      'call +40 712 345 678 now',
      const [],
      apple: [phone(5, 20, 'tel:+40712345678')],
    );
  });
}
