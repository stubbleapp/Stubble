import AppKit

@MainActor
final class AppIconResolver {
    static let shared = AppIconResolver()

    private var cache: [String: NSImage] = [:]
    private let fallbackIcon: NSImage

    private init() {
        fallbackIcon = NSWorkspace.shared.icon(for: .applicationBundle)
    }

    func icon(for bundleId: String?, size: CGFloat = 32) -> NSImage {
        guard let bundleId else { return sized(fallbackIcon, size) }

        if let cached = cache[bundleId] { return cached }

        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = fallbackIcon
        }

        let result = sized(icon, size)
        cache[bundleId] = result
        return result
    }

    private func sized(_ image: NSImage, _ size: CGFloat) -> NSImage {
        image.size = NSSize(width: size, height: size)
        return image
    }
}
