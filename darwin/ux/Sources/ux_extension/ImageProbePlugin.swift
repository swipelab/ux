import CoreGraphics
import Foundation
import ImageIO

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Describes an image file for `XImageProbe`: upright dimensions and a
/// downscaled PNG, without ever holding the full-resolution bitmap.
///
/// `CGImageSourceCopyPropertiesAtIndex` reads the header only, and
/// `CGImageSourceCreateThumbnailAtIndex` allocates for the *output* size — so
/// a 48-megapixel photo costs the same as a small one. That is the whole point:
/// decoding such a photo to read its size or make a 200px thumbnail costs
/// ~190 MB, several times an app extension's budget.
public class ImageProbePlugin: NSObject {
    // UTType.png needs iOS 14; the package deploys to 13.
    private static let pngType = "public.png" as CFString

    private var channel: FlutterMethodChannel?

    public func register(with registrar: FlutterPluginRegistrar) {
        #if os(iOS)
        let messenger = registrar.messenger()
        #else
        let messenger = registrar.messenger
        #endif
        let c = FlutterMethodChannel(name: "ux/image_probe", binaryMessenger: messenger)
        c.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        channel = c
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
            return result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        }
        switch call.method {
        case "size":      handleSize(path: path, result: result)
        case "thumbnail":
            let maxLongest = (args["maxLongest"] as? NSNumber)?.intValue ?? 0
            handleThumbnail(path: path, maxLongest: maxLongest, result: result)
        default:          result(FlutterMethodNotImplemented)
        }
    }

    private func handleSize(path: String, result: @escaping FlutterResult) {
        guard let source = imageSource(path), let size = displaySize(source) else {
            return result(nil)
        }
        result(["width": size.width, "height": size.height])
    }

    private func handleThumbnail(path: String, maxLongest: Int, result: @escaping FlutterResult) {
        guard maxLongest > 0 else {
            return result(FlutterError(code: "bad_args", message: "maxLongest must be > 0", details: nil))
        }
        guard let source = imageSource(path), let size = displaySize(source) else {
            return result(nil)
        }
        // kCGImageSourceCreateThumbnailWithTransform applies the EXIF
        // orientation, matching the dimensions reported above.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxLongest, max(size.width, size.height)),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = encodePng(thumb) else {
            return result(nil)
        }
        result([
            "sourceWidth": size.width,
            "sourceHeight": size.height,
            "width": thumb.width,
            "height": thumb.height,
            "png": FlutterStandardTypedData(bytes: png),
        ])
    }

    private func imageSource(_ path: String) -> CGImageSource? {
        let url = URL(fileURLWithPath: path) as CFURL
        // Not cached: one probe per file, and the cache would hold the decode.
        return CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Pixel dimensions with the EXIF orientation applied.
    private func displaySize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // 5...8 are the transposed/rotated-90° cases.
        return orientation >= 5 ? (width: height, height: width) : (width: width, height: height)
    }

    private func encodePng(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, ImageProbePlugin.pngType, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
