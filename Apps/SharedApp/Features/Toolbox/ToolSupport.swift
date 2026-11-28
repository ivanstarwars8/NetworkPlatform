// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46083058268 (workflow apple.yml)
//
// Shared pieces of the toolbox screens: running a blocking probe off the main actor, a cancellation flag the
// probe polls, formatting of measured values, and the quiet "method and limits" footer every tool carries.
// Probes are started by the user only; nothing here repeats on its own.

import DesignSystem
import Foundation
import NetworkToolbox
import SwiftUI

enum Blocking {
    /// Runs a blocking probe on a global queue (never on the Swift cooperative pool, which must not block).
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// Set from the main actor (Stop button, screen closed), read by the probe between attempts.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum Measure {
    /// "12,3 мс" below 100 ms, "123 мс" above, "1,25 с" from a second.
    static func duration(_ seconds: Double) -> String {
        let milliseconds = seconds * 1000
        if milliseconds >= 1000 {
            return String(format: "%.2f с", seconds).replacingOccurrences(of: ".", with: ",")
        }
        if milliseconds >= 100 {
            return "\(Int(milliseconds.rounded())) мс"
        }
        return String(format: "%.1f мс", milliseconds).replacingOccurrences(of: ".", with: ",")
    }

    static func optionalDuration(_ seconds: Double?) -> String {
        seconds.map(duration) ?? "не измерялось"
    }

    static func speed(_ bitsPerSecond: Double) -> String {
        let parts = UnitFormat.speed(bitsPerSecond: bitsPerSecond)
        return "\(parts.value) \(parts.unit)"
    }

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// The footer under a tool: how it measures and what the platform does not allow. Plain secondary text.
struct MethodNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.bykFootnote)
            .foregroundStyle(Color.bykSecondaryInk)
    }
}

/// A text field for technical input (hosts, ports, URLs): no autocorrection or capitalisation, monospaced.
struct TechnicalField: View {
    let title: String
    @Binding var text: String
    var keyboardNumeric = false

    var body: some View {
        TextField(title, text: $text)
            .font(.bykTechnical(.body))
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            .keyboardType(keyboardNumeric ? .numberPad : .URL)
            #endif
    }
}

/// The note shown on every tool while the tunnel is up: the app's own probes go through the tunnel.
struct TunnelPathNote: View {
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        if tunnel.status == .connected {
            MessageRow(.info, "Туннель подключён: проверка идёт через него, как трафик других приложений.")
        }
    }
}

/// A result headline: a short verdict and one line of explanation. Good results in the "good" colour,
/// problems in the alert colour, everything else in ink. Never bronze (bronze means the tunnel is working).
struct VerdictRow: View {
    enum Tone {
        case good, problem, neutral
    }

    let title: String
    let detail: String?
    let tone: Tone

    init(_ title: String, detail: String? = nil, tone: Tone) {
        self.title = title
        self.detail = detail
        self.tone = tone
    }

    private var color: Color {
        switch tone {
        case .good: return .bykGood
        case .problem: return .bykAlert
        case .neutral: return .bykInk
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat(Spacing.xxs)) {
            Text(title)
                .font(.bykTitle)
                .foregroundStyle(color)
            if let detail = detail {
                Text(detail)
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, CGFloat(Spacing.xxs))
        .accessibilityElement(children: .combine)
    }
}

/// The run / stop button of a tool: the screen's main action.
struct RunButton: View {
    let title: String
    let running: Bool
    let enabled: Bool
    let action: () -> Void
    var stop: (() -> Void)?

    var body: some View {
        if running, let stop = stop {
            Button("Остановить", action: stop)
                .buttonStyle(.bykPrimary)
        } else {
            Button(action: action) {
                if running {
                    HStack(spacing: CGFloat(Spacing.xs)) {
                        ProgressView()
                        Text("Проверяю")
                    }
                } else {
                    Text(title)
                }
            }
            .buttonStyle(.bykPrimary)
            .disabled(!enabled || running)
        }
    }
}
