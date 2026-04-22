import FlutterMacOS
import AppKit

public protocol NativePlugin {
    func register(with registrar: FlutterPluginRegistrar)
}

public enum UxWindow {
    public static var keyWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    /// FlutterViewController's view. Used as the anchor for
    /// `NSSharingServicePicker` popovers.
    public static var flutterView: NSView? {
        keyWindow?.contentViewController?.view
    }
}
