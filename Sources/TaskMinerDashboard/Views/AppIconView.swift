import SwiftUI

struct AppIconView: View {
    let bundleId: String?
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: AppIconResolver.shared.icon(for: bundleId, size: size))
            .resizable()
            .frame(width: size, height: size)
    }
}
