// compiled on macOS CI, never run: Xcode 16.4, iOS/iPadOS, macOS, tvOS, visionOS, flavours XrayOnly,
// MihomoOnly and Dual, unsigned (CODE_SIGNING_ALLOWED=NO), GitHub Actions run 46073714202 (workflow apple.yml)
//
// Navigation per platform (Documentation/Design/DESIGN.md §6):
//   iPhone (compact width)        tab bar: Подключение / Профили / Инструменты (Профи) / Настройки
//   iPad, Mac, Apple Vision Pro   NavigationSplitView: sidebar of the same areas
//   Apple TV                      one dashboard (Shell/TVDashboard.swift)
// What is shown comes from Features/AppDestination.swift and the chosen level; hidden screens are absent,
// never disabled.

import DesignSystem
import SwiftUI

struct RootView: View {
    static let windowID = "main"

    @AppStorage(ExperienceLevel.storageKey) private var storedLevel = ExperienceLevel.basic.rawValue
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var level: ExperienceLevel { .effective(storedRawValue: storedLevel) }

    var body: some View {
        #if os(tvOS)
        TVDashboard()
        #elseif os(iOS)
        if sizeClass == .compact {
            TabShell(level: level)
        } else {
            SidebarShell(level: level)
        }
        #else
        SidebarShell(level: level)
        #endif
    }
}

/// iPhone: one tab per visible area, each with its own navigation stack.
struct TabShell: View {
    let level: ExperienceLevel
    @State private var selection: AppArea = .connection

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppArea.visible(at: level), id: \.self) { area in
                NavigationStack {
                    AreaRootView(area: area, level: level)
                }
                .tabItem { Label(area.title, systemImage: area.systemImage) }
                .tag(area)
            }
        }
        .onChange(of: level) {
            // The level was lowered from Settings: stay in Settings rather than land on a hidden area.
            if !AppArea.visible(at: level).contains(selection) {
                selection = .settings
            }
        }
    }
}

/// The first screen of an area: the destination itself, or the list of tools.
struct AreaRootView: View {
    let area: AppArea
    let level: ExperienceLevel

    var body: some View {
        let destinations = area.destinations(at: level)
        if area == .tools {
            ToolsList(destinations: destinations)
        } else if let first = destinations.first {
            first.screen
        }
    }
}

/// Инструменты: the Профи screens, one row each.
struct ToolsList: View {
    let destinations: [AppDestination]

    var body: some View {
        List {
            Section {
                ForEach(destinations) { destination in
                    NavigationLink {
                        destination.screen
                    } label: {
                        DestinationLabel(destination: destination, showsSummary: true)
                    }
                    .bykRow()
                }
            }
        }
        .bykGroupedList()
        .navigationTitle(AppArea.tools.title)
    }
}

struct DestinationLabel: View {
    let destination: AppDestination
    var showsSummary = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title).font(.bykBody)
                if showsSummary, let summary = destination.summary {
                    Text(summary)
                        .font(.bykFootnote)
                        .foregroundStyle(Color.bykSecondaryInk)
                }
            }
        } icon: {
            Image(systemName: destination.systemImage)
                .foregroundStyle(Color.bykSecondaryInk)
        }
    }
}

/// iPad, Mac, Apple Vision Pro: sidebar of every visible destination, grouped by area.
struct SidebarShell: View {
    let level: ExperienceLevel
    @State private var selection: AppDestination? = .connection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(AppArea.visible(at: level), id: \.self) { area in
                    Section {
                        ForEach(area.destinations(at: level)) { destination in
                            NavigationLink(value: destination) {
                                DestinationLabel(destination: destination)
                            }
                        }
                    } header: {
                        if area == .tools {
                            SectionHeader(area.title)
                        }
                    }
                }
            }
            .navigationTitle("Бык")
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            #endif
        } detail: {
            NavigationStack {
                (selection ?? .connection).screen
            }
            .id(selection ?? .connection)
        }
        .onChange(of: level) {
            if let current = selection, !AppDestination.visible(at: level).contains(current) {
                selection = .settings
            }
        }
    }
}
