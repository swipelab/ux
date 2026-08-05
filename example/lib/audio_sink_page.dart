import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:ux/ux.dart';

/// One 20 ms chunk of a 440 Hz sine at [XAudioSink.sampleRate], starting at
/// sample [offset] so consecutive chunks carry a continuous phase — a seam
/// between them is audible as a click.
Int16List toneChunk(int offset, int samples) {
  const frequency = 440.0;
  final chunk = Int16List(samples);
  for (var i = 0; i < samples; i++) {
    final t = (offset + i) / XAudioSink.sampleRate;
    chunk[i] = (math.sin(2 * math.pi * frequency * t) * 12000).round();
  }
  return chunk;
}

/// Demonstrates XAudioSink: stream a generated tone through the output one
/// chunk at a time — playback starts on the first chunk, long before the last
/// is generated — and cancel what is queued with flush.
class AudioSinkPage extends StatefulWidget {
  /// Creates the page.
  const AudioSinkPage({super.key});

  @override
  State<AudioSinkPage> createState() => _AudioSinkPageState();
}

class _AudioSinkPageState extends State<AudioSinkPage> {
  /// 20 ms at [XAudioSink.sampleRate].
  static const _chunkSamples = 320;

  /// Chunks per press — three seconds of tone.
  static const _chunkCount = 150;

  static const _chunkDuration = Duration(milliseconds: 20);

  final _sink = XAudioSink.instance;
  StreamSubscription<void>? _drains;
  Timer? _timer;

  int _sent = 0;
  int _drainCount = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _drains = _sink.drained.listen((_) {
      setState(() => _drainCount++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_drains?.cancel());
    unawaited(_sink.flush().then<void>(
          (_) {},
          onError: (Object _, StackTrace __) {},
        ));
    super.dispose();
  }

  /// Feeds chunks at the rate they play, so the sink is always being written
  /// to while it plays.
  void _stream() {
    _timer?.cancel();
    _sent = 0;
    _error = null;
    _sendNext();
    _timer = Timer.periodic(_chunkDuration, (timer) {
      if (_sent >= _chunkCount) {
        timer.cancel();
        return;
      }
      _sendNext();
    });
  }

  void _sendNext() {
    final chunk = toneChunk(_sent * _chunkSamples, _chunkSamples);
    setState(() => _sent++);
    unawaited(_send(chunk));
  }

  Future<void> _send(Int16List chunk) async {
    try {
      await _sink.enqueue(chunk);
    } on XAudioSinkException catch (e) {
      _timer?.cancel();
      if (!mounted) return;
      setState(() => _error = '${e.code}: ${e.message ?? ''}');
    }
  }

  Future<void> _flush() async {
    _timer?.cancel();
    await _sink.flush();
    if (!mounted) return;
    setState(() => _sent = 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('XAudioSink')),
      body: ListenableBuilder(
        listenable: _sink.state,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'state: ${_sink.state.value.name}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '${XAudioSink.sampleRate} Hz mono · '
                '$_chunkSamples samples/chunk · '
                '$_sent/$_chunkCount sent · '
                '$_drainCount drained',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _sink.supported ? _stream : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Stream tone'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _sink.supported ? _flush : null,
                icon: const Icon(Icons.stop),
                label: const Text('Flush'),
              ),
              if (!_sink.supported)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'No native sink on this platform.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
