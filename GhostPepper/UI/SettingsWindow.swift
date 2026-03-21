import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let promptEditor = PromptEditorController()

    var body: some View {
        Form {
            Section("Input") {
                Picker("Microphone", selection: $selectedDeviceID) {
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    AudioDeviceManager.setDefaultInputDevice(newValue)
                }
            }

            Section("Cleanup") {
                Toggle("Enable cleanup", isOn: $appState.cleanupEnabled)
                    .onChange(of: appState.cleanupEnabled) { _, enabled in
                        Task {
                            if enabled {
                                await appState.textCleanupManager.loadModel()
                            } else {
                                appState.textCleanupManager.unloadModel()
                            }
                        }
                    }

                if appState.cleanupEnabled {
                    Button("Edit Cleanup Prompt...") {
                        promptEditor.show(appState: appState)
                    }

                    if appState.textCleanupManager.state == .error {
                        Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 400, height: 300)
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
            selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
        }
    }
}
