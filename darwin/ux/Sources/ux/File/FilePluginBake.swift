import CoreGraphics
import Foundation
import ImageIO

/// `XFiles.videoThumbnail`'s baked path — composite + affine + downscale
/// + PNG encode on the CG software rasteriser. Shares the exporter's
/// geometry contract: [transform] is the row-major 3×3 upright-source-px
/// → output-px affine, [overlayPath] (strokes PNG at upright source
/// dims) composites BEFORE the affine, and the [outWidth]×[outHeight]
/// result is scaled so its longest edge fits [maxLongest].
enum FilePluginBake {
    static func bakeThumb(
        frame: CGImage,
        transform: [Double],
        outWidth: Int,
        outHeight: Int,
        overlayPath: String?,
        maxLongest: Int?
    ) -> (png: Data, width: Int, height: Int)? {
        let longest = max(outWidth, outHeight)
        var scale = 1.0
        if let maxLongest, longest > maxLongest {
            scale = Double(maxLongest) / Double(longest)
        }
        let thumbW = max(1, Int((Double(outWidth) * scale).rounded()))
        let thumbH = max(1, Int((Double(outHeight) * scale).rounded()))

        guard let ctx = CGContext(
            data: nil, width: thumbW, height: thumbH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium

        // The affine is top-left y-down; CG draws bottom-left y-up. Outer
        // flip into y-down space, then a per-image inner flip keeps each
        // bitmap upright (the exporter's renderOverlay convention).
        ctx.concatenate(
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(thumbH)))
        ctx.scaleBy(
            x: CGFloat(thumbW) / CGFloat(outWidth),
            y: CGFloat(thumbH) / CGFloat(outHeight))
        // Row-major [a,b,tx, d,e,ty, …] — CG's convention is the transpose.
        ctx.concatenate(CGAffineTransform(
            a: transform[0], b: transform[3], c: transform[1], d: transform[4],
            tx: transform[2], ty: transform[5]))

        func drawUpright(_ image: CGImage) {
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(image.height)))
            ctx.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            ctx.restoreGState()
        }
        drawUpright(frame)
        if let overlayPath,
           let provider = CGDataProvider(url: URL(fileURLWithPath: overlayPath) as CFURL),
           let overlay = CGImage(
               pngDataProviderSource: provider, decode: nil,
               shouldInterpolate: true, intent: .defaultIntent) {
            drawUpright(overlay)
        }

        guard let baked = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, baked, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, thumbW, thumbH)
    }
}
