import Flutter

/// Bridges the per-platform difference in `FlutterPluginRegistrar`:
/// `textures` and `messenger` are **methods** on the iOS variant
/// (`func textures() -> ...`) but **properties** on the macOS variant
/// (`var textures: ...`). Shared `CameraPlugin` calls
/// `registrar.uxTextures` and `registrar.uxMessenger` so the call
/// site stays platform-agnostic.
extension FlutterPluginRegistrar {
    var uxTextures: FlutterTextureRegistry { textures() }
    var uxMessenger: FlutterBinaryMessenger { messenger() }
}
