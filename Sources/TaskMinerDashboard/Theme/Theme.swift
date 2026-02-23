import SwiftUI
import AppKit

/// Adaptive color palette — works in both light and dark mode.
/// Dark: deep grays, clear hierarchy, orange-red accent.
/// Light: clean whites/grays with the same accent and status colors.
enum Theme {

    // MARK: - Adaptive Color Helper

    /// Creates a SwiftUI Color that adapts to the system appearance.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Backgrounds

    /// Primary background — main content area.
    static let primaryBackground = adaptive(
        light: NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1),
        dark: NSColor(red: 0.102, green: 0.102, blue: 0.106, alpha: 1)
    )

    /// Secondary background — toolbars, sidebars, input areas.
    static let secondaryBackground = adaptive(
        light: NSColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
        dark: NSColor(red: 0.145, green: 0.145, blue: 0.153, alpha: 1)
    )

    /// Elevated surface — segmented controls, group headers.
    static let surfaceElevated = adaptive(
        light: NSColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1),
        dark: NSColor(red: 0.173, green: 0.173, blue: 0.18, alpha: 1)
    )

    /// Card / bubble background.
    static let cardBackground = adaptive(
        light: .white,
        dark: NSColor(red: 0.20, green: 0.20, blue: 0.21, alpha: 1)
    )

    /// Selected item background.
    static let selectedSurface = adaptive(
        light: .white,
        dark: NSColor(red: 0.28, green: 0.28, blue: 0.29, alpha: 1)
    )

    // MARK: - Text

    /// Primary text — headings, main content.
    static let textPrimary = adaptive(
        light: NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
        dark: NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    )

    /// Secondary text — labels, metadata.
    static let textSecondary = adaptive(
        light: NSColor(red: 0.38, green: 0.38, blue: 0.40, alpha: 1),
        dark: NSColor(red: 0.68, green: 0.68, blue: 0.70, alpha: 1)
    )

    /// Muted / tertiary — timestamps, inactive icons.
    static let textMuted = adaptive(
        light: NSColor(red: 0.52, green: 0.52, blue: 0.54, alpha: 1),
        dark: NSColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)
    )

    /// Quaternary — very subtle labels.
    static let textQuaternary = adaptive(
        light: NSColor(red: 0.65, green: 0.65, blue: 0.67, alpha: 1),
        dark: NSColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1)
    )

    // MARK: - Accent & Actions

    /// Primary accent — CTAs, links (orange-red).
    static let accent = Color(red: 0.91, green: 0.36, blue: 0.29)

    // MARK: - Borders & Dividers

    static let separator = adaptive(
        light: NSColor(red: 0.85, green: 0.85, blue: 0.86, alpha: 1),
        dark: NSColor(red: 0.33, green: 0.33, blue: 0.35, alpha: 1)
    )

    static let cardBorder = adaptive(
        light: NSColor(red: 0.88, green: 0.88, blue: 0.89, alpha: 1),
        dark: NSColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1)
    )

    // MARK: - Timeline

    static let spineLine = adaptive(
        light: NSColor(red: 0.80, green: 0.80, blue: 0.82, alpha: 0.8),
        dark: NSColor(red: 0.33, green: 0.33, blue: 0.35, alpha: 0.6)
    )

    static let gapDot = adaptive(
        light: NSColor(red: 0.72, green: 0.72, blue: 0.74, alpha: 1),
        dark: NSColor(red: 0.40, green: 0.40, blue: 0.42, alpha: 1)
    )

    // MARK: - Confidence (task dots)

    static let confidenceHigh = Color(red: 0.35, green: 0.75, blue: 0.55)
    static let confidenceMedium = Color(red: 0.90, green: 0.70, blue: 0.35)
    static let confidenceLow = Color(red: 0.91, green: 0.36, blue: 0.29)

    // MARK: - Status

    static let statusActive = Color(red: 0.35, green: 0.75, blue: 0.55)
    static let statusPaused = Color(red: 0.90, green: 0.70, blue: 0.35)
    static let statusError = Color(red: 0.91, green: 0.36, blue: 0.29)

    // MARK: - Activity bar palette (maximally distinct, evenly spaced hues)

    static let barPalette: [Color] = [
        Color(red: 0.35, green: 0.55, blue: 0.82),   // 0 — Blue
        Color(red: 0.90, green: 0.55, blue: 0.30),   // 1 — Orange
        Color(red: 0.35, green: 0.72, blue: 0.50),   // 2 — Green
        Color(red: 0.78, green: 0.38, blue: 0.62),   // 3 — Rose
        Color(red: 0.55, green: 0.45, blue: 0.78),   // 4 — Purple
        Color(red: 0.85, green: 0.72, blue: 0.30),   // 5 — Gold
        Color(red: 0.35, green: 0.65, blue: 0.68),   // 6 — Teal
        Color(red: 0.88, green: 0.42, blue: 0.38),   // 7 — Red
        Color(red: 0.50, green: 0.68, blue: 0.40),   // 8 — Olive
        Color(red: 0.65, green: 0.50, blue: 0.70),   // 9 — Lavender
    ]

    // MARK: - Screenshot trigger badges

    static let triggerAppSwitch = Color(red: 0.40, green: 0.56, blue: 0.78)
    static let triggerTitleChange = Color(red: 0.90, green: 0.68, blue: 0.35)
    static let triggerPeriodic = Color(red: 0.35, green: 0.72, blue: 0.55)
    static let triggerManual = Color(red: 0.62, green: 0.48, blue: 0.75)

}
