import SwiftUI
import AppKit
import Observation
import ServiceManagement

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 680)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
@Observable
final class SettingsDictationTestController {
    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var transcript: String?
    private(set) var lastError: String?

    private var recorder: AudioRecorder?
    private let transcriber: SpeechTranscriber
    private let audioInputCoordinator: AudioInputCoordinator
    private let recorderFactory: () -> AudioRecorder

    init(
        transcriber: SpeechTranscriber,
        audioInputCoordinator: AudioInputCoordinator,
        recorderFactory: @escaping () -> AudioRecorder
    ) {
        self.transcriber = transcriber
        self.audioInputCoordinator = audioInputCoordinator
        self.recorderFactory = recorderFactory
    }

    func start() {
        guard !isRecording else { return }
        transcript = nil
        lastError = nil

        Task {
            let recorder = recorderFactory()
            recorder.prewarm()
            await audioInputCoordinator.pausePreviewForCapture()

            do {
                try await recorder.startRecording()
                self.recorder = recorder
                self.isRecording = true
            } catch {
                audioInputCoordinator.resumePreviewAfterCapture()
                self.lastError = "Could not start recording."
            }
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        isRecording = false
        isTranscribing = true
        self.recorder = nil

        Task {
            let buffer = await recorder.stopRecording()
            audioInputCoordinator.resumePreviewAfterCapture()
            let text = await transcriber.transcribe(audioBuffer: buffer)
            self.transcript = text
            self.lastError = text == nil ? "Ghost Pepper could not transcribe that sample." : nil
            self.isTranscribing = false
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case cleanup
    case corrections
    case models
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .cleanup: "Cleanup"
        case .corrections: "Corrections"
        case .models: "Models"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: "Shortcuts, microphone input, dictation testing, and sound feedback."
        case .cleanup: "Prompt cleanup, OCR context, and learning behavior."
        case .corrections: "Words and replacements Ghost Pepper should preserve."
        case .models: "Speech and cleanup model downloads and runtime status."
        case .general: "Startup behavior, permissions, and app-wide controls."
        }
    }

    var systemImageName: String {
        switch self {
        case .recording: "waveform.and.mic"
        case .cleanup: "sparkles"
        case .corrections: "text.badge.checkmark"
        case .models: "brain"
        case .general: "gearshape"
        }
    }
}

struct RecordingSpeakerFilteringToggleState {
    let isVisible: Bool
    let isEnabled: Bool

    init(speechModel: SpeechModelDescriptor?) {
        isVisible = true
        isEnabled = speechModel?.supportsSpeakerFiltering ?? false
    }
}

struct SettingsView: View {
    let appState: AppState
    private let audioInputCoordinator: AudioInputCoordinator
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var hasAccessibilityPermission = PermissionChecker.checkAccessibility()
    @State private var hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
    @State private var selectedSection: SettingsSection = .recording
    @State private var dictationTestController: SettingsDictationTestController

    init(appState: AppState) {
        self.appState = appState
        self.audioInputCoordinator = appState.audioInputCoordinator
        _dictationTestController = State(
            initialValue: SettingsDictationTestController(
                transcriber: appState.transcriber,
                audioInputCoordinator: appState.audioInputCoordinator,
                recorderFactory: {
                    AudioRecorder(
                        preferredInputDeviceUIDProvider: { [weak coordinator = appState.audioInputCoordinator] in
                            coordinator?.selectedDeviceUID
                        }
                    )
                }
            )
        )
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: appState.modelManager.modelName,
            speechModelState: appState.modelManager.state,
            speechDownloadProgress: appState.modelManager.downloadProgress,
            cachedSpeechModelNames: appState.modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            selectedCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
            cachedCleanupKinds: appState.textCleanupManager.cachedModelKinds
        )
    }

    private var speakerFilteringToggleState: RecordingSpeakerFilteringToggleState {
        RecordingSpeakerFilteringToggleState(
            speechModel: SpeechModelCatalog.model(named: appState.speechModel)
        )
    }

