import SwiftUI

struct AppIconView: View {
    let bundleId: String?
    let size: CGFloat

    /// macOS app icons have built-in canvas padding (~15%).
    /// Scale up so the visible icon art fills the frame tightly.
    private let iconScale: CGFloat = 1.25

    var body: some View {
        if let nsImage = AppIconResolver.shared.icon(for: bundleId, size: size * iconScale) {
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
}
