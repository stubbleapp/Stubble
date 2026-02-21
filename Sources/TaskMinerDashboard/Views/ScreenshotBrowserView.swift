import SwiftUI
import TaskMinerShared

struct ScreenshotBrowserView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var selectedScreenshot: ScreenshotRecord?

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Screenshots")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(viewModel.screenshots.count) screenshots")
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding()

            if viewModel.screenshots.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textQuaternary)
                    Text("No screenshots for this day")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.screenshots) { screenshot in
                            ScreenshotThumbnailView(
                                screenshot: screenshot,
                                screenshotDir: viewModel.config.screenshotDirectory
                            )
                            .onTapGesture {
                                selectedScreenshot = screenshot
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $selectedScreenshot) { screenshot in
            ScreenshotDetailView(
                screenshot: screenshot,
                screenshotDir: viewModel.config.screenshotDirectory,
                dbReader: viewModel.dbReader,
                tasks: viewModel.tasks
            )
        }
    }
}
