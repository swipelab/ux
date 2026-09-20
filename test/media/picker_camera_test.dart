import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/gallery.dart';
import 'package:ux/media.dart';

XAsset _asset(String id) => XAsset(
  id: id,
  kind: XAssetKind.image,
  width: 4,
  height: 4,
  createdAt: DateTime(2026),
);

void main() {
  test('a full selection refuses another asset and numbers picks from 1', () {
    final selection = SelectionContext(limit: 2);
    expect(selection.toggle(_asset('a')), isTrue);
    expect(selection.toggle(_asset('b')), isTrue);
    expect(selection.toggle(_asset('c')), isFalse);
    expect(selection.indexOf(_asset('b')), 2);

    selection.toggle(_asset('a'));
    expect(selection.indexOf(_asset('b')), 1);
    selection.dispose();
  });

  test(
    'a front camera adds the device rotation and a back camera subtracts it',
    () {
      expect(
        computeCaptureTransform(
          physical: DeviceOrientation.landscapeLeft,
          sensorOrientation: 270,
          isFrontCamera: true,
        ).rotationDegrees,
        0,
      );
      expect(
        computeCaptureTransform(
          physical: DeviceOrientation.landscapeLeft,
          sensorOrientation: 90,
          isFrontCamera: false,
        ).rotationDegrees,
        0,
      );
    },
  );

  test(
    'a picker cell source is forgotten only by the one that recorded it',
    () {
      final registry = PickerSourceRegistry();
      final first = RepaintBoundaryGallerySource(GlobalKey());
      final second = RepaintBoundaryGallerySource(GlobalKey());
      registry.register('a', PickerViewKind.grid, first);
      registry.register('a', PickerViewKind.grid, second);

      registry.unregister('a', PickerViewKind.grid, first);
      expect(registry.sourceFor('a', PickerViewKind.grid), same(second));
      expect(registry.sourceFor('a', PickerViewKind.strip), isNull);
    },
  );
}
