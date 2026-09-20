import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/media/picker/picker_grid_layout.dart';

SliverGridLayout _layout({int columns = 3, bool camera = true}) =>
    PickerGridDelegate(columns: columns, hasCamera: camera).getLayout(
      SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: 0,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: 600,
        crossAxisExtent: columns * 100 + (columns - 1) * 2,
        crossAxisDirection: AxisDirection.right,
        viewportMainAxisExtent: 600,
        remainingCacheExtent: 600,
        cacheOrigin: 0,
      ),
    );

void main() {
  test('the camera spans two rows and assets skip its lower slot', () {
    final layout = _layout();
    final camera = layout.getGeometryForChildIndex(0);
    expect(camera.crossAxisExtent, 100);
    expect(camera.mainAxisExtent, 202);
    expect(layout.getGeometryForChildIndex(1).crossAxisOffset, 102);
    final secondRow = layout.getGeometryForChildIndex(3);
    expect(secondRow.scrollOffset, 102);
    expect(secondRow.crossAxisOffset, 102);
    final thirdRow = layout.getGeometryForChildIndex(5);
    expect(thirdRow.scrollOffset, 204);
    expect(thirdRow.crossAxisOffset, 0);
    expect(layout.computeMaxScrollOffset(0), 0);
    expect(layout.computeMaxScrollOffset(1), 202);
    expect(layout.computeMaxScrollOffset(3), 202);
    expect(layout.computeMaxScrollOffset(5), 202);
    expect(layout.computeMaxScrollOffset(6), 304);
  });

  test('lazy recycling retains the camera through the second row', () {
    final layout = _layout();
    expect(layout.getMinChildIndexForScrollOffset(150), 0);
    expect(layout.getMinChildIndexForScrollOffset(204), 5);
    expect(layout.getMaxChildIndexForScrollOffset(102), 2);
    expect(layout.getMaxChildIndexForScrollOffset(103), 4);
    expect(layout.getMaxChildIndexForScrollOffset(205), 7);
  });

  test('landscape reserves only the first column of its five columns', () {
    final layout = _layout(columns: 5);
    expect(layout.getGeometryForChildIndex(5).crossAxisOffset, 102);
    expect(layout.getGeometryForChildIndex(9).crossAxisOffset, 0);
    expect(layout.getGeometryForChildIndex(9).scrollOffset, 204);
  });

  test('ordinary assets fill column zero without a camera reservation', () {
    final layout = _layout(camera: false);
    expect(layout.getGeometryForChildIndex(0).mainAxisExtent, 100);
    expect(layout.getGeometryForChildIndex(3).crossAxisOffset, 0);
    expect(layout.computeMaxScrollOffset(3), 100);
    expect(layout.getMinChildIndexForScrollOffset(102), 3);
  });
}
