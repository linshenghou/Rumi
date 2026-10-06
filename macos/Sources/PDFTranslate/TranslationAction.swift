import SwiftUI

/// A glass toolbar action whose translation glyph stays still over a changing color field.
struct TranslationAction: View {
    let title: String
    var compact: Bool = false
    var isProcessing: Bool = false
    var progress: Double = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 7 : 8) {
                TranslationOrb(size: compact ? 26 : 30, isProcessing: isProcessing, progress: progress)
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, compact ? 5 : 6)
            .padding(.trailing, compact ? 13 : 16)
            .frame(height: compact ? 32 : 38)
            .contentShape(Capsule())
        }
        .buttonStyle(TranslationGlassButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isProcessing ? L10n.format("Translating, %d%%", Int(safeProgress)) : "")
    }

    private var safeProgress: Double {
        progress.isFinite ? min(100, max(0, progress)) : 0
    }
}

private struct TranslationOrb: View {
    let size: CGFloat
    let isProcessing: Bool
    let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            if isProcessing && !reduceMotion {
                // Translation activity is independent of keyboard focus and scene phase.
                // Keep the light moving in a visible background window, too.
                // Removing this view stops the periodic schedule.
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    let turn = time.truncatingRemainder(dividingBy: 12) / 12
                    // A smooth 2.8-second breath changes light only. The glyph,
                    // label and control bounds never move or scale with it.
                    let phase = time.truncatingRemainder(dividingBy: 2.8) / 2.8
                    let breath = (1 - cos(phase * 2 * .pi)) / 2
                    colorField(turn: turn, breath: breath)
                }
            } else {
                colorField(turn: 0, breath: 0)
            }
            Image(systemName: translationSymbol)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: size * 0.66, height: size * 0.62)
                .shadow(color: .black.opacity(0.38), radius: 0.8, y: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func colorField(turn: Double, breath: Double) -> some View {
        let completion = progress.isFinite ? min(100, max(0, progress)) / 100 : 0
        let animating = isProcessing && !reduceMotion
        let angle = turn * 360 + (animating ? completion * 100 : 0)
        let showsHalo = !reduceTransparency && contrast != .increased
        // Modulate the visible face, rather than hiding the breath behind it.
        // Accessibility appearances use a shallower luminance range and no halo.
        let illumination = animating ? breath : 0
        let faceShade = animating
            ? (showsHalo ? 0.38 : 0.20) * (1 - breath) + 0.04
            : (contrast == .increased ? 0.30 : 0.10)
        let colors = AngularGradient(stops: [
            .init(color: Color(red: 0.96, green: 0.29, blue: 0.32), location: 0),
            .init(color: Color(red: 0.28, green: 0.42, blue: 1.00), location: 0.23),
            .init(color: Color(red: 0.17, green: 0.38, blue: 0.98), location: 0.42),
            .init(color: Color(red: 0.18, green: 0.73, blue: 0.43), location: 0.62),
            .init(color: Color(red: 0.96, green: 0.78, blue: 0.22), location: 0.77),
            .init(color: Color(red: 1.00, green: 0.47, blue: 0.20), location: 0.88),
            .init(color: Color(red: 0.96, green: 0.29, blue: 0.32), location: 1)
        ], center: .center, startAngle: .degrees(-90 + angle), endAngle: .degrees(270 + angle))

        return ZStack {
            if showsHalo {
                Circle().fill(colors)
                    .scaleEffect(animating ? 1.0 + breath * 0.16 : 1.0)
                    .blur(radius: size * 0.13)
                    .opacity(animating
                        ? (colorScheme == .dark ? 0.10 + breath * 0.68 : 0.06 + breath * 0.45)
                        : (colorScheme == .dark ? 0.38 : 0.20))
            }
            Circle().fill(colors)
                .blur(radius: size * 0.08)
                .scaleEffect(1.12)
                .clipShape(Circle())
                .overlay {
                    Circle().fill(.black.opacity(faceShade))
                }
                .overlay {
                    Circle().fill(RadialGradient(colors: [.white.opacity(0.34 + illumination * 0.12), .clear],
                        center: .topLeading, startRadius: 0, endRadius: size * 0.9))
                }
                .overlay {
                    Circle().strokeBorder(.white.opacity(contrast == .increased ? 0.65 : 0.24 + illumination * 0.16), lineWidth: 0.5)
                }
        }
    }

    private var translationSymbol: String {
        if #available(macOS 14.4, *) { return "translate" }
        return "character.bubble"
    }
}

private struct TranslationGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { surface }
            .overlay {
                if contrast == .increased {
                    Capsule().strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.45)
            .contentShape(Capsule())
            .onHover { hovered = $0 && isEnabled }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }

    @ViewBuilder
    private var surface: some View {
        if reduceTransparency || contrast == .increased {
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.tint(Color.blue.opacity(hovered ? 0.12 : 0.06))
                    .interactive(isEnabled && !reduceMotion), in: .capsule)
        } else {
            Capsule().fill(.regularMaterial)
                .overlay { Capsule().fill(Color.blue.opacity(hovered ? 0.08 : 0.035)) }
        }
    }
}
