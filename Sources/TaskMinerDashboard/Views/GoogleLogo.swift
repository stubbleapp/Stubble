import SwiftUI

/// Draws the Google 'G' logo with official brand colors on a white circular background.
struct GoogleLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)

            Canvas { context, canvasSize in
                let s = min(canvasSize.width, canvasSize.height)
                let center = CGPoint(x: s / 2, y: s / 2)
                let outerR = s / 2
                let innerR = s * 0.27
                let barHeight = outerR - innerR

                let blue   = Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255)
                let red    = Color(red: 234 / 255, green: 67 / 255, blue: 53 / 255)
                let yellow = Color(red: 251 / 255, green: 188 / 255, blue: 5 / 255)
                let green  = Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)

                /// Arc wedge between two angles (SwiftUI: 0° = east, clockwise).
                func wedge(from startDeg: Double, to endDeg: Double) -> Path {
                    Path { p in
                        p.addArc(center: center, radius: outerR,
                                 startAngle: .degrees(startDeg), endAngle: .degrees(endDeg),
                                 clockwise: false)
                        p.addArc(center: center, radius: innerR,
                                 startAngle: .degrees(endDeg), endAngle: .degrees(startDeg),
                                 clockwise: true)
                        p.closeSubpath()
                    }
                }

                // Colored arc segments (clockwise from right)
                context.fill(wedge(from: -1, to: 90), with: .color(blue))      // right  → bottom
                context.fill(wedge(from: 90, to: 180), with: .color(green))     // bottom → left
                context.fill(wedge(from: 180, to: 270), with: .color(yellow))   // left   → top
                context.fill(wedge(from: 270, to: 325), with: .color(red))      // top    → gap

                // Horizontal blue bar from center to right edge
                context.fill(
                    Path(CGRect(x: center.x - 0.5,
                                y: center.y - barHeight / 2,
                                width: outerR + 0.5,
                                height: barHeight)),
                    with: .color(blue)
                )
            }
            .frame(width: size * 0.6, height: size * 0.6)
        }
        .frame(width: size, height: size)
    }
}
