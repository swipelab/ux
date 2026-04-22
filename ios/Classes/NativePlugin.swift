import Flutter
import UIKit

public protocol NativePlugin {
    func register(with registrar: FlutterPluginRegistrar)
}

public enum UxWindow {
    public static var keyWindow: UIWindow? {
        if let w = UIApplication.shared.delegate?.window ?? nil { return w }
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows where window.isKeyWindow { return window }
        }
        return nil
    }

    public static var topViewController: UIViewController? {
        var vc = keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }
}
