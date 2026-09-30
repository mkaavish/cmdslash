import SwiftUI

/// Sections of the companion window (Docs/PLANNING.md §34) — API Key and Settings today,
/// Connectors planned next.
enum CompanionSection: String, CaseIterable, Identifiable {
    case apiKey = "API Key"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .apiKey: "key.fill"
        case .settings: "gearshape"
        }
    }
}

/// The companion window's root — a sidebar over its sections, matching the settings-like
/// affordance the window is meant to have (account/settings/connectors, not a single flat page).
struct CompanionView: View {
    @State private var selection: CompanionSection? = .apiKey

    var body: some View {
        NavigationSplitView {
            List(CompanionSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(160)
        } detail: {
            switch selection {
            case .apiKey, .none:
                APIKeyView()
            case .settings:
                SettingsView()
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }
}

#Preview {
    CompanionView()
}
