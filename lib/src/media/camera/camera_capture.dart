import 'dart:io' as io;
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:path_provider/path_provider.dart';
import 'package:swipelab_webp/swipelab_webp.dart';
import 'package:ux/src/media/exif_orientation.dart';

/// Re-encodes a captured [jpeg] as an upright WebP file in the temporary
/// directory, from the device's [physical] orientation at capture, the camera's
/// [sensorOrientation] and whether it [isFrontCamera].
Future<io.File> normalizeCameraCapture(
  io.File jpeg, {
  required DeviceOrientation physical,
  required int sensorOrientation,
  required bool isFrontCamera,
}) async {
  final original = await jpeg.readAsBytes();
  final exif = readJpegExifOrientation(original);
  final dims = readJpegRawDimensions(original);

  // Some OEMs (notably Huawei EMUI) physically pre-rotate the JPEG pixels to
  // match `targetRotation` and stamp EXIF=1; others (Pixel) leave pixels at
  // sensor orientation and stamp a non-identity EXIF tag. Detect via dim swap
  // (90/270° rotations swap dims) plus the EXIF=1 + non-zero CameraX-formula
  // case (180° rotations leave dims alone, but EXIF=1 with a non-zero
  // would-be-rotation only happens on pre-rotating OEMs — Pixel writes EXIF=3
  // there).
  final sensorIsLandscapeReadout =
      sensorOrientation == 90 || sensorOrientation == 270;
  final jpegIsLandscape = dims != null && dims.width >= dims.height;
  final dimsSwapped =
      dims != null && sensorIsLandscapeReadout != jpegIsLandscape;

  final displayRotation = _flutterToDisplayRotationDegrees(physical);
  final cameraxPreRotation = isFrontCamera
      ? (sensorOrientation + displayRotation) % 360
      : (sensorOrientation - displayRotation + 360) % 360;

  final preRotated = dimsSwapped || (exif == 1 && cameraxPreRotation != 0);

  final pixelExpected = computeCaptureTransform(
    physical: physical,
    sensorOrientation: sensorOrientation,
    isFrontCamera: isFrontCamera,
  );

  final Uint8List rgba;
  final int width;
  final int height;
  final WebPOrientation outputOrientation;

  if (preRotated) {
    // CameraX pre-rotated by `cameraxPreRotation` (standard CameraX formula
    // off `displayRotation`). Our target is `pixelExpected.rotationDegrees`
    // (off `_surfaceDegrees`). The two diverge by 180° for landscapes because
    // [_surfaceDegrees] and [_flutterToDisplayRotationDegrees] use complementary
    // conventions for landscapeLeft/Right. Apply the residual.
    final decoded = await _decodeJpegRgba(original);
    rgba = decoded.rgba;
    width = decoded.width;
    height = decoded.height;
    final residual =
        (pixelExpected.rotationDegrees - cameraxPreRotation + 360) % 360;
    outputOrientation = _webpOrientationFor((
      rotationDegrees: residual,
      mirror: pixelExpected.mirror,
    ));
  } else {
    final decoded = await _decodeJpegRgba(stripJpegApp1(original));
    rgba = decoded.rgba;
    width = decoded.width;
    height = decoded.height;
    outputOrientation = _webpOrientationFor(pixelExpected);
  }

  final webp = await compute(
    encodeWebP,
    WebPEncodeInput(
      rgba: rgba,
      width: width,
      height: height,
      orientation: outputOrientation,
    ),
  );
  if (webp == null) {
    throw StateError('WebP encode failed');
  }

  final tmp = await getTemporaryDirectory();
  final outPath =
      '${tmp.path}/capture_${clock.now().microsecondsSinceEpoch}.webp';
  final outFile = io.File(outPath);
  await outFile.writeAsBytes(webp, flush: true);
  return outFile;
}

Future<({Uint8List rgba, int width, int height})> _decodeJpegRgba(
  Uint8List bytes,
) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final w = frame.image.width;
      final h = frame.image.height;
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) {
        throw StateError('toByteData returned null');
      }
      final rgba = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      return (rgba: rgba, width: w, height: h);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

/// Mirrors the native `flutterToSurfaceRotation` in `DeviceOrientationBridge.kt`
/// (the value the native side hands to `ImageCapture.targetRotation`). Used to
/// reconstruct CameraX's pre-rotation amount on the Dart side.
int _flutterToDisplayRotationDegrees(DeviceOrientation o) => switch (o) {
  DeviceOrientation.portraitUp => 0,
  DeviceOrientation.landscapeRight => 90,
  DeviceOrientation.portraitDown => 180,
  DeviceOrientation.landscapeLeft => 270,
};

/// The rotation that turns sensor pixels upright for a capture at [physical];
/// never mirrors.
({int rotationDegrees, bool mirror}) computeCaptureTransform({
  required DeviceOrientation physical,
  required int sensorOrientation,
  required bool isFrontCamera,
}) {
  final p = _surfaceDegrees(physical);
  final rotation = isFrontCamera
      ? (sensorOrientation + p) % 360
      : (sensorOrientation - p + 360) % 360;
  return (rotationDegrees: rotation, mirror: false);
}

int _surfaceDegrees(DeviceOrientation o) => switch (o) {
  DeviceOrientation.portraitUp => 0,
  DeviceOrientation.landscapeLeft => 90,
  DeviceOrientation.portraitDown => 180,
  DeviceOrientation.landscapeRight => 270,
};

WebPOrientation _webpOrientationFor(({int rotationDegrees, bool mirror}) t) {
  return switch ((t.rotationDegrees, t.mirror)) {
    (0, false) => WebPOrientation.normal,
    (90, false) => WebPOrientation.rotate90,
    (180, false) => WebPOrientation.rotate180,
    (270, false) => WebPOrientation.rotate270,
    (0, true) => WebPOrientation.flipH,
    (90, true) => WebPOrientation.transverse,
    (180, true) => WebPOrientation.flipV,
    (270, true) => WebPOrientation.transpose,
    _ => WebPOrientation.normal,
  };
}
