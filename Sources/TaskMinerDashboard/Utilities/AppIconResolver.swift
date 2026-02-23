import AppKit

/// Resolves app bundle IDs to icons with caching.
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]

    private init() {}

    /// Returns the app icon for the given bundle ID.
    /// When `bundleId` is nil or the app can't be found, returns `nil`
    /// so the view layer can show an appropriate fallback.
    func icon(for bundleId: String?, size: CGFloat = 32) -> NSImage? {
        guard let bundleId else { return nil }

        if let cached = cache[bundleId] { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            cache[bundleId] = nil
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let sizedResult = sized(icon, size)
        cache[bundleId] = sizedResult
        return sizedResult
    }

    private func sized(_ image: NSImage, _ size: CGFloat) -> NSImage {
        let targetSize = NSSize(width: size, height: size)
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1)
        newImage.unlockFocus()
        return newImage
    }
}
