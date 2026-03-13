import SwiftUI

/// Animated ring presence drawn with SwiftUI Canvas.
/// The important detail is that the animation clock lives in SwiftUI state,
/// so parent-driven view reconstruction does not reset elapsed time.
struct PresenceView: View {
    var appState: AppState
    var captureEnergy: CGFloat
    var playbackEnergy: CGFloat

    private struct RingParams {
        var thickness: CGFloat
        var speed: CGFloat
        var radius: CGFloat
        var glow: CGFloat
        var opacity: CGFloat
        var chromaticSpread: CGFloat
        var noise: CGFloat

        func lerped(toward target: RingParams, factor: CGFloat) -> RingParams {
            RingParams(
                thickness: thickness + (target.thickness - thickness) * factor,
                speed: speed + (target.speed - speed) * factor,
                radius: radius + (target.radius - radius) * factor,
                glow: glow + (target.glow - glow) * factor,
                opacity: opacity + (target.opacity - opacity) * factor,
                chromaticSpread: chromaticSpread + (target.chromaticSpread - chromaticSpread) * factor,
                noise: noise + (target.noise - noise) * factor
            )
        }
    }

    private static let red = Color(red: 1.0, green: 0.22, blue: 0.36)
    private static let green = Color(red: 0.48, green: 1.0, blue: 0.42)
    private static let blue = Color(red: 0.26, green: 0.48, blue: 1.0)
    private static let coreTint = Color.white
    private static let haloTint = Color(red: 0.92, green: 0.96, blue: 1.0)

    private static let layers: [(color: Color, seed: Double, thicknessFactor: CGFloat, speedMul: Double, alpha: Double)] = [
        (red, 42.0, 1.0, 0.985, 0.9),
        (green, 18.0, 0.96, 1.0, 0.9),
        (blue, 71.0, 0.92, 1.015, 0.9),
    ]

