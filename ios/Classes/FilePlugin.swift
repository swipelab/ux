import Flutter
import QuickLook
import UIKit

public class FilePlugin: NSObject, NativePlugin {
    private var channel: FlutterMethodChannel?
    private var previewDataSource: FilePreviewDataSource?

    public func register(with registrar: FlutterPluginRegistrar) {
        let c = FlutterMethodChannel(name: "ux/file", binaryMessenger: registrar.messenger())
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
        guard let topVC = UxWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let title = args["title"] as? String

        let items: [Any] = title.map { [FileActivityItemSource(url: url, title: $0)] } ?? [url]
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)

        if UIDevice.current.userInterfaceIdiom == .pad,
           let popover = vc.popoverPresentationController {
            popover.sourceView = topVC.view
            if let r = args["sourceRect"] as? [String: Any],
               let x = (r["x"] as? NSNumber)?.doubleValue,
               let y = (r["y"] as? NSNumber)?.doubleValue,
               let w = (r["w"] as? NSNumber)?.doubleValue,
               let h = (r["h"] as? NSNumber)?.doubleValue {
                popover.sourceRect = CGRect(x: x, y: y, width: w, height: h)
            } else {
                let b = topVC.view.bounds
                popover.sourceRect = CGRect(x: b.midX, y: b.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }

        topVC.present(vc, animated: true) {
            result(true)
        }
    }

    private func handleOpen(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        guard let topVC = UxWindow.topViewController else {
            return result(FlutterError(code: "no_view", message: "no top view controller", details: nil))
        }

        let url = URL(fileURLWithPath: path)
        let ds = FilePreviewDataSource(url: url)
        // QLPreviewController requires a strong-retained data source.
        previewDataSource = ds

        let vc = QLPreviewController()
        vc.dataSource = ds

        topVC.present(vc, animated: true) {
            result(true)
        }
    }
}

private final class FilePreviewDataSource: NSObject, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) { self.url = url }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        url as QLPreviewItem
    }
}

private final class FileActivityItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
        url
    }

    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        url
    }

    func activityViewController(_ controller: UIActivityViewController, subjectForActivityType type: UIActivity.ActivityType?) -> String {
        title
    }
}
