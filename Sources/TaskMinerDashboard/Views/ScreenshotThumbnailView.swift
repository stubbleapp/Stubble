import SwiftUI
import TaskMinerShared

struct ScreenshotThumbnailView: View {
    let screenshot: ScreenshotRecord
    let screenshotDir: URL
    var isSelected: Bool = false

    @State private var thumbnail: NSImage?

    private var fullPath: URL {
        screenshotDir.appendingPathComponent(screenshot.filePath)
    }

    private var isFileDeleted: Bool {
        screenshot.filePath.isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if isFileDeleted {
                    Rectangle()
                        .fill(Theme.cardBackground)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.title3)
                                    .foregroundStyle(Theme.textMuted)
                                Text("OCR only")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        )
                } else if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Theme.cardBackground)
                        .overlay(ProgressView().scaleEffect(0.5))
                }
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 2.5)
            )
            .overlay(alignment: .topLeading) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.accent)
                        .background(Circle().fill(Color.white).padding(2))
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)

            HStack {
                Text(screenshot.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(screenshot.trigger.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(triggerColor.opacity(0.12))
                    .foregroundStyle(triggerColor)
                    .cornerRadius(4)
            }
        }
        .task(id: screenshot.id) {
            guard !isFileDeleted else { return }
            thumbnail = await ThumbnailCache.shared.thumbnail(
                for: fullPath, maxSize: CGSize(width: 400, height: 300)
            )
        }
    }

    private var triggerColor: Color {
        switch screenshot.trigger {
        case .appSwitch: return Theme.triggerAppSwitch
        case .titleChange: return Theme.triggerTitleChange
        case .periodic: return Theme.triggerPeriodic
        case .manual: return Theme.triggerManual
        }
    }
}
