import SwiftUI
import AppKit

struct AppIconView: View {
    let bundleId: String?
    let size: CGFloat

    var body: some View {
        Image(nsImage: AppIconResolver.shared.icon(for: bundleId, size: size))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}
