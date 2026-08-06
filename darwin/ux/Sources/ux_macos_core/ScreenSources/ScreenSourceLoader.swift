import Foundation

/// One picker entry: a normalized source and the preview drawn for it.
public struct ScreenSourceSnapshotItem: Equatable, Sendable {
    public init(source: ScreenSource, thumbnailPng: Data?) {
        self.source = source
        self.thumbnailPng = thumbnailPng
    }

    public let source: ScreenSource

    /// `nil` when this source alone fails to render while the snapshot as a
    /// whole succeeds.
    public let thumbnailPng: Data?
}

/// Turns the capture stack's sources into one picker snapshot.
public struct ScreenSourceLoader {
    public init(capture: ScreenCapturing, maxConcurrentRenders: Int = 3) {
        self.capture = capture
        self.maxConcurrentRenders = max(1, maxConcurrentRenders)
    }

    private let capture: ScreenCapturing
    private let maxConcurrentRenders: Int

    /// The allowed sources present right now, displays before windows and in
    /// enumeration order within each kind.
    ///
    /// Throws ``ScreenSourceError/thumbnailFailed(_:)`` only when no allowed
    /// source renders at all.
    public func snapshot(
        allowedDisplayIds: Set<String>,
        allowedWindowIds: Set<String>,
        thumbnailWidth: Int,
        thumbnailHeight: Int
    ) async throws -> [ScreenSourceSnapshotItem] {
        if allowedDisplayIds.isEmpty, allowedWindowIds.isEmpty { return [] }

        let enumerated: [ScreenSource]
        do {
            enumerated = try await capture.shareableSources()
        } catch {
            throw ScreenSourceError.enumerationFailed(String(describing: error))
        }

        let normalized = enumerated.map {
            ScreenSourceNormalizer.normalize(
                kind: $0.kind,
                id: $0.id,
                title: $0.title,
                applicationName: $0.applicationName,
                width: $0.width,
                height: $0.height
            )
        }
        let allowed =
            normalized.filter { $0.kind == .display && allowedDisplayIds.contains($0.id) }
            + normalized.filter { $0.kind == .window && allowedWindowIds.contains($0.id) }
        if allowed.isEmpty { return [] }

        let thumbnails = await render(
            allowed,
            into: ScreenThumbnailSize(width: thumbnailWidth, height: thumbnailHeight)
        )
        if thumbnails.allSatisfy({ $0 == nil }) {
            throw ScreenSourceError.thumbnailFailed(
                "\(allowed.count) source(s) failed to render"
            )
        }

        return zip(allowed, thumbnails).map(ScreenSourceSnapshotItem.init)
    }

    private func render(
        _ sources: [ScreenSource],
        into bounds: ScreenThumbnailSize
    ) async -> [Data?] {
        let renderer = ScreenThumbnailRenderer(capture: capture)
        return await withTaskGroup(of: (Int, Data?).self) { group in
            var thumbnails = [Data?](repeating: nil, count: sources.count)
            var next = 0
            while next < min(maxConcurrentRenders, sources.count) {
                let index = next
                group.addTask { (index, await renderer.render(sources[index], into: bounds)) }
                next += 1
            }
            while let (index, thumbnail) = await group.next() {
                thumbnails[index] = thumbnail
                if next < sources.count {
                    let index = next
                    group.addTask { (index, await renderer.render(sources[index], into: bounds)) }
                    next += 1
                }
            }
            return thumbnails
        }
    }
}
