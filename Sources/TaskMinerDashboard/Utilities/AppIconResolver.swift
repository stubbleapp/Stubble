import AppKit

/// Resolves app bundle IDs to icons with caching.
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]
    private let fallbackIcon: NSImage = NSImage(systemSymbolName: "app.badge", accessibilityDescription: nil) ?? NSImage()

    private init() {}

    func icon(for bundleId: String?, size: CGFloat = 32) -> NSImage {
        guard let bundleId else { return sized(fallbackIcon, size) }

        if let cached = cache[bundleId] { return cached }

        var result = fallbackIcon
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            result = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        let sizedResult = sized(result, size)
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
