import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Barcode formats the platform decoder will look for. Today only QR is
/// supported; the enum exists for forward-compatibility with the native
/// channel arguments.
enum BarcodeFormat {
  /// QR code.
  qr,
}

/// Static helpers exposed by the platform-side scanner plugin.
class XScannerPermission {
  XScannerPermission._();

  static const _channel = MethodChannel('ux/scanner');

  /// Requests camera permission. Returns `true` once the OS has reported
  /// authorized; `false` if the user denied or the platform is
  /// unsupported. Safe to call multiple times — already-granted returns
  /// `true` immediately.
  static Future<bool> requestCamera() async {
    if (defaultTargetPlatform != TargetPlatform.iOS &&
        defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    final granted = await _channel.invokeMethod<bool>('requestPermission');
    return granted ?? false;
  }
}

/// Camera-preview widget that emits decoded barcode payloads.
///
/// Backed by AVFoundation on iOS (built-in QR support, no extra dep) and
/// CameraX + ZXing on Android. The widget mounts a platform-view —
/// `UiKitView` on iOS, `AndroidView` on Android — and listens to a
/// per-process event channel for decoded strings.
///
/// Camera permission must be granted by the host app before mounting.
/// On platforms other than iOS / Android the widget renders an empty
/// box.
class XScanner extends StatefulWidget {
  /// Binds the callback decoded payloads are delivered to.
  const XScanner({
    super.key,
    required this.onCode,
    this.formats = const [BarcodeFormat.qr],
  });

  /// Called with each decoded payload, once per decode.
  final ValueChanged<String> onCode;

  /// Formats the platform decoder looks for.
  final List<BarcodeFormat> formats;

  @override
  State<XScanner> createState() => _XScannerState();
}

class _XScannerState extends State<XScanner> {
  static const _events = EventChannel('ux/scanner/events');
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _events.receiveBroadcastStream().listen((event) {
      final code = event as String?;
      if (code == null || !mounted) return;
      widget.onCode(code);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final creationParams = <String, Object?>{
      'formats': widget.formats.map((e) => e.name).toList(),
    };
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: 'ux/scanner',
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: 'ux/scanner',
        surfaceFactory: (context, controller) {
          return AndroidViewSurface(
            controller: controller as AndroidViewController,
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          );
        },
        onCreatePlatformView: (params) {
          return PlatformViewsService.initSurfaceAndroidView(
              id: params.id,
              viewType: 'ux/scanner',
              layoutDirection: TextDirection.ltr,
              creationParams: creationParams,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => params.onFocusChanged(true),
            )
            ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
            ..create();
        },
      );
    }
    return const SizedBox.shrink();
  }
}
