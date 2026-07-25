#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif
import ux_extension

// `ux_extension` stands alone so an app extension can link it without `ux`
// (Package.swift); `NativePlugin` lives here, so its conformances do too.
extension AppGroupPlugin: NativePlugin {}
extension CryptoPlugin: NativePlugin {}
extension VideoProbePlugin: NativePlugin {}