    @State private var startDate = Date()
    @State private var current = RingParams(
        thickness: 1.8,
        speed: 0.6,
        radius: 0.60,
        glow: 0,
        opacity: 0.85,
        chromaticSpread: 1.0,
        noise: 0.007
    )
    @State private var lastFrameTime: TimeInterval = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = max(context.date.timeIntervalSince(startDate), 0)

            Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { ctx, size in
                drawRing(in: &ctx, size: size, elapsed: elapsed)
            }
            .onAppear {
                if lastFrameTime == 0 {
                    lastFrameTime = elapsed
                }
            }
            .onChange(of: context.date, initial: true) { _, newDate in
                let elapsed = max(newDate.timeIntervalSince(startDate), 0)
                advanceAnimation(to: elapsed)
            }
        }
    }

    private func targetParams() -> RingParams {
        switch appState {
        case .idle, .error:
            return RingParams(
                thickness: 1.9,
                speed: 0.5,
                radius: 0.53,
                glow: 0.035,
                opacity: 0.84,
                chromaticSpread: 1.0,
                noise: 0.007
            )

        case .listening:
            let energy = captureEnergy
            return RingParams(
                thickness: 2.05 + energy * 0.45,
                speed: 0.86 + energy * 0.25,
                radius: 0.515 - energy * 0.012,
                glow: 0.05 + energy * 0.04,
                opacity: 0.9,
                chromaticSpread: 0.74 - energy * 0.12,
                noise: 0.0085 + energy * 0.003
            )

        case .thinking:
            return RingParams(
                thickness: 2.0,
                speed: 1.34,
                radius: 0.525,
                glow: 0.045,
                opacity: 0.88,
                chromaticSpread: 0.88,
                noise: 0.011
            )

        case .speaking:
            let energy = playbackEnergy
            return RingParams(
                thickness: 2.2 + energy * 0.85,
                speed: 1.0 + energy * 0.34,
                radius: 0.545 + energy * 0.02,
                glow: 0.08 + energy * 0.14,
                opacity: 0.96,
                chromaticSpread: 1.14 + energy * 0.25,
                noise: 0.0105 + energy * 0.007
            )
        }
    }

    private func advanceAnimation(to elapsed: TimeInterval) {
        let target = targetParams()
        let dt = max(elapsed - lastFrameTime, 1.0 / 120.0)
        let factor = CGFloat(1.0 - exp(-dt * 8.0))

        current = current.lerped(toward: target, factor: factor)
        lastFrameTime = elapsed
    }

    private func drawRing(in ctx: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let dim = min(size.width, size.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        let phase = elapsed * Double(current.speed)
        let idleBreath = (appState == .idle || appState == .error)
            ? sin(elapsed * 2.0 * .pi / 4.0) * 0.012
            : 0.0
        let pulsePhase = 0.5 + 0.5 * sin(phase * 2.8)
        let statePulse: Double = switch appState {
        case .idle, .error:
            0.0
        case .listening:
            -(0.008 + pulsePhase * 0.012) * (0.75 + Double(captureEnergy) * 0.25)
        case .thinking:
            sin(phase * 1.7) * 0.003
        case .speaking:
            (0.012 + pulsePhase * (0.018 + Double(playbackEnergy) * 0.02)) * (0.8 + Double(playbackEnergy) * 0.2)
        }
        let baseRadius = dim / 2 * (current.radius + CGFloat(idleBreath + statePulse))

        let activeEnergy: CGFloat = switch appState {
        case .idle, .error: 0.018
        case .listening: 0.04 + captureEnergy * 0.12
        case .thinking: 0.055
        case .speaking: 0.06 + playbackEnergy * 0.25
        }

        let innerPresence = switch appState {
        case .idle, .error: 0.16
        case .listening: 0.19
        case .thinking: 0.17
        case .speaking: 0.22 + Double(current.glow) * 0.08
        }

        let coreGradient = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: Self.coreTint.opacity(innerPresence), location: 0.0),
                .init(color: Self.coreTint.opacity(innerPresence * 0.82), location: 0.45),
                .init(color: Self.coreTint.opacity(innerPresence * 0.45), location: 0.8),
                .init(color: Self.coreTint.opacity(0), location: 1.0),
            ]),
            center: center,
            startRadius: 0,
            endRadius: baseRadius * 0.9
        )

        let coreRadius = baseRadius * 0.88
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: coreGradient
        )

        let highlightCenter = CGPoint(
            x: center.x - baseRadius * 0.22,
            y: center.y - baseRadius * 0.26
        )
        let highlight = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.16), location: 0.0),
                .init(color: .white.opacity(0.08), location: 0.35),
                .init(color: .white.opacity(0), location: 1.0),
            ]),
            center: highlightCenter,
            startRadius: 0,
            endRadius: baseRadius * 0.42
        )
        ctx.fill(
            Path(ellipseIn: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )),
            with: highlight
        )

        if current.glow > 0.01 {
            let glowSpread = dim * 0.06
            let gradient = GraphicsContext.Shading.radialGradient(
                Gradient(stops: [
                    .init(color: Self.haloTint.opacity(Double(current.glow) * 0.16), location: 0.0),
                    .init(color: Self.haloTint.opacity(Double(current.glow) * 0.07), location: 0.55),
                    .init(color: Self.haloTint.opacity(0), location: 1.0),
                ]),
                center: center,
                startRadius: baseRadius - dim * 0.01,
                endRadius: baseRadius + glowSpread
            )

            let radius = baseRadius + glowSpread
            ctx.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )),
                with: gradient
            )
        }

        ctx.blendMode = .plusLighter

        let spread = Double(current.chromaticSpread)
        let haloRadius = baseRadius * (1.008 + current.glow * 0.03)
        let haloOpacity: Double = switch appState {
        case .idle, .error: 0.045
        case .listening: 0.05
        case .thinking: 0.04
        case .speaking: 0.07 + Double(current.glow) * 0.12
        }

        if haloOpacity > 0.01 {
            let haloPath = Self.ringPath(
                center: center,
                baseRadius: haloRadius,
                seed: 128,
                time: phase * 0.92,
                energy: activeEnergy * 0.35,
                noise: current.noise * 0.6,
                dim: dim
            )

            ctx.stroke(
                haloPath,
                with: .color(Self.haloTint.opacity(haloOpacity * 0.5)),
                style: StrokeStyle(
                    lineWidth: current.thickness * 1.35,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            ctx.stroke(
                haloPath,
                with: .color(Self.haloTint.opacity(haloOpacity * 0.18)),
                style: StrokeStyle(
                    lineWidth: current.thickness * 2.4,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        let accentRadius: CGFloat?
        let accentOpacity: Double
        let accentWidth: CGFloat
        let accentSeed: Double
        let accentTime: Double
        let accentEnergy: CGFloat

        switch appState {
        case .listening:
            accentRadius = baseRadius * CGFloat(0.94 - pulsePhase * 0.05)
            accentOpacity = 0.18 + Double(captureEnergy) * 0.08
            accentWidth = current.thickness * 0.58
            accentSeed = 220
            accentTime = phase * 1.18
            accentEnergy = activeEnergy * 0.75
        case .speaking:
            accentRadius = baseRadius * CGFloat(1.03 + pulsePhase * (0.035 + Double(playbackEnergy) * 0.03))
            accentOpacity = 0.16 + Double(current.glow) * 0.18
            accentWidth = current.thickness * 0.62
            accentSeed = 240
            accentTime = phase * 1.05
            accentEnergy = activeEnergy * 0.85
        default:
            accentRadius = nil
            accentOpacity = 0
            accentWidth = 0
            accentSeed = 0
            accentTime = 0
            accentEnergy = 0
        }

        if let accentRadius {
            let accentPath = Self.ringPath(
                center: center,
                baseRadius: accentRadius,
                seed: accentSeed,
                time: accentTime,
                energy: accentEnergy,
                noise: current.noise * 0.72,
                dim: dim
            )

            ctx.stroke(
                accentPath,
                with: .color(.white.opacity(accentOpacity)),
                style: StrokeStyle(
                    lineWidth: accentWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        for layer in Self.layers {
            let layerSpeedMul = 1.0 + (layer.speedMul - 1.0) * spread
            let path = Self.ringPath(
                center: center,
                baseRadius: baseRadius,
                seed: layer.seed,
                time: phase * layerSpeedMul,
                energy: activeEnergy,
                noise: current.noise,
                dim: dim
            )
            ctx.stroke(
                path,
                with: .color(layer.color.opacity(Double(current.opacity) * layer.alpha)),
                style: StrokeStyle(
                    lineWidth: current.thickness * layer.thicknessFactor,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }

    private static func ringPath(
        center: CGPoint,
        baseRadius: CGFloat,
        seed: Double,
        time: Double,
        energy: CGFloat,
        noise: CGFloat,
        dim: CGFloat
    ) -> Path {
        let steps = 180
        let amplitude = Double(noise + energy * 0.01) * Double(dim)

        var path = Path()
        for i in 0...steps {
            let fraction = Double(i) / Double(steps)
            let angle = fraction * 2.0 * .pi

            let s1 = sin(angle * 5.0 - time * 1.2 + seed) * amplitude
            let s2 = sin(angle * 3.0 + time * 0.9 + seed * 0.7) * (amplitude * 0.8)
            let s3 = sin(angle * 7.0 - time * 0.6 + seed * 1.3) * (amplitude * 0.4)
            let radius = Double(baseRadius) + s1 + s2 + s3

            let x = Double(center.x) + cos(angle) * radius
            let y = Double(center.y) + sin(angle) * radius

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
    PresenceView(appState: .idle, captureEnergy: 0, playbackEnergy: 0)
        .frame(width: 300, height: 300)
        .background(.black)
}

#Preview("Listening") {
    PresenceView(appState: .listening, captureEnergy: 0.4, playbackEnergy: 0)
        .frame(width: 300, height: 300)
        .background(.black)
}

#Preview("Speaking") {
    PresenceView(appState: .speaking, captureEnergy: 0, playbackEnergy: 0.6)
        .frame(width: 300, height: 300)
        .background(.black)
}
