// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Настройки: the level (which screens are shown), the engine of a build with two engines, and about the app
// (version, engines in this build, bundled fonts and their licences).

import DesignSystem
import ProfileLibrary
import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var library: ProfileLibraryModel
    @AppStorage(ExperienceLevel.storageKey) private var storedLevel = ExperienceLevel.basic.rawValue

    private var level: ExperienceLevel { .effective(storedRawValue: storedLevel) }

    var body: some View {
        List {
            Section {
                ForEach(ExperienceLevel.selectable, id: \.self) { candidate in
                    Button {
                        storedLevel = candidate.rawValue
                    } label: {
                        SelectableRow(candidate.title, subtitle: candidate.summary, isSelected: candidate == level)
                    }
                    .bykRow()
                }
            } header: {
                SectionHeader("Уровень")
            } footer: {
                Text("Уровень определяет, какие экраны видны. Скрытые экраны не работают в фоне.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }

            if library.availableEngines.count > 1 {
                Section {
                    Picker(selection: $library.engine) {
                        ForEach(library.availableEngines, id: \.self) { engine in
                            Text(SettingsScreen.engineName(engine)).tag(engine)
                        }
                    } label: {
                        Text("Движок").font(.bykBody)
                    }
                    .disabled(tunnel.phase.action != .connect)
                    .bykRow()
                } header: {
                    SectionHeader("Движок")
                } footer: {
                    Text("Применяется при следующем подключении.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }

            Section {
                ValueRow("Версия", value: SettingsScreen.versionText)
                ValueRow("Движки в сборке", value: library.availableEngines.map(SettingsScreen.engineName).joined(separator: ", "))
                NavigationLink {
                    FontLicencesView()
                } label: {
                    Text("Шрифты и лицензии").font(.bykBody)
                }
            } header: {
                SectionHeader("О приложении")
            }
            .bykRow()
        }
        .bykGroupedList()
        .navigationTitle("Настройки")
    }

    static func engineName(_ engine: TunnelEngine) -> String {
        switch engine {
        case .xray: return "Xray"
        case .mihomo: return "Mihomo"
        }
    }

    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// The bundled fonts and their SIL Open Font License texts (the licence requires shipping them).
struct FontLicencesView: View {
    var body: some View {
        List {
            ForEach(FontFamily.allCases, id: \.self) { family in
                Section {
                    Text(BykFonts.available.contains(family) ? "Загружен" : "Не загрузился — используется системный шрифт.")
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                        .bykRow()
                    if let licence = BykFonts.licence(of: family) {
                        Text(licence)
                            .font(.bykCaption)
                            .foregroundStyle(Color.bykInk)
                            .bykRow()
                    }
                } header: {
                    SectionHeader(family.familyName)
                }
            }
        }
        .bykGroupedList()
        .navigationTitle("Шрифты и лицензии")
    }
}
