import 'package:flutter/material.dart';
import 'package:ux/ux.dart';

/// Demonstrates the two OS-session controls a call screen reaches for:
/// XWindow.keepAwake, which holds the screen on while the call runs, and
/// XUrl.openAppSettings, the recovery link offered after the user denies a
/// permission.
class KeepAwakePage extends StatefulWidget {
  /// Creates the page.
  const KeepAwakePage({super.key});

  @override
  State<KeepAwakePage> createState() => _KeepAwakePageState();
}

class _KeepAwakePageState extends State<KeepAwakePage> {
  final _window = XWindow.instance;

  bool _awake = false;
  String _settings = '';

  @override
  void dispose() {
    if (_awake) _window.keepAwake(false);
    super.dispose();
  }

  Future<void> _setAwake(bool value) async {
    setState(() => _awake = value);
    await _window.keepAwake(value);
  }

  Future<void> _openSettings() async {
    final ok = await XUrl.openAppSettings();
    if (!mounted) return;
    setState(() => _settings = ok ? 'settings opened' : 'settings unreachable');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Keep awake')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SwitchListTile(
              value: _awake,
              onChanged: _setAwake,
              title: const Text('Hold the screen awake'),
              subtitle: const Text('XWindow.keepAwake'),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open app settings'),
            ),
            const SizedBox(height: 12),
            Text(_settings, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
