import SwiftUI

struct AppIconView: View {
    let bundleId: String?
    var appName: String? = nil
    let size: CGFloat

    /// macOS app icons have built-in canvas padding (~15%).
    /// Scale up so the visible icon art fills the frame tightly.
    private let iconScale: CGFloat = 1.25

    private var resolvedIcon: NSImage? {
        // Try bundle ID first
        if let icon = AppIconResolver.shared.icon(for: bundleId, size: size * iconScale) {
            return icon
        }
        // Fall back to app name lookup
        if let name = appName, let icon = AppIconResolver.shared.icon(forAppName: name, size: size * iconScale) {
            return icon
        }
        return nil
    }

    var body: some View {
        Group {
            if let nsImage = resolvedIcon {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size * iconScale, height: size * iconScale)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                // Visible fallback when no icon can be resolved
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(Theme.textQuaternary)
                    .frame(width: size, height: size)
                    .background(Theme.surfaceElevated)
            }
        }
        .unredacted()
    }
}

/// App icon that shows the app name in a popover on hover (instantly, no delay).
/// Uses NSPopover so the label is never clipped by parent views.
struct HoverableAppIconView: View {
    let appName: String
    let bundleId: String?
    let size: CGFloat
    @State private var isHovered = false

    var body: some View {
        AppIconView(bundleId: bundleId, appName: appName, size: size)
            .popover(isPresented: $isHovered, arrowEdge: .bottom) {
                Text(appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
