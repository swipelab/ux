int _idCounter = 0;

/// Returns a monotonically increasing integer ID.
///
/// Useful for generating unique keys within a single isolate session.
/// Resets to 0 on app restart.
int nextId() => _idCounter++;
