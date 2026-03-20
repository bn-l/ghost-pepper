import SwiftUI

@main
struct GhostPepperApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            if appState.status == .ready || appState.status == .transcribing || appState.status == .cleaningUp {
                Image("MenuBarIcon")
                    .renderingMode(.template)
            } else {
                Image(systemName: menuBarIconName)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(menuBarIconColor)
            }
        }
    }

    private var menuBarIconName: String {
        switch appState.status {
        case .loading:
            return "arrow.down.circle"
        case .recording:
            return "waveform.circle.fill"
        case .error:
            return "exclamationmark.triangle"
        default:
            return "waveform"
        }
    }

    private var menuBarIconColor: Color {
        switch appState.status {
        case .loading: return .orange
        case .recording: return .red
        case .error: return .yellow
        default: return .primary
        }
    }
}
