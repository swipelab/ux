import FlutterMacOS

/// macOS counterpart of `ios/Classes/Camera/FlutterRegistrar+iOS.swift`.
/// On macOS, `FlutterPluginRegistrar.textures` and `.messenger` are
/// properties (no parens) rather than methods. Shared `CameraPlugin`
/// uses `registrar.uxTextures` and `registrar.uxMessenger` for
/// surface parity.
extension FlutterPluginRegistrar {
    var uxTextures: FlutterTextureRegistry { textures }
    var uxMessenger: FlutterBinaryMessenger { messenger }
}
