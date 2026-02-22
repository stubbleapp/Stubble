import Foundation
import AppKit
import CoreGraphics
import TaskMinerShared

class ScreenshotCapture {
    private let quality: CGFloat

    init(quality: CGFloat) {
        self.quality = quality
    }

    func captureFullScreen() -> CGImage? {
        // CGWindowListCreateImage captures all windows on the main display
        let image = CGWindowListCreateImage(
            CGRect.null, // null = entire main display
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        )
        return image
    }

    func saveAsJPEG(image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            Logger.error("Failed to create image destination at \(url.path)")
            return false
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)

        if CGImageDestinationFinalize(destination) {
            Logger.debug("Screenshot saved: \(url.lastPathComponent)")
            return true
        } else {
            Logger.error("Failed to finalize image at \(url.path)")
            return false
        }
    }

    func captureAndSave(to url: URL) -> Bool {
        guard let image = captureFullScreen() else {
            Logger.error("Screenshot capture failed")
            return false
        }
        return saveAsJPEG(image: image, to: url)
    }
}
