// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Quiet building blocks around the horn (DESIGN.md §5): grouped lists on slate, section headers in sentence
// case, value rows, the primary button, empty and message states. No decoration beyond what tells the user
// something.

#if canImport(SwiftUI)
import SwiftUI

// MARK: - Lists and forms

public extension View {
    /// A grouped list or form on the slate background, rows on the surface colour. visionOS keeps the system
    /// glass (an opaque slate window would fight the platform), tvOS keeps its focus styling.
    func bykGroupedList() -> some View {
        modifier(GroupedListModifier())
    }

    /// Row background of a grouped list (surface colour) where the platform allows a custom one.
    func bykRow() -> some View {
        modifier(RowModifier())
    }

    /// Base appearance of a screen: text face and neutral tint. Bronze is never the global tint; it is applied
    /// only to the main action and to the connected state.
    func bykScreen() -> some View {
        font(.bykBody)
            .foregroundStyle(Color.bykInk)
            .tint(Color.bykInk)
    }
}

private struct GroupedListModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS) || os(macOS)
        content
            .scrollContentBackground(.hidden)
            .background(Color.bykBackground)
        #else
        content
        #endif
    }
}

private struct RowModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listRowBackground(Color.bykSurface)
        #else
        content
        #endif
    }
}

/// Section header: sentence case (never upper-cased by the system), text face, secondary ink.
public struct SectionHeader: View {
    let title: String

    public init(_ title: String) {
        self.title = title
    }

    public var body: some View {
        Text(title)
            .font(.byk(.footnote, weight: .medium))
            .foregroundStyle(Color.bykSecondaryInk)
            .textCase(nil)
    }
}

/// A label and a value. `technical` values (addresses, ports, identifiers) use the monospaced face.
public struct ValueRow: View {
    let title: String
    let value: String
    let technical: Bool

    public init(_ title: String, value: String, technical: Bool = false) {
        self.title = title
        self.value = value
        self.technical = technical
    }

    public var body: some View {
        LabeledContent {
            Text(value)
                .font(technical ? .bykTechnical(.body) : .bykBody)
                .foregroundStyle(Color.bykSecondaryInk)
                .multilineTextAlignment(.trailing)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        } label: {
            Text(title).font(.bykBody).foregroundStyle(Color.bykInk)
        }
    }
}

/// A selectable row: title, optional secondary line, a check when selected.
public struct SelectableRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool

    public init(_ title: String, subtitle: String? = nil, isSelected: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: CGFloat(Spacing.s)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(isSelected ? .bykBodyEmphasis : .bykBody)
                    .foregroundStyle(Color.bykInk)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }
            Spacer(minLength: CGFloat(Spacing.xs))
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.byk(.body, weight: .semibold))
                    .foregroundStyle(Color.bykInk)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Buttons

/// The one main action of a screen: bronze fill, full width. At most one per screen.
public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.bykBodyEmphasis)
                .foregroundStyle(Color.bykOnAccent)
                .frame(maxWidth: .infinity, minHeight: 50)
                .padding(.horizontal, CGFloat(Spacing.m))
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Radius.button), style: .continuous)
                        .fill(isEnabled ? Color.bykAccentText : Color.bykSecondaryInk.opacity(0.35))
                )
                .opacity(configuration.isPressed ? 0.85 : 1)
                .contentShape(RoundedRectangle(cornerRadius: CGFloat(Radius.button), style: .continuous))
        }
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    static var bykPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

// MARK: - States

/// Nothing to show yet: what is missing, and the one thing that fixes it.
public struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String?
    let actionTitle: String?
    let action: (() -> Void)?

    public init(title: String, message: String, systemImage: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: CGFloat(Spacing.s)) {
            if let systemImage = systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.bykSecondaryInk)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.bykTitle)
                .foregroundStyle(Color.bykInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.bykBody)
                .foregroundStyle(Color.bykSecondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle = actionTitle, let action = action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bykPrimary)
                    .frame(maxWidth: 320)
                    .padding(.top, CGFloat(Spacing.xs))
            }
        }
        .padding(CGFloat(Spacing.l))
        .frame(maxWidth: .infinity)
    }
}

/// Severity of a message line.
public enum MessageKind: Sendable {
    case info
    case warning
    case error

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

/// One message: what happened (and, in the text, what to do). Errors and warnings in the alert colour.
public struct MessageRow: View {
    let kind: MessageKind
    let text: String

    public init(_ kind: MessageKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        Label {
            Text(text)
                .font(.bykFootnote)
                .foregroundStyle(Color.bykInk)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind == .info ? Color.bykSecondaryInk : Color.bykAlert)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A message outside a list (connection screen, sheets): a surface panel with an alert edge for errors.
public struct MessagePanel: View {
    let kind: MessageKind
    let text: String

    public init(_ kind: MessageKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        MessageRow(kind, text)
            .padding(CGFloat(Spacing.s))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CGFloat(Radius.panel), style: .continuous)
                    .fill(Color.bykSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat(Radius.panel), style: .continuous)
                    .strokeBorder(kind == .info ? Color.bykSeparator : Color.bykAlert.opacity(0.6), lineWidth: 1)
            )
    }
}
#endif
