// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Движок профиля (in the profile's detail): Авто / Xray / Mihomo when the build has both engines, why the engine
// in effect was chosen, what it leaves out (never silently), how each engine supports the profile, and the last
// start that worked. The rules live in Packages/EngineSelection and are tested on Linux.

import DesignSystem
import DomainModels
import EngineSelection
import ProfileLibrary
import SwiftUI

struct EngineChoiceSection: View {
    @EnvironmentObject private var library: ProfileLibraryModel
    let profile: Profile
    let isLocked: Bool

    var body: some View {
        // Read so that a changed preference or a new last known good redraws the section.
        let _ = library.engineChoiceRevision
        let decision = library.engineDecision(for: profile)

        Section {
            if library.availableEngines.count > 1 {
                Picker(selection: preference) {
                    ForEach(choices, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                } label: {
                    Text("Движок").font(.bykBody)
                }
                .disabled(isLocked)
                .bykRow()
            }

            if let engine = decision.engine {
                ValueRow("Будет запущен", value: engine.displayName).bykRow()
            }
            Text(decision.explanation)
                .font(.bykFootnote)
                .foregroundStyle(Color.bykSecondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .bykRow()

            ForEach(Array(decision.losses.enumerated()), id: \.offset) { _, loss in
                MessageRow(.warning, loss.russianText).bykRow()
            }
        } header: {
            SectionHeader("Движок")
        } footer: {
            if isLocked {
                Text("Движок меняется после отключения.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
        }

        if decision.supports.count > 1 || library.lastKnownGood(for: profile.id) != nil {
            Section {
                if decision.supports.count > 1 {
                    ForEach(decision.supports, id: \.engine) { support in
                        ValueRow(support.engine.displayName, value: EngineChoiceSection.supportText(support)).bykRow()
                    }
                }
                if let good = library.lastKnownGood(for: profile.id) {
                    ValueRow(
                        "Последний удачный запуск",
                        value: "\(good.engine.displayName), \(good.recordedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .bykRow()
                }
            } header: {
                SectionHeader("Поддержка профиля")
            } footer: {
                Text("По отчётам компиляторов: что каждый движок может передать из этого профиля. Если новая настройка не запустится, приложение вернёт последнюю удачную.")
                    .font(.bykFootnote)
                    .foregroundStyle(Color.bykSecondaryInk)
            }
        }
    }

    private var choices: [EnginePreference] {
        [.automatic] + library.availableEngines.map(EnginePreference.init(engine:))
    }

    private var preference: Binding<EnginePreference> {
        Binding(
            get: { library.enginePreference(for: profile.id) },
            set: { library.setEnginePreference($0, for: profile.id) }
        )
    }

    static func supportText(_ support: EngineSupport) -> String {
        switch support.level {
        case .complete:
            return "поддерживает всё"
        case .partial:
            return "без " + RussianPlural.phrase(support.losses.count, one: "возможности", few: "возможностей", many: "возможностей")
        case .unsupported:
            return "не запускает"
        }
    }
}
