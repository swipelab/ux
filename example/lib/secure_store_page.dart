import 'package:flutter/material.dart';
import 'package:ux/secure_store.dart';

/// Demonstrates XSecureStore: write a value under a key, read it back, and
/// delete it — the round trip a session token makes through the OS credential
/// store.
class SecureStorePage extends StatefulWidget {
  /// Creates the page.
  const SecureStorePage({super.key});

  @override
  State<SecureStorePage> createState() => _SecureStorePageState();
}

class _SecureStorePageState extends State<SecureStorePage> {
  final _store = XSecureStore.instance;
  final _key = TextEditingController(text: 'session');
  final _value = TextEditingController(text: 'token-1');

  String _result = '';

  @override
  void dispose() {
    _key.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _run(String label, Future<String?> Function() command) async {
    try {
      final value = await command();
      if (!mounted) return;
      setState(() => _result = '$label → ${value ?? 'null'}');
    } on XSecureStoreException catch (e) {
      if (!mounted) return;
      setState(() => _result = '$label ✗ ${e.code}: ${e.message ?? ''}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _key.text;
    return Scaffold(
      appBar: AppBar(title: const Text('XSecureStore')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _key,
              decoration: const InputDecoration(labelText: 'key'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _value,
              decoration: const InputDecoration(labelText: 'value'),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _store.supported
                  ? () => _run('write', () async {
                        await _store.write(key, _value.text);
                        return _value.text;
                      })
                  : null,
              icon: const Icon(Icons.lock),
              label: const Text('Write'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  _store.supported ? () => _run('read', () => _store.read(key)) : null,
              icon: const Icon(Icons.lock_open),
              label: const Text('Read'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _store.supported
                  ? () => _run('delete', () async {
                        await _store.delete(key);
                        return null;
                      })
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete'),
            ),
            const SizedBox(height: 24),
            Text(_result, style: theme.textTheme.bodyMedium),
            if (!_store.supported)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'No native store on this platform.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
