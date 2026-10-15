import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ux/audio.dart';

/// Demonstrates XAudioCapture: start/stop the microphone tap, meter the
/// level of each 20 ms frame, and show the state the native side reports
/// when the OS takes the input away.
class AudioCapturePage extends StatefulWidget {
  /// Creates the page.
  const AudioCapturePage({super.key});

  @override
  State<AudioCapturePage> createState() => _AudioCapturePageState();
}

class _AudioCapturePageState extends State<AudioCapturePage> {
  final _capture = XAudioCapture.instance;
  StreamSubscription<XAudioFrame>? _frames;

  double _level = 0;
  int _frameCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _frames = _capture.frames.listen((frame) {
      setState(() {
        _level = frame.level;
        _frameCount++;
      });
    });
  }

  @override
  void dispose() {
    _frames?.cancel();
    unawaited(
      _capture.stop().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    super.dispose();
  }

  Future<void> _toggle() async {
    setState(() => _error = null);
    try {
      if (_capture.state.value == XAudioCaptureState.running) {
        await _capture.stop();
        if (!mounted) return;
        setState(() => _level = 0);
      } else {
        await _capture.start();
      }
    } on XAudioCaptureException catch (e) {
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message ?? ''}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('XAudioCapture')),
      body: ListenableBuilder(
        listenable: _capture.state,
        builder: (context, _) {
          final running = _capture.state.value == XAudioCaptureState.running;
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'state: ${_capture.state.value.name}',
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${XAudioCapture.sampleRate} Hz mono · '
                  '${XAudioCapture.frameSamples} samples/frame · '
                  '$_frameCount frames',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                _LevelBar(level: _level),
                const SizedBox(height: 8),
                Text(
                  'level ${_level.toStringAsFixed(3)}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _capture.supported ? _toggle : null,
                  icon: Icon(running ? Icons.stop : Icons.mic),
                  label: Text(running ? 'Stop' : 'Start'),
                ),
                if (!_capture.supported)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'No native tap on this platform.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _LevelBar extends StatelessWidget {
  const _LevelBar({required this.level});

  final double level;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 28,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        // Speaking voice sits around an RMS of 0.05–0.25, so the meter
        // shows 4× the level to use the whole bar.
        widthFactor: (level * 4).clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}
