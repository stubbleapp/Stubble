import Foundation
import TaskMinerShared

class ScreenshotStorage {
    let directory: URL
    private let maxAgeDays: Int

    private static let dayDirFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    private static let fileFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    init(directory: URL, maxAgeDays: Int) throws {
        self.directory = directory
        self.maxAgeDays = maxAgeDays
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Validate the directory is not a symlink (prevents exfiltration via symlink replacement)
        let resolved = directory.resolvingSymlinksInPath()
        let standardized = directory.standardizedFileURL
        guard resolved.path == standardized.path else {
            Logger.error("ScreenshotStorage: symlink detected at \(directory.path) → \(resolved.path)")
            throw NSError(domain: "ScreenshotStorage", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Screenshot directory is a symlink — refusing to write"
            ])
        }
        // Restrict screenshots directory to owner-only access (0700) — contains captured screen content.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func generatePath(for date: Date) -> URL {
        let dayDir = directory.appendingPathComponent(Self.dayDirFmt.string(from: date))
        try? FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        // Validate subdirectory hasn't been replaced with a symlink
        if dayDir.resolvingSymlinksInPath().path != dayDir.standardizedFileURL.path {
            Logger.error("ScreenshotStorage: symlink detected at subdirectory \(dayDir.path)")
            return directory.appendingPathComponent("__symlink_rejected__")
        }
        // Restrict subdirectories to owner-only access
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dayDir.path)

        let suffix = UUID().uuidString.prefix(6).lowercased()
        let filename = "\(Self.fileFmt.string(from: date))_\(suffix).jpg"
        return dayDir.appendingPathComponent(filename)
    }

    /// Set owner-only permissions (0600) on a screenshot file after writing.
    func restrictPermissions(at path: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
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

    /// Remove specific screenshot files from disk by their relative paths.
    /// Also removes empty parent directories left behind.
    func cleanupFiles(relativePaths: [String]) {
        let fm = FileManager.default
        var emptyDirCandidates: Set<URL> = []

        for relPath in relativePaths {
            // Guard against path traversal from DB-sourced relative paths
            guard !relPath.contains("..") else {
                Logger.warning("ScreenshotStorage: skipping suspicious path containing '..': \(relPath)")
                continue
            }
            let fullPath = directory.appendingPathComponent(relPath)
            do {
                try fm.removeItem(at: fullPath)
                // Track parent dirs for cleanup
                emptyDirCandidates.insert(fullPath.deletingLastPathComponent())
            } catch {
                Logger.debug("Failed to remove screenshot file \(relPath): \(error.localizedDescription)")
            }
        }

        // Remove empty day/month/year directories bottom-up
        for dayDir in emptyDirCandidates {
            removeIfEmpty(dayDir, fm: fm)
            let monthDir = dayDir.deletingLastPathComponent()
            removeIfEmpty(monthDir, fm: fm)
            let yearDir = monthDir.deletingLastPathComponent()
            removeIfEmpty(yearDir, fm: fm)
        }

        if !relativePaths.isEmpty {
            Logger.info("Cleaned up \(relativePaths.count) screenshot file(s)")
        }
    }

    private func removeIfEmpty(_ dir: URL, fm: FileManager) {
        // Don't remove the root screenshots directory
        guard dir != directory else { return }
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty else { return }
        try? fm.removeItem(at: dir)
    }

}
