import AppKit

/// Resolves app bundle IDs to icons with caching.
@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]

    private init() {}

    /// Returns the app icon for the given bundle ID.
    /// When `bundleId` is nil or the app can't be found, returns `nil`
    /// so the view layer can show an appropriate fallback.
    /// Note: cache misses are NOT stored, so newly-installed apps are found on next lookup.
    func icon(for bundleId: String?, size: CGFloat = 32) -> NSImage? {
        guard let bundleId else { return nil }

        if let cached = cache[bundleId] { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let sizedResult = sized(icon, size)
        cache[bundleId] = sizedResult
        return sizedResult
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
