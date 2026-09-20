import 'package:flutter/material.dart';
import 'package:ux/camera.dart';

class CameraPermissionPage extends StatefulWidget {
  const CameraPermissionPage({super.key});

  @override
  State<CameraPermissionPage> createState() => _CameraPermissionPageState();
}

class _CameraPermissionPageState extends State<CameraPermissionPage>
    with WidgetsBindingObserver {
  bool? _granted;
  String? _error;
  bool _busy = false;
  int _query = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final query = ++_query;
    try {
      final granted = await XCameraController.cameraPermissionGranted();
      if (!mounted || query != _query) return;
      setState(() {
        _granted = granted;
        _error = null;
      });
    } catch (error) {
      if (!mounted || query != _query) return;
      setState(() => _error = error.toString());
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Camera permission')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(switch (_granted) {
            null => 'Camera access: checking',
            true => 'Camera access: granted',
            false => 'Camera access: not granted',
          }),
          const SizedBox(height: 16),
          const Text(
            'Checking access does not open a camera or request microphone access. '
            'Request access shows the camera prompt or opens Settings. '
            'Access refreshes when you return to the app.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _act(() async {
                    await XCameraController.requestCameraPermission();
                  }),
            child: const Text('Request camera access'),
          ),
          TextButton(
            onPressed: _busy ? null : _refresh,
            child: const Text('Refresh status'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _act(XCameraController.openSystemSettings),
            child: const Text('Open Settings'),
          ),
          if (_error case final error?) Text(error),
        ],
      ),
    );
  }
}
