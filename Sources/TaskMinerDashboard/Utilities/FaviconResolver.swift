import AppKit

/// Fetches and caches website favicons by domain name.
/// Uses Google's favicon service for reliable cross-site coverage.
///
/// Cache layers:
/// 1. In-memory dictionary (fastest, lost on quit)
/// 2. Disk cache in ~/Library/Caches/Stubble/favicons/ (survives restarts)
/// 3. Network fetch from Google's favicon API (async, triggers SwiftUI re-render)
@MainActor
final class FaviconResolver {
    static let shared = FaviconResolver()

    private var memoryCache: [String: NSImage] = [:]
    /// Tracks in-flight fetches to avoid duplicate requests for the same domain.
    private var inFlight: Set<String> = []
    /// Disk cache directory — ~/Library/Caches/Stubble/favicons/
    private let cacheDir: URL

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cachesDir.appendingPathComponent("Stubble/favicons")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Returns a cached favicon for the domain, or nil if not yet fetched.
    /// On cache miss, kicks off an async fetch — the caller's SwiftUI view will
    /// re-render when the image becomes available.
    func favicon(for domain: String, size: CGFloat = 32) -> NSImage? {
        let key = domain.lowercased()

        // 1. Memory cache
        if let cached = memoryCache[key] { return cached }

        // 2. Disk cache
        let diskPath = cacheDir.appendingPathComponent("\(key).png")
        if let diskImage = NSImage(contentsOf: diskPath) {
            let result = sized(diskImage, size)
            memoryCache[key] = result
            return result
        }

        // 3. Async network fetch
        if !inFlight.contains(key) {
            inFlight.insert(key)
            Task {
                await fetchAndCache(domain: key, size: size)
            }
        }

        return nil
    }

    // MARK: - Private

    private func fetchAndCache(domain: String, size: CGFloat) async {
        defer { inFlight.remove(domain) }

        // Google's favicon service — reliable, handles edge cases, consistent sizing
        let urlString = "https://www.google.com/s2/favicons?domain=\(domain)&sz=64"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let image = NSImage(data: data)
            else { return }

            let sizedImage = sized(image, size)
            memoryCache[domain] = sizedImage

            // Persist to disk cache
            let diskPath = cacheDir.appendingPathComponent("\(domain).png")
            try? data.write(to: diskPath, options: .atomic)
        } catch {
            // Silently fail — the view shows a globe fallback
        }
    }

    private func sized(_ image: NSImage, _ size: CGFloat) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        return NSImage(size: targetSize, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect,
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy,
                       fraction: 1)
            return true
        }
    }
}
