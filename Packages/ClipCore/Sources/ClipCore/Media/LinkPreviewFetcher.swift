import Foundation
#if canImport(LinkPresentation)
import LinkPresentation
#endif

// Owned by the extensions engineer. Cross-platform (macOS 14 / iOS 17).

/// Link title + icon (+ preview image) via `LPMetadataProvider`.
///
/// - Only `http`/`https` URLs with a host are fetched; anything else returns nil
///   immediately without touching the network.
/// - A new provider per call (they are single-use), started on the main queue.
/// - Hard deadline: `timeout` for the page fetch, plus a short bounded budget for
///   icon/image loading. Offline / errors / timeouts → nil.
/// - Icon is re-encoded as PNG ≤ 128 px, preview image as JPEG/PNG ≤ 800 px, so the
///   stored internal representations stay small.
public struct LinkPreviewFetcher: LinkMetadataFetching {
    public var timeout: TimeInterval
    public var includesPreviewImage: Bool
    public var iconMaxPixelSize: Int
    public var previewImageMaxPixelSize: Int

    public init(
        timeout: TimeInterval = 10,
        includesPreviewImage: Bool = true,
        iconMaxPixelSize: Int = 128,
        previewImageMaxPixelSize: Int = 800
    ) {
        self.timeout = timeout
        self.includesPreviewImage = includesPreviewImage
        self.iconMaxPixelSize = iconMaxPixelSize
        self.previewImageMaxPixelSize = previewImageMaxPixelSize
    }

    /// True only for http(s) URLs with a non-empty host.
    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        guard let host = url.host, !host.isEmpty else { return false }
        return true
    }

    public func fetchMetadata(for url: URL) async -> LinkMetadata? {
        guard LinkPreviewFetcher.isFetchable(url) else { return nil }
        #if canImport(LinkPresentation)
        let pageTimeout = max(1, timeout)
        guard let fetched = await LinkPreviewFetcher.fetchLinkMetadata(url: url, timeout: pageTimeout) else {
            return nil
        }
        // Sub-resource budget: icons/images are usually already downloaded by LP.
        let assetTimeout: TimeInterval = min(5, pageTimeout)

        var result = LinkMetadata()
        if let title = fetched.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            result.title = title
        }
        if let iconProvider = fetched.iconProvider {
            if let raw = await ItemProviderLoader.loadData(from: iconProvider, typeIdentifier: ClipUTI.image, timeout: assetTimeout) {
                result.iconData = ImageEncoding.normalizedPNG(from: raw, maxPixelSize: iconMaxPixelSize)
            }
        }
        if includesPreviewImage, let imageProvider = fetched.imageProvider {
            if let raw = await ItemProviderLoader.loadData(from: imageProvider, typeIdentifier: ClipUTI.image, timeout: assetTimeout) {
                result.imageData = ImageEncoding.normalizedCompact(from: raw, maxPixelSize: previewImageMaxPixelSize)
            }
        }
        if result.title == nil && result.iconData == nil && result.imageData == nil {
            return nil
        }
        return result
        #else
        return nil
        #endif
    }

    #if canImport(LinkPresentation)
    /// What we keep from `LPLinkMetadata` (extracted inside the completion handler).
    private struct FetchedLink: @unchecked Sendable {
        var title: String?
        var iconProvider: NSItemProvider?
        var imageProvider: NSItemProvider?
    }

    private static func fetchLinkMetadata(url: URL, timeout: TimeInterval) async -> FetchedLink? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<FetchedLink?, Never>) in
            let once = OneShotContinuation<FetchedLink?>(continuation)
            // Created, started and cancelled on the main actor (safe whatever LP's isolation is).
            Task { @MainActor in
                let provider = LPMetadataProvider()
                provider.timeout = timeout
                provider.startFetchingMetadata(for: url) { @Sendable metadata, error in
                    guard error == nil, let metadata = metadata else {
                        once.resume(returning: nil)
                        return
                    }
                    once.resume(returning: FetchedLink(
                        title: metadata.title,
                        iconProvider: metadata.iconProvider,
                        imageProvider: metadata.imageProvider
                    ))
                }
                // @Sendable: LP calls back on a background queue, so this closure must not be
                // inferred main-actor-isolated. Backstop below keeps `provider` alive.
                try? await Task.sleep(nanoseconds: UInt64((timeout + 1) * 1_000_000_000))
                if once.resume(returning: nil) {
                    provider.cancel()
                }
            }
        }
    }
    #endif
}

// MARK: - Timed NSItemProvider loading (also used by the share extension)

/// `NSItemProvider` loaders with a hard timeout. Each returns nil on error or timeout
/// and never resumes twice. Transform closures run inside the provider's completion
/// handler (on a background queue) — e.g. to read a temporary file before it is deleted.
public enum ItemProviderLoader {
    /// `loadDataRepresentation` (bytes in memory).
    public static func loadData(from provider: NSItemProvider, typeIdentifier: String, timeout: TimeInterval) async -> Data? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let once = OneShotContinuation<Data?>(continuation)
            let progress = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                once.resume(returning: data)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.1, timeout)) {
                if once.resume(returning: nil) {
                    progress.cancel()
                }
            }
        }
    }

    /// `loadFileRepresentation`: `transform` receives the temporary file URL, which is
    /// only valid while the transform runs.
    public static func loadFile<T: Sendable>(
        from provider: NSItemProvider,
        typeIdentifier: String,
        timeout: TimeInterval,
        transform: @escaping @Sendable (URL) -> T?
    ) async -> T? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OneShotContinuation<T?>(continuation)
            let progress = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url = url else {
                    once.resume(returning: nil)
                    return
                }
                once.resume(returning: transform(url))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.1, timeout)) {
                if once.resume(returning: nil) {
                    progress.cancel()
                }
            }
        }
    }

    /// `loadItem` (String / URL / Data / UIImage ...): `transform` converts the
    /// coerced object into a Sendable value.
    public static func loadItem<T: Sendable>(
        from provider: NSItemProvider,
        typeIdentifier: String,
        timeout: TimeInterval,
        transform: @escaping @Sendable (NSSecureCoding?) -> T?
    ) async -> T? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OneShotContinuation<T?>(continuation)
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if error != nil {
                    once.resume(returning: nil)
                    return
                }
                once.resume(returning: transform(item))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.1, timeout)) {
                once.resume(returning: nil)
            }
        }
    }
}

/// Resumes a continuation at most once (completion handler vs. timeout race).
final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// Returns true if this call resumed the continuation (false if already resumed).
    @discardableResult
    func resume(returning value: T) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending = pending else { return false }
        pending.resume(returning: value)
        return true
    }
}
