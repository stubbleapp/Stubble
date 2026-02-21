import SwiftUI

struct TimelineBarView: View {
    let groups: [ActivityGroup]

    private var appColors: [String: Color] {
        let palette = Theme.barPalette
        var map: [String: Color] = [:]
        var idx = 0
        for group in groups {
            let key = group.bundleId ?? group.appName
            if map[key] == nil {
                map[key] = palette[idx % palette.count]
                idx += 1
            }
        }
        return map
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(groups) { group in
                    let fraction = group.totalDuration / totalDuration
                    RoundedRectangle(cornerRadius: 3)
                        .fill(appColors[group.bundleId ?? group.appName] ?? Theme.textMuted)
                        .frame(width: max(2, geo.size.width * fraction))
                        .help("\(group.appName): \(formatDuration(group.totalDuration))")
                }
            }
        }
        .background(Theme.separator.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var totalDuration: TimeInterval {
        max(1, groups.map(\.totalDuration).reduce(0, +))
    }
}
