// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Xcode previews of the components in both appearances. PreviewProvider (not the #Preview macro): the macro
// needs Xcode's macro plugin, which `swift build` on the CI runner does not load.

#if canImport(SwiftUI) && DEBUG
import SwiftUI

struct HornConnectControl_Previews: PreviewProvider {
    static var previews: some View {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            ScrollView {
                VStack(spacing: CGFloat(Spacing.xl)) {
                    HornConnectControl(phase: .disconnected, throughput: nil) {}
                    HornConnectControl(phase: .connecting, throughput: nil) {}
                    HornConnectControl(
                        phase: .connected,
                        throughput: Throughput(downBitsPerSecond: 48_300_000, upBitsPerSecond: 2_100_000)
                    ) {}
                    HornConnectControl(phase: .connected, throughput: nil) {}
                    HornConnectControl(phase: .disconnected, throughput: nil, isEnabled: false,
                                       disabledHint: "Сначала добавьте профиль.") {}
                }
                .padding()
            }
            .background(Color.bykBackground)
            .environment(\.colorScheme, scheme)
            .previewDisplayName(scheme == .dark ? "Тёмная" : "Светлая")
        }
    }
}

struct Components_Previews: PreviewProvider {
    static var previews: some View {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            List {
                Section {
                    SelectableRow("Домашний", subtitle: "3 сервера", isSelected: true).bykRow()
                    SelectableRow("Рабочий", subtitle: "1 сервер", isSelected: false).bykRow()
                    ValueRow("Порт", value: "443", technical: true).bykRow()
                } header: {
                    SectionHeader("Профили")
                }
                Section {
                    MessageRow(.info, "Импортировано 3 сервера.").bykRow()
                    MessageRow(.warning, "Одна строка пропущена: неизвестная схема ссылки.").bykRow()
                    MessageRow(.error, "Подписка не загрузилась: сервер ответил 404. Проверьте адрес.").bykRow()
                } header: {
                    SectionHeader("Сообщения")
                }
            }
            .bykGroupedList()
            .environment(\.colorScheme, scheme)
            .previewDisplayName(scheme == .dark ? "Списки, тёмная" : "Списки, светлая")
        }
        EmptyStateView(
            title: "Профилей нет",
            message: "Добавьте ссылку на сервер или адрес подписки.",
            systemImage: "tray",
            actionTitle: "Добавить профиль"
        ) {}
        .background(Color.bykBackground)
        .previewDisplayName("Пустое состояние")
    }
}
#endif
