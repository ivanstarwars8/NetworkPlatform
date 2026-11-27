// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// The signature element (DESIGN.md §4): the horn arc is the connect button. It fills with bronze from the
// bases up as the tunnel comes up, shows the state word in the display face beneath, and the live speed
// while connected. One orchestrated transition per state change (fill + word); with Reduce Motion the fill
// changes without a spring and nothing breathes.
//
// The control only displays what it is given: the phase (from NEVPNStatus) and a measured throughput, or nil.

#if canImport(SwiftUI)
import SwiftUI

/// The two horns as one shape, fitted into the largest centred square of the rect.
public struct HornShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ p: HornPoint) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(p.x) * side, y: origin.y + CGFloat(p.y) * side)
        }
        var path = Path()
        for outline in HornGeometry.outlines {
            path.move(to: point(outline.start))
            path.addCurve(to: point(outline.outer.end), control1: point(outline.outer.control1), control2: point(outline.outer.control2))
            path.addCurve(to: point(outline.inner.end), control1: point(outline.inner.control1), control2: point(outline.inner.control2))
            path.closeSubpath()
        }
        return path
    }
}

/// The horn drawing alone: muted track plus the bronze fill rising from the bases.
public struct HornGlyph: View {
    let fill: Double
    let waiting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(fill: Double, waiting: Bool = false) {
        self.fill = fill
        self.waiting = waiting
    }

    public var body: some View {
        ZStack {
            HornShape().fill(Color.bykSecondaryInk.opacity(0.22))
            bronze
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var bronze: some View {
        let layer = HornShape()
            .fill(Color.bykAccent)
            .mask(alignment: .bottom) {
                GeometryReader { proxy in
                    Rectangle()
                        .frame(height: proxy.size.height * CGFloat(HornGeometry.maskFraction(fill: fill)))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        if waiting && !reduceMotion {
            // Breathes only while the outcome is unknown; stops (and costs nothing) otherwise.
            layer.phaseAnimator([1.0, 0.45]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        } else {
            layer
        }
    }
}

public struct HornConnectControl: View {
    public enum Scale: Sendable {
        /// Phones, tablets, Mac and vision windows.
        case regular
        /// tvOS: read from across a room.
        case large
    }

    let phase: ConnectionPhase
    let throughput: Throughput?
    let isEnabled: Bool
    let disabledHint: String?
    let scale: Scale
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - phase: what the tunnel is doing.
    ///   - throughput: measured speed, shown only while connected; `nil` until two samples exist.
    ///   - isEnabled: `false` when the action cannot run (for example, no profile to connect with).
    ///   - disabledHint: what the user has to do when `isEnabled` is false.
    public init(
        phase: ConnectionPhase,
        throughput: Throughput?,
        isEnabled: Bool = true,
        disabledHint: String? = nil,
        scale: Scale = .regular,
        action: @escaping () -> Void
    ) {
        self.phase = phase
        self.throughput = throughput
        self.isEnabled = isEnabled
        self.disabledHint = disabledHint
        self.scale = scale
        self.action = action
    }

    private var canPress: Bool { isEnabled && phase.action != .none }

    private var hornSide: CGFloat { scale == .large ? 340 : 200 }

    public var body: some View {
        VStack(spacing: CGFloat(Spacing.m)) {
            Button(action: action) {
                HornGlyph(fill: phase.hornFill, waiting: phase.isWaiting)
                    .frame(width: hornSide, height: hornSide)
                    .padding(CGFloat(Spacing.s))
                    .contentShape(Rectangle())
            }
            .buttonStyle(HornButtonStyle())
            .disabled(!canPress)
            .accessibilityLabel(Text(phase.actionTitle ?? phase.stateWord))
            .accessibilityValue(Text(phase.stateWord))
            .accessibilityHint(Text(isEnabled ? "" : (disabledHint ?? "")))

            Text(phase.stateWord)
                .font(.byk(scale == .large ? .hero : .display, family: .display, weight: .semibold))
                .foregroundStyle(phase == .connected ? Color.bykAccentText : Color.bykInk)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .accessibilityHidden(true)

            if let line = secondaryLine {
                Text(line)
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if phase.showsThroughput {
                ThroughputLine(throughput: throughput, scale: scale)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.86), value: phase)
    }

    private var secondaryLine: String? {
        if !isEnabled, phase.action == .connect, let hint = disabledHint { return hint }
        return phase.hint
    }
}

/// Down and up speed. Numbers only when measured; until then it says so.
public struct ThroughputLine: View {
    let throughput: Throughput?
    let scale: HornConnectControl.Scale

    public init(throughput: Throughput?, scale: HornConnectControl.Scale = .regular) {
        self.throughput = throughput
        self.scale = scale
    }

    public var body: some View {
        Group {
            if let throughput = throughput {
                HStack(alignment: .firstTextBaseline, spacing: CGFloat(Spacing.l)) {
                    figure(symbol: "arrow.down", label: "Загрузка", bitsPerSecond: throughput.downBitsPerSecond)
                    figure(symbol: "arrow.up", label: "Отдача", bitsPerSecond: throughput.upBitsPerSecond)
                }
            } else {
                Text("Измеряю скорость")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
        }
        .frame(minHeight: scale == .large ? 64 : 36)
    }

    private func figure(symbol: String, label: String, bitsPerSecond: Double) -> some View {
        let parts = UnitFormat.speed(bitsPerSecond: bitsPerSecond)
        return HStack(alignment: .firstTextBaseline, spacing: CGFloat(Spacing.xxs)) {
            Image(systemName: symbol)
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
            Text(parts.value)
                .font(.byk(scale == .large ? .display : .title, family: .display, weight: .medium))
                .foregroundStyle(Color.bykInk)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(parts.unit)
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label): \(parts.value) \(parts.unit)"))
    }
}

/// Press feedback for the horn: a slight press-in; on tvOS the focused horn grows.
struct HornButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HornButtonBody(configuration: configuration)
    }

    private struct HornButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .opacity(isEnabled ? 1 : 0.55)
                .scaleEffect(scale)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isFocused)
        }

        private var scale: CGFloat {
            if reduceMotion { return 1 }
            if configuration.isPressed { return 0.96 }
            #if os(tvOS)
            if isFocused { return 1.06 }
            #endif
            return 1
        }
    }
}
#endif
