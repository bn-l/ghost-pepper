import SwiftUI

@MainActor
final class GhostPepperLifecycleDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }
}

@main
struct GhostPepperApp: App {
    private static let automaticTerminationReason = "Ghost Pepper keeps a persistent menu bar presence."
    @NSApplicationDelegateAdaptor(GhostPepperLifecycleDelegate.self) private var lifecycleDelegate
    @State private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var hasInitialized = false
    private let onboardingController = OnboardingWindowController()

    var body: some Scene {
        MenuBarExtra {
            if !onboardingCompleted {
                Button("Show Setup Window") {
                    onboardingController.bringToFront()
                }
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            } else {
                MenuBarView(appState: appState)
            }
        } label: {
            Group {
                switch appState.status {
                case .recording:
                    Image("MenuBarIconRedDim")
                        .renderingMode(.original)
                case .loading:
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.yellow)
                default:
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                }
            }
            .onAppear {
                lifecycleDelegate.onWillTerminate = {
                    ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
                    appState.prepareForTermination()
                }
                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                guard !hasInitialized else { return }
                hasInitialized = true
                if onboardingCompleted {
                    Task { await appState.initialize() }
                } else {
                    onboardingController.show(appState: appState) {
                        onboardingCompleted = true
                        Task { await appState.initialize() }
                    }
                }
            }
        }
    }
}
