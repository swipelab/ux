import FlutterMacOS
import AppKit
import Quartz

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "share": handleShare(call, result: result)
        case "open":  handleOpen(call, result: result)
        default:      result(FlutterMethodNotImplemented)
        }
    }

    private func handleShare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let view = UxWindow.flutterView else {
            return result(FlutterError(code: "no_view", message: "no Flutter view", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let picker = NSSharingServicePicker(items: [url])

        let rect: NSRect
        if let r = args["sourceRect"] as? [String: Any],
           let x = (r["x"] as? NSNumber)?.doubleValue,
           let y = (r["y"] as? NSNumber)?.doubleValue,
           let w = (r["w"] as? NSNumber)?.doubleValue,
           let h = (r["h"] as? NSNumber)?.doubleValue {
            if view.isFlipped {
                rect = NSRect(x: x, y: y, width: w, height: h)
            } else {
                rect = NSRect(x: x, y: view.bounds.height - y - h, width: w, height: h)
            }
        } else {
            rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }

        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        result(true)
    }

    private func handleOpen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        let url = URL(fileURLWithPath: path)

        // Prefer in-app Quick Look (keeps Banlu in the foreground).
        // Fall back to NSWorkspace.open if there's no window to host the panel.
        if let flutterView = UxWindow.flutterView,
           let window = flutterView.window,
           let panel = QLPreviewPanel.shared() {
            let responder = UxQLPreviewResponder(url: url, window: window)
            flutterView.addSubview(responder)
            window.makeFirstResponder(responder)
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
            result(true)
            return
        }

        result(NSWorkspace.shared.open(url))
    }
}

private final class UxQLPreviewResponder: NSView, QLPreviewPanelDataSource {
    let url: URL
    private weak var previousFirstResponder: NSResponder?
    private weak var previousWindow: NSWindow?

    init(url: URL, window: NSWindow) {
        self.url = url
        self.previousWindow = window
        self.previousFirstResponder = window.firstResponder
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        let win = previousWindow
        let prev = previousFirstResponder
        DispatchQueue.main.async { [weak self] in
            win?.makeFirstResponder(prev)
            self?.removeFromSuperview()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as QLPreviewItem
    }
}
