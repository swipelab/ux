import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  test('XKeyboard.instance is a singleton', () {
    expect(XKeyboard.instance, same(XKeyboard.instance));
  });

  test('XKeyboard.height starts at 0', () {
    expect(XKeyboard.instance.height, 0);
  });

  test('XKeyboard.isOpen is false when height is 0', () {
    expect(XKeyboard.instance.isOpen, false);
  });
}
