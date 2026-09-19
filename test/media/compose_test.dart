import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/media.dart';

import 'fake_host.dart';

class _CaptionHost extends FakeMediaHost {
  final made = <TextEditingController>[];

  @override
  TextEditingController captionController() {
    final controller = TextEditingController();
    made.add(controller);
    return controller;
  }
}

void main() {
  test('an entry captions through the host\'s controller', () {
    final host = _CaptionHost();
    MediaHost.current = host;
    final entry = ComposeEntry(input: ImageMedia(file: File('meal.jpg')));
    expect(entry.composerController, same(host.made.single));
    entry.dispose();
  });

  test('a result with bytes resolves to them', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final result = ComposeResult(
      source: ImageMedia(file: File('absent.jpg')),
      composedImage: null,
      imageBytes: bytes,
    );
    expect(await result.resolveImageBytes(), same(bytes));
  });

  test('releasing the top hide slot hides the one under it again', () {
    final hidden = HiddenMediaController.instance..clearForTest();
    final under = hidden.acquire('a');
    final top = hidden.acquire('b');
    expect(hidden.isHidden('b'), isTrue);

    hidden.release(top);
    expect(hidden.isHidden('a'), isTrue);

    hidden.release(under);
    expect(hidden.hidden, isNull);
  });
}
