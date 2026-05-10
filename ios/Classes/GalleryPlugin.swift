import Flutter
import Photos
import PhotosUI
import UIKit

/// `Photos.framework` bridge for `UxGallery` — paginated asset queries,
/// cell-sized thumbnails via `PHCachingImageManager`, and on-demand
/// file resolution into the app cache.
public class GalleryPlugin: NSObject, NativePlugin {
    private let imageManager = PHCachingImageManager()
    private var fetchCache: [String: PHFetchResult<PHAsset>] = [:]

    public func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "ux/gallery",
            binaryMessenger: registrar.messenger(),
        )
        channel.setMethodCallHandler { [weak self] call, result in
            self?.handle(call: call, result: result)
        }
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "permission":
            result(Self.permissionString(Self.currentAuthorization()))
        case "requestPermission":
            Self.requestAuthorization { status in
                DispatchQueue.main.async {
                    result(Self.permissionString(status))
                }
            }
        case "openSettings":
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            result(nil)
        case "presentLimitedLibraryPicker":
            if #available(iOS 14, *), let vc = UxWindow.topViewController {
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
            }
            result(nil)
        case "albums":
            handleAlbums(call: call, result: result)
        case "assets":
            handleAssets(call: call, result: result)
        case "thumbnail":
            handleThumbnail(call: call, result: result)
        case "resolveFile":
            handleResolveFile(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Permission

    private static func currentAuthorization() -> PHAuthorizationStatus {
        if #available(iOS 14, *) {
            return PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        return PHPhotoLibrary.authorizationStatus()
    }

    private static func requestAuthorization(_ handler: @escaping (PHAuthorizationStatus) -> Void) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite, handler: handler)
        } else {
            PHPhotoLibrary.requestAuthorization(handler)
        }
    }

    private static func permissionString(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "granted"
        default:
            // .limited is iOS 14+; reaching here on iOS 13 means a future
            // case we don't handle yet — treat as denied to be safe.
            if #available(iOS 14, *), status == .limited { return "limited" }
            return "denied"
        }
    }

    // MARK: - Albums

    /// Subset of smart albums we expose. Cut: bursts, animated, depth-effect,
    /// long-exposure, panoramas, slo-mo, etc. — matches the picker's scope cuts.
    private static let smartAlbumKept: [PHAssetCollectionSubtype] = [
        .smartAlbumVideos,
        .smartAlbumFavorites,
        .smartAlbumScreenshots,
    ]

    private func handleAlbums(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let filter = Self.kindFilter(args["filter"])

        let baseOptions = PHFetchOptions()
        if let f = filter {
            baseOptions.predicate = NSPredicate(format: "mediaType == %d", f.rawValue)
        }

        var albums: [[String: Any?]] = []

        // Recents — virtual album over the entire library.
        let recents = PHAsset.fetchAssets(with: baseOptions)
        if recents.count > 0 {
            albums.append([
                "id": "recents",
                "name": "Recents",
                "count": recents.count,
                "cover_kind": Self.coverKindString(recents.firstObject),
            ])
        }

        // Smart albums.
        for subtype in Self.smartAlbumKept {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum, subtype: subtype, options: nil,
            )
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: baseOptions)
                if assets.count > 0 {
                    albums.append([
                        "id": collection.localIdentifier,
                        "name": collection.localizedTitle ?? "",
                        "count": assets.count,
                        "cover_kind": Self.coverKindString(assets.firstObject),
                    ])
                }
            }
        }

        // User albums.
        let userCollections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil,
        )
        userCollections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: baseOptions)
            if assets.count > 0 {
                albums.append([
                    "id": collection.localIdentifier,
                    "name": collection.localizedTitle ?? "",
                    "count": assets.count,
                    "cover_kind": Self.coverKindString(assets.firstObject),
                ])
            }
        }

        result(albums)
    }

    private static func coverKindString(_ asset: PHAsset?) -> String? {
        guard let asset else { return nil }
        return asset.mediaType == .video ? "video" : "image"
    }

    // MARK: - Assets

    private static func kindFilter(_ raw: Any?) -> PHAssetMediaType? {
        switch raw as? String {
        case "image": return .image
        case "video": return .video
        default: return nil
        }
    }

    private func handleAssets(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        let albumId = args["albumId"] as? String
        let filterRaw = args["filter"] as? String ?? "any"
        let filter = Self.kindFilter(filterRaw)
        let start = args["start"] as? Int ?? 0
        let end = args["end"] as? Int ?? 0

        let cacheKey = "\(albumId ?? "_recents")|\(filterRaw)"
        let fetch = fetchCache[cacheKey] ?? {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            if let f = filter {
                options.predicate = NSPredicate(format: "mediaType == %d", f.rawValue)
            }
            let result: PHFetchResult<PHAsset>
            if let id = albumId, id != "recents" {
                if let collection = PHAssetCollection.fetchAssetCollections(
                    withLocalIdentifiers: [id], options: nil,
                ).firstObject {
                    result = PHAsset.fetchAssets(in: collection, options: options)
                } else {
                    result = PHAsset.fetchAssets(with: options)
                }
            } else {
                result = PHAsset.fetchAssets(with: options)
            }
            fetchCache[cacheKey] = result
            return result
        }()

        let total = fetch.count
        let from = max(0, min(start, total))
        let to = max(from, min(end, total))
        var assets: [[String: Any?]] = []
        assets.reserveCapacity(to - from)
        for i in from..<to {
            assets.append(Self.assetMap(fetch.object(at: i)))
        }
        result(assets)
    }

    private static func assetMap(_ asset: PHAsset) -> [String: Any?] {
        return [
            "id": asset.localIdentifier,
            "kind": asset.mediaType == .video ? "video" : "image",
            "duration_ms": asset.mediaType == .video ? Int(asset.duration * 1000) : nil,
            "width": asset.pixelWidth,
            "height": asset.pixelHeight,
            "created_ms": Int((asset.creationDate ?? Date()).timeIntervalSince1970 * 1000),
        ]
    }

    // MARK: - Thumbnail

    private func handleThumbnail(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let assetId = args["assetId"] as? String,
              let sizePx = args["sizePx"] as? Int
        else {
            result(FlutterError(code: "bad_args", message: "missing assetId/sizePx", details: nil))
            return
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetId], options: nil,
        ).firstObject else {
            result(FlutterError(code: "not_found", message: "no asset for id", details: nil))
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false

        let target = CGSize(width: sizePx, height: sizePx)
        var delivered = false

        imageManager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: options,
        ) { image, info in
            // requestImage fires twice (degraded preview + final). Skip the
            // preview so the channel emits exactly once.
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if delivered { return }
            if isDegraded { return }
            delivered = true

            guard let image, let data = image.jpegData(compressionQuality: 0.85) else {
                let err = FlutterError(
                    code: "encode_failed",
                    message: "thumbnail unavailable",
                    details: nil,
                )
                DispatchQueue.main.async { result(err) }
                return
            }

            DispatchQueue.main.async {
                result([
                    "bytes": FlutterStandardTypedData(bytes: data),
                    "width": Int(image.size.width * image.scale),
                    "height": Int(image.size.height * image.scale),
                ])
            }
        }
    }

    // MARK: - File resolution

    private func handleResolveFile(call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let assetId = args["assetId"] as? String else {
            result(FlutterError(code: "bad_args", message: "missing assetId", details: nil))
            return
        }
        guard let asset = PHAsset.fetchAssets(
            withLocalIdentifiers: [assetId], options: nil,
        ).firstObject else {
            result(FlutterError(code: "not_found", message: "no asset for id", details: nil))
            return
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { r in
            switch r.type {
            case .photo, .video, .fullSizePhoto, .fullSizeVideo: return true
            default: return false
            }
        } ?? resources.first

        guard let resource = primary else {
            result(FlutterError(code: "no_resource", message: "asset has no readable resource", details: nil))
            return
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ux_gallery", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDir, withIntermediateDirectories: true,
        )

        let ext = (resource.originalFilename as NSString).pathExtension
        let safe = assetId.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDir.appendingPathComponent(
            "\(safe).\(ext.isEmpty ? "bin" : ext)",
        )

        if FileManager.default.fileExists(atPath: fileURL.path) {
            result(fileURL.path)
            return
        }

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(
            for: resource, toFile: fileURL, options: opts,
        ) { error in
            DispatchQueue.main.async {
                if let error {
                    result(FlutterError(
                        code: "write_failed",
                        message: error.localizedDescription,
                        details: nil,
                    ))
                } else {
                    result(fileURL.path)
                }
            }
        }
    }
}
