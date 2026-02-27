import SwiftUI
import AppKit
import CoreText

/// Adaptive color palette — works in both light and dark mode.
/// Dark: deep grays, clear hierarchy, orange-red accent.
/// Light: clean whites/grays with the same accent and status colors.
enum Theme {

    // MARK: - Custom Fonts

    /// Register bundled Cormorant fonts at runtime.
    /// In the .app bundle this is handled by ATSApplicationFontsPath in Info.plist,
    /// but during development (swift build) there's no Info.plist so we register manually.
    static func registerFonts() {
        let fontNames = ["Cormorant-Bold", "Cormorant-SemiBold", "Cormorant-Medium"]
        for name in fontNames {
            // Try bundle first (for .app), then fall back to source tree (for swift build)
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            } else {
                // Development fallback: find font relative to the binary's location
                let devPath = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent() // Theme/
                    .deletingLastPathComponent() // TaskMinerDashboard/
                    .deletingLastPathComponent() // Sources/
                    .deletingLastPathComponent() // project root
                    .appendingPathComponent("Resources/Fonts/\(name).ttf")
                if FileManager.default.fileExists(atPath: devPath.path) {
                    CTFontManagerRegisterFontsForURL(devPath as CFURL, .process, nil)
                }
            }
        }
    }

    /// Cormorant serif font for header titles — playful, editorial feel.
    /// Falls back to the system serif if Cormorant isn't available.
    static func headerFont(size: CGFloat) -> Font {
        if NSFont(name: "Cormorant-Bold", size: size) != nil {
            return .custom("Cormorant-Bold", size: size)
        }
        return .system(size: size, weight: .bold, design: .serif)
    }

    // MARK: - Adaptive Color Helper

    /// Creates a SwiftUI Color that adapts to the system appearance.
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Backgrounds

    /// Primary background — main content area (light cream / dark #292929).
    static let primaryBackground = adaptive(
        light: NSColor(red: 0.976, green: 0.973, blue: 0.961, alpha: 1),   // #F9F8F5 — warm cream
        dark: NSColor(red: 0.161, green: 0.161, blue: 0.161, alpha: 1)     // RGB(41,41,41) — #292929
    )

    /// Secondary background — toolbars, sidebars, input areas.
    static let secondaryBackground = adaptive(
        light: NSColor(red: 0.969, green: 0.969, blue: 0.953, alpha: 1),   // #F7F7F3 — user-specified
        dark: NSColor(red: 0.161, green: 0.161, blue: 0.161, alpha: 1)     // RGB(41,41,41) — matches primary
    )

    /// Elevated surface — segmented controls, group headers.
    static let surfaceElevated = adaptive(
        light: NSColor(red: 0.92, green: 0.918, blue: 0.902, alpha: 1),    // warm elevated
        dark: NSColor(red: 0.208, green: 0.208, blue: 0.208, alpha: 1)     // RGB(53,53,53)
    )

    /// Card / bubble background (warm white).
    static let cardBackground = adaptive(
        light: NSColor(red: 0.995, green: 0.993, blue: 0.985, alpha: 1),   // warm white
        dark: NSColor(red: 0.231, green: 0.231, blue: 0.231, alpha: 1)     // RGB(59,59,59)
    )

    /// Selected item background (warm white).
    static let selectedSurface = adaptive(
        light: NSColor(red: 0.995, green: 0.993, blue: 0.985, alpha: 1),   // warm white
        dark: NSColor(red: 0.298, green: 0.298, blue: 0.298, alpha: 1)     // RGB(76,76,76)
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
        light: NSColor(red: 0.86, green: 0.855, blue: 0.84, alpha: 1),     // warm separator
        dark: NSColor(red: 0.33, green: 0.33, blue: 0.35, alpha: 1)
    )

    static let cardBorder = adaptive(
        light: NSColor(red: 0.89, green: 0.886, blue: 0.87, alpha: 1),     // warm border
        dark: NSColor(red: 0.28, green: 0.28, blue: 0.30, alpha: 1)
    )

    // MARK: - Timeline

    static let spineLine = adaptive(
        light: NSColor(red: 0.82, green: 0.815, blue: 0.80, alpha: 0.8),   // warm spine
        dark: NSColor(red: 0.33, green: 0.33, blue: 0.35, alpha: 0.6)
    )

    static let gapDot = adaptive(
        light: NSColor(red: 0.74, green: 0.735, blue: 0.72, alpha: 1),     // warm gap dot
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

    // MARK: - Chat overlay

    /// Chat panel background — solid, no translucency.
    static let chatSurface = adaptive(
        light: NSColor(red: 0.995, green: 0.993, blue: 0.988, alpha: 1.0),
        dark: NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1.0)
    )

    /// Chat panel border — solid.
    static let chatBorder = adaptive(
        light: NSColor(red: 0.88, green: 0.876, blue: 0.86, alpha: 1.0),
        dark: NSColor(red: 0.30, green: 0.30, blue: 0.32, alpha: 1.0)
    )

    /// Subtle inner separator in the chat panel.
    static let chatSeparator = adaptive(
        light: NSColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.06),
        dark: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.08)
    )

    /// Assistant message bubble background — solid.
    static let chatAssistantBubble = adaptive(
        light: NSColor(red: 0.955, green: 0.953, blue: 0.945, alpha: 1.0),
        dark: NSColor(red: 0.22, green: 0.22, blue: 0.23, alpha: 1.0)
    )

    // MARK: - Screenshot trigger badges

    static let triggerAppSwitch = Color(red: 0.40, green: 0.56, blue: 0.78)
    static let triggerTitleChange = Color(red: 0.90, green: 0.68, blue: 0.35)
    static let triggerPeriodic = Color(red: 0.35, green: 0.72, blue: 0.55)
    static let triggerManual = Color(red: 0.62, green: 0.48, blue: 0.75)

    // MARK: - Shimmer placeholder color

    /// The shimmer highlight — white in light mode, lighter gray in dark.
    static let shimmerHighlight = adaptive(
        light: NSColor(white: 1.0, alpha: 0.6),
        dark: NSColor(white: 1.0, alpha: 0.15)
    )
}

// MARK: - Activity Halo Dot

/// A round halo indicator matching the Stubble logo style — solid core with
/// a soft radial glow in the given activity color.
struct ActivityHaloDot: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: color, location: 0.0),
                        .init(color: color, location: 0.35),
                        .init(color: color.opacity(0.4), location: 0.55),
                        .init(color: color.opacity(0.08), location: 0.8),
                        .init(color: color.opacity(0.0), location: 1.0),
                    ]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
    }
}

// MARK: - Shimmer Effect

/// Animated shimmer overlay for skeleton/placeholder loading states.
/// A soft gradient sweeps left-to-right across the content in a loop.
struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        let bandWidth = geo.size.width * 0.4
                        let travel = geo.size.width + bandWidth
                        LinearGradient(
                            colors: [.clear, Theme.shimmerHighlight, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        .offset(x: -bandWidth + phase * travel)
                    }
                    .clipped()
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.0
                }
            }
            .onChange(of: active) { _, isActive in
                if isActive {
                    phase = 0
                    withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                } else {
                    phase = 0
                }
            }
    }
}

extension View {
    /// Applies a shimmer animation overlay when `active` is true.
    func shimmer(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
