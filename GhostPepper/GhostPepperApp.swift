import SwiftUI

enum AppStorageKeys {
    static let onboardingCompleted = "onboardingCompleted"
}

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
    private static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @NSApplicationDelegateAdaptor(GhostPepperLifecycleDelegate.self) private var lifecycleDelegate
    @State private var appState = AppState()
    @AppStorage(AppStorageKeys.onboardingCompleted) private var onboardingCompleted = false
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
                guard !hasInitialized else { return }
                hasInitialized = true

                // App-hosted XCTest launches should not present onboarding or mutate
                // global activation policy just because the test host booted the app.
                guard Self.isRunningTests == false else {
                    return
                }

                ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
                lifecycleDelegate.onWillTerminate = {
                    ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
                    appState.prepareForTermination()
                }
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
