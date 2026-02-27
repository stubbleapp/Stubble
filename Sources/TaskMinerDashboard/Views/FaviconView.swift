import SwiftUI

/// Displays a website favicon for a given domain.
/// Shows a globe fallback while the favicon is loading or unavailable.
struct FaviconView: View {
    let domain: String
    let size: CGFloat

    var body: some View {
        Group {
            if let nsImage = FaviconResolver.shared.favicon(for: domain, size: size) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(Theme.textQuaternary)
                    .frame(width: size, height: size)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            }
        }
        .unredacted()
    }
}

/// Favicon with domain label on hover, mirroring HoverableAppIconView.
struct HoverableFaviconView: View {
    let domain: String
    let size: CGFloat
    @State private var isHovered = false

    var body: some View {
        FaviconView(domain: domain, size: size)
            .popover(isPresented: $isHovered, arrowEdge: .bottom) {
                Text(domain)
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
