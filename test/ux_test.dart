import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  test('UxKeyboard.instance is a singleton', () {
    expect(UxKeyboard.instance, same(UxKeyboard.instance));
  });

  test('UxKeyboard.height starts at 0', () {
    expect(UxKeyboard.instance.height, 0);
  });

  test('UxKeyboard.isOpen is false when height is 0', () {
    expect(UxKeyboard.instance.isOpen, false);
  });
}