    var body: some View {
        HSplitView {
            sidebar

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    switch selectedSection {
                    case .recording:
                        recordingSection
                    case .cleanup:
                        cleanupSection
                    case .corrections:
                        correctionsSection
                    case .models:
                        modelsSection
                    case .general:
                        generalSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear {
            refreshPermissions()
            audioInputCoordinator.refreshDevices()
            audioInputCoordinator.setPreviewActive(true)
        }
        .onDisappear {
            audioInputCoordinator.setPreviewActive(false)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImageName)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .font(.body.weight(.medium))
                            Text(section.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                selectedSection == section
                                    ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
                                    : .clear
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(minWidth: 250, idealWidth: 270, maxWidth: 290)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(selectedSection.title)
                .font(.title2.weight(.semibold))
            Text(selectedSection.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("Shortcuts") {
                ShortcutRecorderView(
                    title: "Push to Talk",
                    chord: appState.pushToTalkChord,
                    onRecordingStateChange: appState.setShortcutCaptureActive(_:),
                    onChange: { appState.updateShortcut($0, for: .pushToTalk) }
                )
                Divider()
                ShortcutRecorderView(
                    title: "Toggle to Talk",
                    chord: appState.toggleToTalkChord,
                    onRecordingStateChange: appState.setShortcutCaptureActive(_:),
                    onChange: { appState.updateShortcut($0, for: .toggleToTalk) }
                )

                if let shortcutErrorMessage = appState.shortcutErrorMessage {
                    Text(shortcutErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            SettingsCard("Input") {
                if audioInputCoordinator.inputDevices.isEmpty {
                    Text("No audio input devices detected.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Preferred microphone", selection: Binding(
                        get: { audioInputCoordinator.selectedDeviceUID ?? "" },
                        set: { audioInputCoordinator.selectDevice(uid: $0) }
                    )) {
                        ForEach(audioInputCoordinator.inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }

                    Text(audioInputCoordinator.stateDescription)
                        .font(.caption)
                        .foregroundStyle(audioInputStatusColor)

                    if audioInputCoordinator.selectedDevice?.isContinuityCandidate == true {
                        Text("Continuity microphones are supported as app-local inputs. Ghost Pepper now keeps setup responsive and reports whether frames arrive or stay silent.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(audioInputCoordinator.level > 0.7 ? .red : audioInputCoordinator.level > 0.3 ? .orange : .green)
                                    .frame(width: geo.size.width * CGFloat(audioInputCoordinator.level))
                                    .animation(.easeOut(duration: 0.08), value: audioInputCoordinator.level)
                            }
                        }
                        .frame(height: 8)

                        Text("Live level")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(height: 12)
                }

                Toggle("Play start/stop sounds", isOn: Binding(
                    get: { appState.playSounds },
                    set: { appState.playSounds = $0 }
                ))

                if speakerFilteringToggleState.isVisible {
                    Toggle("Ignore other speakers when supported", isOn: Binding(
                        get: { appState.ignoreOtherSpeakers },
                        set: { appState.ignoreOtherSpeakers = $0 }
                    ))
                    .disabled(!speakerFilteringToggleState.isEnabled)

                    if !speakerFilteringToggleState.isEnabled {
                        Text("Speaker filtering is unavailable for the selected speech model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Dictation Test") {
                HStack(spacing: 12) {
                    Button(dictationTestController.isRecording ? "Recording..." : "Start Test") {
                        dictationTestController.start()
                    }
                    .disabled(dictationTestController.isRecording || dictationTestController.isTranscribing)

                    Button(dictationTestController.isTranscribing ? "Transcribing..." : "Stop Test") {
                        dictationTestController.stop()
                    }
                    .disabled(!dictationTestController.isRecording)
                }

                if let transcript = dictationTestController.transcript, !transcript.isEmpty {
                    Text(transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let lastError = dictationTestController.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("Cleanup") {
                Toggle("Enable transcript cleanup", isOn: Binding(
                    get: { appState.cleanupEnabled },
                    set: { appState.setCleanupEnabled($0) }
                ))

                HStack {
                    Text("Prompt")
                    Spacer()
                    Button("Edit Prompt...") {
                        appState.showPromptEditor()
                    }
                }
            }

            SettingsCard("Context") {
                Toggle("Use frontmost window OCR as supporting context", isOn: Binding(
                    get: { appState.frontmostWindowContextEnabled },
                    set: { appState.frontmostWindowContextEnabled = $0 }
                ))

                if appState.frontmostWindowContextEnabled && !hasScreenRecordingPermission {
                    Text("Screen Recording permission is required for OCR context capture.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Learn short replacements after paste", isOn: Binding(
                    get: { appState.postPasteLearningEnabled },
                    set: { appState.postPasteLearningEnabled = $0 }
                ))

                if appState.postPasteLearningEnabled && !hasScreenRecordingPermission {
                    Text("Post-paste learning is more reliable when Screen Recording access is granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var correctionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("Preferred Transcriptions") {
                Text("One phrase per line. Ghost Pepper will preserve these spellings exactly when possible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: Binding(
                    get: { appState.correctionStore.preferredTranscriptionsText },
                    set: { appState.correctionStore.preferredTranscriptionsText = $0 }
                ))
                .font(.body)
                .frame(minHeight: 180)
            }

            SettingsCard("Commonly Misheard") {
                Text("Write replacements as `heard -> intended`, one per line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: Binding(
                    get: { appState.correctionStore.commonlyMisheardText },
                    set: { appState.correctionStore.commonlyMisheardText = $0 }
                ))
                .font(.body)
                .frame(minHeight: 180)
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard("Speech Model") {
                Picker("Selected speech model", selection: Binding(
                    get: { appState.speechModel },
                    set: { newValue in
                        appState.speechModel = newValue
                        Task {
                            await appState.loadSpeechModel(name: newValue)
                        }
                    }
                )) {
                    ForEach(ModelManager.availableModels, id: \.name) { model in
                        Text(model.statusName).tag(model.name)
                    }
                }
            }

            SettingsCard("Cleanup Model") {
                Picker("Selected cleanup model", selection: Binding(
                    get: { appState.textCleanupManager.selectedCleanupModelKind },
                    set: { newValue in
                        appState.textCleanupManager.selectedCleanupModelKind = newValue
                        Task {
                            await appState.textCleanupManager.loadModel(kind: newValue)
                        }
                    }
                )) {
                    ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
                        Text(model.displayName).tag(model.kind)
                    }
                }

                HStack(spacing: 12) {
                    Button("Load Selected") {
                        Task {
                            await appState.textCleanupManager.loadModel()
                        }
                    }

                    Button("Download Missing Models") {
                        Task {
                            await appState.textCleanupManager.downloadMissingModels()
                        }
                    }
                }

                if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                    Text(activeDownloadText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Runtime Inventory") {
                ModelInventoryCard(rows: modelRows)
            }
        }
    }

    private var generalSection: some View {
        @Bindable var appState = appState

        return VStack(alignment: .leading, spacing: 16) {
            SettingsCard("Startup") {
                Toggle("Launch Ghost Pepper at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        updateLaunchAtLogin(newValue)
                    }
                ))

                Button("Relaunch Ghost Pepper") {
                    appState.relaunchApp()
                }
            }

            SettingsCard("Permissions") {
                PermissionRow(
                    title: "Accessibility",
                    isGranted: hasAccessibilityPermission,
                    grantTitle: "Open Accessibility Settings",
                    grantAction: PermissionChecker.openAccessibilitySettings
                )
                Divider()
                PermissionRow(
                    title: "Input Monitoring",
                    isGranted: hasInputMonitoringPermission,
                    grantTitle: "Open Input Monitoring Settings",
                    grantAction: PermissionChecker.openInputMonitoringSettings
                )
                Divider()
                PermissionRow(
                    title: "Screen Recording",
                    isGranted: hasScreenRecordingPermission,
                    grantTitle: "Open Screen Recording Settings",
                    grantAction: PermissionChecker.openScreenRecordingSettings
                )

                Button("Refresh Permissions") {
                    refreshPermissions()
                }
            }

            SettingsCard("Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Observability Mode")
                        .font(.body.weight(.medium))

                    Picker("Observability Mode", selection: $appState.observabilityMode) {
                        ForEach(ObservabilityMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Info keeps always-on operational lifecycle logs. Trace adds finer-grained local diagnostics without logging transcript or OCR content.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Button("Open Debug Log") {
                    appState.showDebugLog()
                }
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return
        }

        launchAtLogin = enabled
    }

    private func refreshPermissions() {
        hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
        hasAccessibilityPermission = PermissionChecker.checkAccessibility()
        hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
    }

    private var audioInputStatusColor: Color {
        switch audioInputCoordinator.selectionState {
        case .ready:
            return .green
        case .noFramesReceived, .silentInput:
            return .orange
        case .failed, .deviceMissing:
            return .red
        case .idle, .connecting, .waitingForFrames:
            return .secondary
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let isGranted: Bool
    let grantTitle: String
    let grantAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(isGranted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundStyle(isGranted ? Color.secondary : Color.orange)
            }

            Spacer()

            if !isGranted {
                Button(grantTitle) {
                    grantAction()
                }
            }
        }
    }
}
