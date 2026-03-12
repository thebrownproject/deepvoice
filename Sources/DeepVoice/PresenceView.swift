import SwiftUI

/// Animated ring presence drawn with SwiftUI Canvas.
/// Three chromatic ring layers (peach/coral/rose) with sinusoidal noise on the radius,
/// responding to app state and audio energy. Inspired by the companion in Her.
struct PresenceView: View {
    var appState: AppState
    var energy: CGFloat  // 0..1 mic or playback RMS

    private let startDate = Date()

    private static let peach = Color(red: 1.0, green: 0.75, blue: 0.58)
    private static let coral = Color(red: 0.96, green: 0.55, blue: 0.48)
    private static let rose  = Color(red: 0.84, green: 0.44, blue: 0.60)

    private struct RingParams {
        var thickness: CGFloat
        var speed: CGFloat
        var radius: CGFloat   // fraction of min(w,h)/2
        var glow: CGFloat

        func lerped(toward target: RingParams, factor: CGFloat) -> RingParams {
            RingParams(
                thickness: thickness + (target.thickness - thickness) * factor,
                speed: speed + (target.speed - speed) * factor,
                radius: radius + (target.radius - radius) * factor,
                glow: glow + (target.glow - glow) * factor
            )
        }
    }

    @State private var current = RingParams(thickness: 1.8, speed: 0.6, radius: 0.60, glow: 0)
    @State private var lastFrameTime: TimeInterval = 0

    private func targetParams(energy e: CGFloat) -> RingParams {
        switch appState {
        case .idle, .error:
            return RingParams(thickness: 1.8, speed: 0.6, radius: 0.60, glow: 0)
        case .listening:
            return RingParams(
                thickness: 2.4 + e * 2.0,
                speed: 0.9 + e * 0.4,
                radius: 0.62 + e * 0.05,
                glow: 0
            )
        case .thinking:
            return RingParams(thickness: 2.0, speed: 1.6, radius: 0.58, glow: 0)
        case .speaking:
            return RingParams(
                thickness: 2.8 + e * 2.5,
                speed: 1.0,
                radius: 0.66 + e * 0.04,
                glow: 0.15 + e * 0.15
            )
        }
    }

    // Per-layer speed multipliers so chromatic layers drift apart organically
    private static let layers: [(color: Color, seed: Double, thicknessFactor: CGFloat, speedMul: Double)] = [
        (peach, 42.0, 1.0,  0.95),
        (coral, 18.0, 0.85, 1.0),
        (rose,  71.0, 0.95, 1.05),
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let target = targetParams(energy: energy)

            // Exponential smoothing: ~300ms transition at 60fps
            // dt-independent factor: 1 - exp(-dt * rate), rate ~8 gives ~300ms settle
            let dt = max(elapsed - lastFrameTime, 0.001)
            let factor = CGFloat(1.0 - exp(-dt * 8.0))

            Canvas { ctx, size in
                let dim = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)

                // Idle breathing: subtle sine modulation on radius (~4s period)
                let breath = (appState == .idle || appState == .error)
                    ? sin(elapsed * 2.0 * .pi / 4.0) * 0.015 : 0.0
                let baseRadius = dim / 2 * (current.radius + CGFloat(breath))
                let t = elapsed * Double(current.speed)

                // Glow: inverse-distance falloff for softer, wider spread
                if current.glow > 0.01 {
                    let glowColor = Color(red: 0.98, green: 0.65, blue: 0.53)
                    let glowSpread = dim * 0.12
                    let gradient = GraphicsContext.Shading.radialGradient(
                        Gradient(stops: [
                            .init(color: glowColor.opacity(Double(current.glow) * 0.6), location: 0.0),
                            .init(color: glowColor.opacity(Double(current.glow) * 0.25), location: 0.5),
                            .init(color: glowColor.opacity(0), location: 1.0),
                        ]),
                        center: center,
                        startRadius: baseRadius - dim * 0.02,
                        endRadius: baseRadius + glowSpread
                    )
                    let r = baseRadius + glowSpread
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                        with: gradient
                    )
                }

                // Outer echo ring: faint, thinner, drifts at different speed
                let echoRadius = baseRadius * 1.15
                let echoTime = elapsed * Double(current.speed) * 0.7
                for layer in Self.layers {
                    let path = Self.ringPath(
                        center: center,
                        baseRadius: echoRadius,
                        seed: layer.seed + 100,
                        time: echoTime * layer.speedMul,
                        energy: energy * 0.4,
                        dim: dim
                    )
                    ctx.stroke(
                        path,
                        with: .color(layer.color.opacity(0.25)),
                        style: StrokeStyle(
                            lineWidth: current.thickness * layer.thicknessFactor * 0.5,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                // Primary chromatic ring layers
                for layer in Self.layers {
                    let layerTime = t * layer.speedMul
                    let path = Self.ringPath(
                        center: center,
                        baseRadius: baseRadius,
                        seed: layer.seed,
                        time: layerTime,
                        energy: energy,
                        dim: dim
                    )
                    ctx.stroke(
                        path,
                        with: .color(layer.color.opacity(0.85)),
                        style: StrokeStyle(
                            lineWidth: current.thickness * layer.thicknessFactor,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .onChange(of: elapsed) {
                current = current.lerped(toward: target, factor: factor)
                lastFrameTime = elapsed
            }
        }
    }

    /// Closed path for one ring layer with 3-octave sinusoidal noise on the radius.
    private static func ringPath(
        center: CGPoint,
        baseRadius: CGFloat,
        seed: Double,
        time: Double,
        energy: CGFloat,
        dim: CGFloat
    ) -> Path {
        let steps = 180
        let amp = (0.004 + Double(energy) * 0.012) * Double(dim)

        var path = Path()
        for i in 0...steps {
            let fraction = Double(i) / Double(steps)
            let angle = fraction * 2.0 * .pi

            let s1 = sin(angle * 5.0 - time * 1.2 + seed) * amp
            let s2 = sin(angle * 3.0 + time * 0.9 + seed * 0.7) * (amp * 0.8)
            let s3 = sin(angle * 7.0 - time * 0.6 + seed * 1.3) * (amp * 0.4)
            let noise = s1 + s2 + s3

            let r = Double(baseRadius) + noise
            let x = Double(center.x) + cos(angle) * r
            let y = Double(center.y) + sin(angle) * r

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

#Preview("Idle") {
    PresenceView(appState: .idle, energy: 0)
        .frame(width: 300, height: 300)
        .background(.black)
}

#Preview("Listening") {
    PresenceView(appState: .listening, energy: 0.4)
        .frame(width: 300, height: 300)
        .background(.black)
}

#Preview("Speaking") {
    PresenceView(appState: .speaking, energy: 0.6)
        .frame(width: 300, height: 300)
        .background(.black)
}
