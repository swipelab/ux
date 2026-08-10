import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  test('published constant predicates return their named values', () {
    expect(True(), isTrue);
    expect(False(), isFalse);
  });
}
