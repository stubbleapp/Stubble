import Foundation
import TaskMinerShared

class ScreenshotStorage {
    let directory: URL
    private let maxAgeDays: Int

    init(directory: URL, maxAgeDays: Int) throws {
        self.directory = directory
        self.maxAgeDays = maxAgeDays
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func generatePath(for date: Date) -> URL {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let dayDir = directory.appendingPathComponent(dayFormatter.string(from: date))
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)

        let fileFormatter = DateFormatter()
        fileFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let filename = "\(fileFormatter.string(from: date))_\(suffix).jpg"
        return dayDir.appendingPathComponent(filename)
    }

    func relativePath(for fullPath: URL) -> String {
        let base = directory.path
        let full = fullPath.path
        if full.hasPrefix(base) {
            let start = full.index(full.startIndex, offsetBy: base.count + 1)
            return String(full[start...])
        }
        return full
    }

    func fileSize(at path: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int
    }

    /// Remove screenshot files and folders for any day that is not today.
    /// Keeps only the current day to limit disk usage.
    func cleanupKeepingOnlyToday() {
        let fm = FileManager.default
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy/MM/dd"
        let todayStr = todayFormatter.string(from: today)

        guard let yearDirs = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"

        for yearDir in yearDirs {
            guard (try? yearDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let monthDirs = try? fm.contentsOfDirectory(
                at: yearDir, includingPropertiesForKeys: [.isDirectoryKey]
            ) else { continue }

            for monthDir in monthDirs {
                guard (try? monthDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                guard let dayDirs = try? fm.contentsOfDirectory(
                    at: monthDir, includingPropertiesForKeys: [.isDirectoryKey]
                ) else { continue }

                for dayDir in dayDirs {
                    guard (try? dayDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    let components = dayDir.pathComponents
                    let count = components.count
                    guard count >= 3 else { continue }
                    let dateStr = "\(components[count-3])/\(components[count-2])/\(components[count-1])"
                    if dateStr == todayStr { continue }

                    do {
                        try fm.removeItem(at: dayDir)
                        Logger.info("Cleaned up screenshots for \(dateStr) (keeping only today)")
                    } catch {
                        Logger.warning("Failed to clean up \(dateStr): \(error)")
                    }
                }
            }
        }
    }

    /// Legacy name for compatibility; now keeps only today.
    func cleanupOldScreenshots() {
        cleanupKeepingOnlyToday()
    }
}
