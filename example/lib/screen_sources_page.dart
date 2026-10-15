import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:ux/screen_sources.dart';

/// Enumerates the capture stack's own sources, whose ids
/// [XScreenSourcesBackend.list] takes as its allowed sets.
typedef ScreenSourcePriming = Future<List<DesktopCapturerSource>> Function();

/// Demonstrates the screen-share picker: prime the capture stack, hand its
/// ids to XScreenSourcesBackend.list, show the snapshot, and capture the
/// source the user picks.
class ScreenSourcesPage extends StatefulWidget {
  /// Creates the page.
  const ScreenSourcesPage({super.key});

  /// The capture stack's enumeration, both source types in one call.
  static Future<List<DesktopCapturerSource>> captureStackSources() =>
      desktopCapturer.getSources(
        types: const [SourceType.Screen, SourceType.Window],
      );

  /// The enumeration a refresh primes with. Swap to script or record it.
  static ScreenSourcePriming primeSources = captureStackSources;

  /// Marks the frame that arrived for the current selection.
  static const firstFrameKey = ValueKey<String>('screen-source-first-frame');

  /// Identifies the tile of [kind] `id`, which selecting captures.
  static ValueKey<String> sourceTileKey(XScreenSourceKind kind, String id) =>
      ValueKey<String>('screen-source-${kind.name}-$id');

  @override
  State<ScreenSourcesPage> createState() => _ScreenSourcesPageState();
}

class _ScreenSourcesPageState extends State<ScreenSourcesPage> {
  final _backend = XScreenSourcesBackend.instance;

  bool _available = false;
  bool _permission = false;
  bool _refreshing = false;
  bool _firstFrame = false;
  String? _error;
  List<XScreenSource>? _sources;
  XScreenSource? _selected;
  MediaStream? _stream;
  RTCVideoRenderer? _renderer;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _release(_stream, _renderer);
    super.dispose();
  }

  Future<void> _probe() async {
    try {
      final available = await _backend.available();
      final permission = available && await _backend.hasPermission();
      if (!mounted) return;
      setState(() {
        _available = available;
        _permission = permission;
      });
    } on XScreenSourcesException catch (e) {
      if (!mounted) return;
      setState(() => _error = _format(e));
    }
  }

  Future<void> _request() async {
    try {
      final permission = await _backend.requestPermission();
      if (!mounted) return;
      setState(() => _permission = permission);
    } on XScreenSourcesException catch (e) {
      if (!mounted) return;
      setState(() => _error = _format(e));
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final primed = await ScreenSourcesPage.primeSources();
      final allowedDisplayIds = <String>{};
      final allowedWindowIds = <String>{};
      for (final source in primed) {
        switch (source.type) {
          case SourceType.Screen:
            allowedDisplayIds.add(source.id);
          case SourceType.Window:
            allowedWindowIds.add(source.id);
        }
      }
      final sources = await _backend.list(
        allowedDisplayIds: allowedDisplayIds,
        allowedWindowIds: allowedWindowIds,
      );
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _refreshing = false;
      });
    } on XScreenSourcesException catch (e) {
      if (!mounted) return;
      setState(() {
        _sources = null;
        _refreshing = false;
        _error = _format(e);
      });
    }
  }

  Future<void> _select(XScreenSource source) async {
    final stream = _stream;
    final renderer = _renderer;
    setState(() {
      _selected = source;
      _firstFrame = false;
      _error = null;
      _stream = null;
      _renderer = null;
    });
    await _release(stream, renderer);

    RTCVideoRenderer? next;
    try {
      next = RTCVideoRenderer();
      await next.initialize();
      next.onFirstFrameRendered = () {
        if (!mounted) return;
        setState(() => _firstFrame = true);
      };
      final captured = await navigator.mediaDevices.getDisplayMedia({
        'audio': false,
        'video': {
          'deviceId': {'exact': source.id},
          'mandatory': {'frameRate': 30.0},
        },
      });
      next.srcObject = captured;
      if (!mounted) {
        await _release(captured, next);
        return;
      }
      setState(() {
        _stream = captured;
        _renderer = next;
      });
    } catch (e) {
      await _release(null, next);
      if (!mounted) return;
      setState(() => _error = 'capture failed: $e');
    }
  }

  Future<void> _release(MediaStream? stream, RTCVideoRenderer? renderer) async {
    await renderer?.dispose();
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  String _format(XScreenSourcesException e) => '${e.code}: ${e.message ?? ''}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = _sources;
    final renderer = _renderer;
    return Scaffold(
      appBar: AppBar(title: const Text('XScreenSources')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'available: $_available · permission: $_permission',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            if (!_permission)
              FilledButton.icon(
                onPressed: _request,
                icon: const Icon(Icons.privacy_tip),
                label: const Text('Request screen recording'),
              )
            else
              FilledButton.icon(
                onPressed: _refreshing ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
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
            if (renderer != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: SizedBox(
                  height: 180,
                  child: RTCVideoView(
                    renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                ),
              ),
            if (_firstFrame)
              Padding(
                key: ScreenSourcesPage.firstFrameKey,
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'first frame: ${_selected?.title ?? ''}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 16),
            if (sources != null && sources.isEmpty)
              Text('No sources.', style: theme.textTheme.bodyMedium),
            if (sources != null && sources.isNotEmpty)
              Expanded(
                child: ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (context, i) => _SourceTile(
                    source: sources[i],
                    selected:
                        sources[i].id == _selected?.id &&
                        sources[i].kind == _selected?.kind,
                    onTap: () => _select(sources[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final XScreenSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final thumbnail = source.thumbnailPng;
    final application = source.applicationName;
    return ListTile(
      key: ScreenSourcesPage.sourceTileKey(source.kind, source.id),
      selected: selected,
      onTap: onTap,
      leading: SizedBox(
        width: 96,
        height: 54,
        child: thumbnail == null
            ? ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: Center(
                  child: Text(
                    'no thumbnail',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              )
            : Image.memory(thumbnail, fit: BoxFit.contain),
      ),
      title: Text(source.title),
      subtitle: Text(
        '${source.kind.name} · ${source.sourceWidth}×${source.sourceHeight}'
        '${application == null ? '' : ' · $application'}',
      ),
    );
  }
}
