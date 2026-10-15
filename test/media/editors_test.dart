import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/media.dart';

import 'fake_host.dart';

void main() {
  setUp(() => MediaHost.current = FakeMediaHost());

  test('CameraFit interpolates translation and scale together', () {
    const from = CameraFit(tx: 0, ty: 0, scale: 1);
    const to = CameraFit(tx: 100, ty: 40, scale: 3);
    expect(from + (to - from) * 0.5, const CameraFit(tx: 50, ty: 20, scale: 2));
    expect(CameraFit.fromMatrix(to.toMatrix()), to);
  });

  test('a text style spends the colour on glyphs, frame or outline', () {
    const red = Color(0xFFFF0000);
    expect(TextEntityStyle.regular.resolve(red).textColor, red);
    expect(TextEntityStyle.filled.resolve(red).frameColor, red);
    expect(TextEntityStyle.stroke.resolve(red).strokeColor, red);
    expect(TextEntityStyle.stroke.next, TextEntityStyle.regular);
  });

  test(
    'the editor keyboard lift is the keyboard inset net of the safe area',
    () {
      final insets = MediaHost.current.insets as FakeMediaInsets
        ..viewPadding = const EdgeInsets.only(top: 47, bottom: 34)
        ..keyboardInset = 336;
      expect(editorSafeAreaTop, 47);
      expect(editorKeyboardLift, 302);

      insets.keyboardInset = 0;
      expect(editorKeyboardLift, 0);
    },
  );

  test(
    'an entity layer writes the selected entity, else the pending style',
    () {
      final layer = EntityLayer(imageSize: const Size(1000, 800));
      layer.cycleStyle();
      expect(layer.pendingStyle, TextEntityStyle.semi);

      final entity = TextEntity(
        text: 'hello',
        style: TextEntityStyle.regular,
        align: TextAlign.center,
        colour: const Color(0xFFFFFFFF),
        fontSize: .08,
        position: const Offset(500, 400),
        width: 400,
      );
      layer
        ..add(entity)
        ..select(entity.id)
        ..cycleStyle();
      expect(entity.style, TextEntityStyle.filled);
      expect(layer.pendingStyle, TextEntityStyle.semi);

      layer.remove(entity.id);
      expect(layer.selected, isNull);
      expect(layer.hasAppliedEdits, isFalse);
    },
  );

  test('a draw layer keeps a colour and a thickness per brush', () async {
    final recorder = PictureRecorder();
    Canvas(recorder);
    final image = await recorder.endRecording().toImage(4, 4);
    final layer = DrawImageLayer(image: image)
      ..setCurrentColor(const Color(0xFF00FF00))
      ..normalizedThickness = 0.9
      ..setBrushType(BrushType.marker);
    expect(layer.currentColor, kBrushDefaultColors[BrushType.marker]);
    expect(layer.normalizedThickness, kBrushDefaultThickness[BrushType.marker]);

    layer.setBrushType(BrushType.pen);
    expect(layer.currentColor, const Color(0xFF00FF00));
    expect(layer.normalizedThickness, 0.9);
    image.dispose();
  });
}
