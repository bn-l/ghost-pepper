import SwiftUI
import Observation
import ServiceManagement

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case cleaningUp = "Cleaning up..."
    case error = "Error"
}

enum EmptyTranscriptionDisposition: Equatable {
    case cancel
    case showNoSoundDetected
}

@MainActor
@Observable
final class AppState {
    enum PipelineOwner {
        case liveRecording
    }

    typealias CleanupResult = (
        text: String,
        prompt: String,
        attemptedCleanup: Bool,
        cleanupUsedFallback: Bool
    )

    private struct RecordingTranscriptionResult {
        let rawTranscription: String?
    }

    var status: AppStatus = .loading
    var isRecording: Bool = false
    var errorMessage: String?
    var shortcutErrorMessage: String?
    var cleanupBackend: CleanupBackendOption {
        didSet {
            cleanupSettingsDefaults.set(cleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        }
    }
    var frontmostWindowContextEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                frontmostWindowContextEnabled,
                forKey: Self.frontmostWindowContextEnabledDefaultsKey
            )
        }
    }
    var playSounds: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                playSounds,
                forKey: Self.playSoundsDefaultsKey
            )
        }
    }
    var observabilityMode: ObservabilityMode {
        didSet {
            cleanupSettingsDefaults.set(
                observabilityMode.rawValue,
                forKey: ObservabilityConfig.defaultsKey
            )
            debugLogStore.refresh()
            if observabilityMode != oldValue {
                logSystem.logger(category: .ui) { [weak self] in
                    self?.currentLogContext ?? .empty
                }.notice(
                    "observability.mode_changed",
                    "Observability mode changed.",
                    fields: ["mode": observabilityMode.rawValue]
                )
            }
        }
    }
    var cleanupEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(cleanupEnabled, forKey: Self.cleanupEnabledDefaultsKey)
        }
    }
    var cleanupPrompt: String {
        didSet {
            cleanupSettingsDefaults.set(cleanupPrompt, forKey: Self.cleanupPromptDefaultsKey)
        }
    }
    var speechModel: String {
        didSet {
            cleanupSettingsDefaults.set(speechModel, forKey: Self.speechModelDefaultsKey)
        }
    }
    private(set) var pushToTalkChord: KeyChord
    private(set) var toggleToTalkChord: KeyChord
    var postPasteLearningEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                postPasteLearningEnabled,
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
            postPasteLearningCoordinator.learningEnabled = postPasteLearningEnabled
        }
    }
    var ignoreOtherSpeakers: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                ignoreOtherSpeakers,
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
    }

    let modelManager = ModelManager()
    let audioInputCoordinator: AudioInputCoordinator
    let audioRecorder: AudioRecorder
    let transcriber: SpeechTranscriber
    let textPaster: TextPaster
    @ObservationIgnored
    lazy var soundEffects = SoundEffects(isEnabled: { [weak self] in
        self?.playSounds ?? true
    })
    let hotkeyMonitor: HotkeyMonitoring
    let overlay = RecordingOverlayController()
    let textCleanupManager: TextCleanupManager
    let frontmostWindowOCRService: FrontmostWindowOCRService
    let cleanupPromptBuilder: CleanupPromptBuilder
    let correctionStore: CorrectionStore
    let textCleaner: TextCleaner
    let chordBindingStore: ChordBindingStore
    let postPasteLearningCoordinator: PostPasteLearningCoordinator
    let debugLogStore: DebugLogStore
    let logSystem: AppLogSystem
    let appRelauncher: AppRelaunching
    var recordingSessionCoordinatorFactory: (() -> RecordingSessionCoordinator?)?
    var transcribeAudioBufferOverride: (([Float]) -> String?)?
    var cleanedTranscriptionResultOverride: ((String, OCRContext?) async -> CleanupResult)?
    private(set) var activeRecordingSessionCoordinator: RecordingSessionCoordinator?

    var isReady: Bool {
        status == .ready
    }

    static func emptyTranscriptionDisposition(forAudioSampleCount sampleCount: Int) -> EmptyTranscriptionDisposition {
        if sampleCount < emptyTranscriptionCancelThresholdSampleCount {
            return .cancel
        }

        return .showNoSoundDetected
    }

    @ObservationIgnored
    private let recordingOCRPrefetch: RecordingOCRPrefetch
    @ObservationIgnored
    private var activePerformanceTrace: PerformanceTrace?
    @ObservationIgnored
    private var activeCleanupAttempted = false
    @ObservationIgnored
    private var pipelineOwner: PipelineOwner?
    @ObservationIgnored
    private let appSessionID = UUID().uuidString
    @ObservationIgnored
    private let cleanupSettingsDefaults: UserDefaults
    @ObservationIgnored
    private let inputMonitoringChecker: () -> Bool
    @ObservationIgnored
    private let inputMonitoringPrompter: () -> Void
    @ObservationIgnored
    private var hotkeyMonitorStarted = false
    @ObservationIgnored
    private var clipboardFallbackDismissTask: Task<Void, Never>?
    @ObservationIgnored
    private var loadingOverlayDismissTask: Task<Void, Never>?

    private static let cleanupBackendDefaultsKey = "cleanupBackend"
    private static let cleanupEnabledDefaultsKey = "cleanupEnabled"
    private static let cleanupPromptDefaultsKey = "cleanupPrompt"
    private static let speechModelDefaultsKey = "speechModel"
    private static let frontmostWindowContextEnabledDefaultsKey = "frontmostWindowContextEnabled"
    private static let postPasteLearningEnabledDefaultsKey = "postPasteLearningEnabled"
    private static let ignoreOtherSpeakersDefaultsKey = "ignoreOtherSpeakers"
    private static let playSoundsDefaultsKey = "playSounds"
    private static let emptyTranscriptionCancelThresholdSampleCount = 80_000
    private static let speechModelErrorPrefix = "Failed to load speech model: "

    nonisolated static let defaultPushToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61)   // Right Option
    ]))!

    nonisolated static let defaultToggleToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),  // Right Command
        PhysicalKey(keyCode: 61),  // Right Option
        PhysicalKey(keyCode: 49)   // Space
    ]))!

    nonisolated static let defaultShortcutBindings: [ChordAction: KeyChord] = [
        .pushToTalk: defaultPushToTalkChord,
        .toggleToTalk: defaultToggleToTalkChord
    ]

    init(
        hotkeyMonitor: HotkeyMonitoring = HotkeyMonitor(bindings: AppState.defaultShortcutBindings),
        chordBindingStore: ChordBindingStore = ChordBindingStore(),
        cleanupSettingsDefaults: UserDefaults = .standard,
        textCleanupManager: TextCleanupManager? = nil,
        frontmostWindowOCRService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        correctionStore: CorrectionStore? = nil,
        audioInputCoordinator: AudioInputCoordinator? = nil,
        audioRecorder: AudioRecorder? = nil,
        textPaster: TextPaster = TextPaster(),
        debugLogStore: DebugLogStore? = nil,
        appRelauncher: AppRelaunching? = nil,
        privacyMaintenance: PrivacyMaintaining = PrivacyMaintenance.defaultClient,
        inputMonitoringChecker: @escaping () -> Bool = PermissionChecker.checkInputMonitoring,
        inputMonitoringPrompter: @escaping () -> Void = PermissionChecker.promptInputMonitoring
    ) {
        privacyMaintenance.run(defaults: cleanupSettingsDefaults)
        self.hotkeyMonitor = hotkeyMonitor
        self.chordBindingStore = chordBindingStore
        self.cleanupSettingsDefaults = cleanupSettingsDefaults
        self.textPaster = textPaster
        self.logSystem = AppLogSystem(
            configProvider: { ObservabilityConfig.resolve(defaults: cleanupSettingsDefaults) }
        )
        self.debugLogStore = debugLogStore ?? DebugLogStore()
        self.appRelauncher = appRelauncher ?? AppRelauncher()
        self.inputMonitoringChecker = inputMonitoringChecker
        self.inputMonitoringPrompter = inputMonitoringPrompter
        self.pushToTalkChord = chordBindingStore.binding(for: .pushToTalk) ?? AppState.defaultPushToTalkChord
        self.toggleToTalkChord = chordBindingStore.binding(for: .toggleToTalk) ?? AppState.defaultToggleToTalkChord
        self.textCleanupManager = textCleanupManager ?? TextCleanupManager(defaults: cleanupSettingsDefaults)
        self.frontmostWindowOCRService = frontmostWindowOCRService
        let resolvedAudioInputCoordinator = audioInputCoordinator ?? AudioInputCoordinator(defaults: cleanupSettingsDefaults)
        self.audioInputCoordinator = resolvedAudioInputCoordinator
        self.audioRecorder = audioRecorder ?? AudioRecorder(
            preferredInputDeviceUIDProvider: { [weak resolvedAudioInputCoordinator] in
                resolvedAudioInputCoordinator?.selectedDeviceUID
            }
        )
        self.recordingOCRPrefetch = RecordingOCRPrefetch { [frontmostWindowOCRService] customWords in
            await frontmostWindowOCRService.captureContext(customWords: customWords)
        }
        self.cleanupPromptBuilder = cleanupPromptBuilder
        self.correctionStore = correctionStore ?? CorrectionStore(defaults: cleanupSettingsDefaults)
        let storedCleanupBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.cleanupBackendDefaultsKey) ?? ""
        ) ?? .localModels
        let storedCleanupEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.cleanupEnabledDefaultsKey) == nil {
            storedCleanupEnabled = true
        } else {
            storedCleanupEnabled = cleanupSettingsDefaults.bool(forKey: Self.cleanupEnabledDefaultsKey)
        }
        let storedCleanupPrompt = cleanupSettingsDefaults.string(forKey: Self.cleanupPromptDefaultsKey) ?? TextCleaner.defaultPrompt
        let storedSpeechModel = cleanupSettingsDefaults.string(forKey: Self.speechModelDefaultsKey) ?? SpeechModelCatalog.defaultModelID
        let storedFrontmostWindowContextEnabled = cleanupSettingsDefaults.bool(
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        let storedPostPasteLearningEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.postPasteLearningEnabledDefaultsKey) == nil {
            storedPostPasteLearningEnabled = true
        } else {
            storedPostPasteLearningEnabled = cleanupSettingsDefaults.bool(
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
        }
        let storedIgnoreOtherSpeakers: Bool
        if cleanupSettingsDefaults.object(forKey: Self.ignoreOtherSpeakersDefaultsKey) == nil {
            storedIgnoreOtherSpeakers = false
        } else {
            storedIgnoreOtherSpeakers = cleanupSettingsDefaults.bool(
                forKey: Self.ignoreOtherSpeakersDefaultsKey
            )
        }
        self.cleanupEnabled = storedCleanupEnabled
        self.cleanupPrompt = storedCleanupPrompt
        self.speechModel = storedSpeechModel
        self.cleanupBackend = storedCleanupBackend
        self.frontmostWindowContextEnabled = storedFrontmostWindowContextEnabled
        self.postPasteLearningEnabled = storedPostPasteLearningEnabled
        self.ignoreOtherSpeakers = storedIgnoreOtherSpeakers
        self.observabilityMode = ObservabilityConfig.resolve(defaults: cleanupSettingsDefaults).mode
        if cleanupSettingsDefaults.object(forKey: Self.playSoundsDefaultsKey) == nil {
            self.playSounds = true
        } else {
            self.playSounds = cleanupSettingsDefaults.bool(forKey: Self.playSoundsDefaultsKey)
        }
        self.transcriber = SpeechTranscriber(modelManager: modelManager)
        self.textCleaner = TextCleaner(
            cleanupManager: self.textCleanupManager,
            correctionStore: self.correctionStore
        )
        self.postPasteLearningCoordinator = PostPasteLearningCoordinator(
            correctionStore: self.correctionStore,
            learningEnabled: storedPostPasteLearningEnabled,
            revisit: { session in
                await PostPasteLearningObservationProvider.captureObservation(
                    for: session
                )
            }
        )

        cleanupSettingsDefaults.set(storedCleanupEnabled, forKey: Self.cleanupEnabledDefaultsKey)
        cleanupSettingsDefaults.set(storedCleanupPrompt, forKey: Self.cleanupPromptDefaultsKey)
        cleanupSettingsDefaults.set(storedSpeechModel, forKey: Self.speechModelDefaultsKey)
        cleanupSettingsDefaults.set(storedCleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        cleanupSettingsDefaults.set(
            storedFrontmostWindowContextEnabled,
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedPostPasteLearningEnabled,
            forKey: Self.postPasteLearningEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedIgnoreOtherSpeakers,
            forKey: Self.ignoreOtherSpeakersDefaultsKey
        )
        cleanupSettingsDefaults.set(
            playSounds,
            forKey: Self.playSoundsDefaultsKey
        )
        persistShortcutBindingsIfNeeded()
        hotkeyMonitor.updateBindings(shortcutBindings)
        self.textPaster.onPaste = { [postPasteLearningCoordinator = self.postPasteLearningCoordinator] session in
            postPasteLearningCoordinator.handlePaste(session)
        }
        self.audioRecorder.onRecordingStarted = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micLiveAt = .now
            }
        }
        self.audioRecorder.onRecordingStopped = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.micColdAt = .now
            }
        }
        self.textPaster.onPasteStart = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.pasteStartAt = .now
            }
        }
        self.textPaster.onPasteEnd = { [weak self] in
            Task { @MainActor in
                self?.completeActivePerformanceTraceIfNeeded()
            }
        }
        self.postPasteLearningCoordinator.onLearnedCorrection = { [weak overlay] replacement in
            Task { @MainActor in
                overlay?.show(message: .learnedCorrection(replacement))
            }
        }
        let componentContextProvider: () -> AppLogContext = { [weak self] in
            self?.currentLogContext ?? .empty
        }
        if let hotkeyMonitor = hotkeyMonitor as? HotkeyMonitor {
            hotkeyMonitor.logger = self.logSystem.logger(category: .hotkey, contextProvider: componentContextProvider)
        }
        self.audioInputCoordinator.logger = self.logSystem.logger(category: .audio, contextProvider: componentContextProvider)
        self.audioRecorder.logger = self.logSystem.logger(category: .recording, contextProvider: componentContextProvider)
        self.textCleanupManager.logger = self.logSystem.logger(category: .cleanup, contextProvider: componentContextProvider)
        self.frontmostWindowOCRService.logger = self.logSystem.logger(category: .ocr, contextProvider: componentContextProvider)
        self.textCleaner.logger = self.logSystem.logger(category: .cleanup, contextProvider: componentContextProvider)
        self.postPasteLearningCoordinator.logger = self.logSystem.logger(category: .learning, contextProvider: componentContextProvider)
        self.modelManager.logger = self.logSystem.logger(category: .model, contextProvider: componentContextProvider)
    }

    func initialize(skipPermissionPrompts: Bool = false) async {
        // Enable launch at login by default on first run
        if !UserDefaults.standard.bool(forKey: "hasSetLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "hasSetLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        if !skipPermissionPrompts {
            let hasMic = await PermissionChecker.checkMicrophone()
            if !hasMic {
                errorMessage = "Microphone access required"
                status = .error
                return
            }

            let needsAccessibility = !PermissionChecker.checkAccessibility()
            let needsInputMonitoring = !inputMonitoringChecker()
            if needsAccessibility || needsInputMonitoring {
                showSettings()
            }
        }

        audioInputCoordinator.refreshDevices()
        audioRecorder.prewarm()
        FocusedElementLocator.startPasteTargetTracking()

        status = .loading
        let showOverlay = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        let initializationInterval = appLogger.beginInterval(
            "app.initialization",
            "App initialization started.",
            fields: ["speechModelID": speechModel]
        )
        defer {
            appLogger.endInterval(initializationInterval, "App initialization finished.", fields: ["status": status.rawValue])
        }
        if showOverlay {
            overlay.show(message: .modelLoading)
        }
        if !modelManager.isReady {
            await loadSpeechModel(name: speechModel)
        }
        if showOverlay {
            overlay.dismiss()
        }

        guard modelManager.isReady else {
            return
        }

        await startHotkeyMonitor()

        await refreshCleanupModelState()
    }

    func relaunchApp() {
        do {
            try appRelauncher.relaunch()
        } catch {
            errorMessage = "Failed to relaunch Ghost Pepper: \(error.localizedDescription)"
            appLogger.error("app.relaunch_failed", errorMessage ?? "Failed to relaunch Ghost Pepper.", error: error)
        }
    }

    func startHotkeyMonitor() async {
        hotkeyMonitor.onRecordingStart = nil
        hotkeyMonitor.onRecordingStop = nil
        hotkeyMonitor.onRecordingRestart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Push-to-talk upgraded to toggle — reset buffer only if recording just started
                // (less than 1 second of audio at 16kHz). If they've been talking longer, keep it.
                let sampleCount = self.audioRecorder.audioBuffer.count
                if sampleCount < 16000 {
                    self.audioRecorder.resetBuffer()
                    self.hotkeyLogger.notice("recording.restart_discarded_samples", "Recording restarted after push-to-talk upgraded to toggle.", fields: ["discardedSampleCount": String(sampleCount)])
                } else {
                    self.hotkeyLogger.notice("recording.restart_kept_samples", "Push-to-talk upgraded to toggle while keeping existing audio.", fields: ["keptSampleCount": String(sampleCount)])
                }
            }
        }

        hotkeyMonitor.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onPushToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = .now
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onToggleToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.beginPerformanceTrace()
                await self?.startRecording()
            }
        }
        hotkeyMonitor.onToggleToTalkStop = { [weak self] in
            Task { @MainActor in
                self?.activePerformanceTrace?.hotkeyLiftedAt = .now
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyMonitor.updateBindings(shortcutBindings)

        if hotkeyMonitorStarted {
            hotkeyLogger.info("monitor.start_skipped", "Hotkey monitor start skipped because it is already active.")
            if status != .error {
                status = .ready
                errorMessage = nil
            }
            return
        }

        if !inputMonitoringChecker() {
            // Try to prompt, but don't block — Accessibility alone may be sufficient
            inputMonitoringPrompter()
            permissionsLogger.warning("input_monitoring.missing", "Input Monitoring not granted. Attempting to start with Accessibility only.")
        }

        if hotkeyMonitor.start() {
            hotkeyMonitorStarted = true
            status = .ready
            errorMessage = nil
            hotkeyLogger.notice("monitor.ready", "Hotkey monitor is ready.")
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
            permissionsLogger.warning("accessibility.required", errorMessage ?? "Accessibility access required.")
        }
    }

    func prepareRecordingSessionIfNeeded() async {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil

        guard ignoreOtherSpeakers, selectedSpeechModelSupportsSpeakerFiltering else {
            return
        }

        let coordinator: RecordingSessionCoordinator?
        if let recordingSessionCoordinatorFactory {
            coordinator = recordingSessionCoordinatorFactory()
        } else {
            coordinator = await modelManager.makeRecordingSessionCoordinator()
        }

        guard let coordinator else {
            return
        }

        activeRecordingSessionCoordinator = coordinator
        audioRecorder.onConvertedAudioChunk = { [weak coordinator] samples in
            coordinator?.appendAudioChunk(samples)
        }
    }

    private func clearRecordingSessionCoordinator() {
        audioRecorder.onConvertedAudioChunk = nil
        activeRecordingSessionCoordinator = nil
    }

    private var selectedSpeechModelSupportsSpeakerFiltering: Bool {
        SpeechModelCatalog.model(named: speechModel)?.supportsSpeakerFiltering == true
    }

    private func startRecording() async {
        // If the selected speech model isn't ready, show loading message
        guard status == .ready else {
            if status == .loading {
                overlay.show(message: .modelLoading)
                loadingOverlayDismissTask?.cancel()
                loadingOverlayDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    self?.overlay.dismiss()
                }
            }
            return
        }

        if activePerformanceTrace == nil {
            beginPerformanceTrace()
        }

        guard acquirePipeline(for: .liveRecording) else {
            hotkeyLogger.info("recording.start_skipped_pipeline_busy", "Recording start skipped because the transcription pipeline is busy.")
            activePerformanceTrace = nil
            activeCleanupAttempted = false
            return
        }

        do {
            await prepareRecordingSessionIfNeeded()
            if cleanupEnabled && canAttemptCleanup && frontmostWindowContextEnabled {
                recordingOCRPrefetch.start(customWords: ocrCustomWords)
            } else {
                recordingOCRPrefetch.cancel()
            }
            await audioInputCoordinator.pausePreviewForCapture()
            try await audioRecorder.startRecording()
            recordingLogger.notice("recording.started", "Recording started.")
            soundEffects.playStart()
            overlay.show(message: .recording)
            isRecording = true
            status = .recording
        } catch {
            recordingOCRPrefetch.cancel()
            audioInputCoordinator.resumePreviewAfterCapture()
            releasePipeline(owner: .liveRecording)
            activePerformanceTrace = nil
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
            recordingLogger.error("recording.start_failed", errorMessage ?? "Failed to start recording.", error: error)
        }
    }

    private var isTranscribing = false

    private func stopRecordingAndTranscribe() async {
        guard status == .recording, !isTranscribing else { return }
        isTranscribing = true
        defer { isTranscribing = false }

        recordingLogger.info("recording.stopped", "Recording stopped. Starting transcription.")
        let buffer = await audioRecorder.stopRecording()
        audioInputCoordinator.resumePreviewAfterCapture()
        let recordingSessionCoordinator = activeRecordingSessionCoordinator
        clearRecordingSessionCoordinator()
        soundEffects.playStop()
        isRecording = false
        status = .transcribing
        overlay.show(message: .transcribing)
        activePerformanceTrace?.transcriptionStartAt = .now

        let archivedWindowContext: OCRContext?
        if frontmostWindowContextEnabled {
            let prefetchedContext = await recordingOCRPrefetch.resolve()
            archivedWindowContext = prefetchedContext?.context
            if activeCleanupAttempted == false {
                activePerformanceTrace?.ocrCaptureDuration = prefetchedContext?.elapsed
            }
        } else {
            archivedWindowContext = nil
        }

        let didProduceTranscript = await processRecordingResult(
            audioBuffer: buffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            archivedWindowContext: archivedWindowContext,
            shouldPaste: true
        )

        if didProduceTranscript {
            overlay.dismiss(ifShowing: .transcribing)
            overlay.dismiss(ifShowing: .cleaningUp)
        } else {
            switch Self.emptyTranscriptionDisposition(forAudioSampleCount: buffer.count) {
            case .cancel:
                overlay.dismiss()
                transcriptionLogger.info("transcription.empty_short_recording", "Empty transcription cancelled after a short recording.")
            case .showNoSoundDetected:
                overlay.show(message: .noSoundDetected)
                transcriptionLogger.warning("transcription.no_sound_detected", "No sound detected for a long recording.")
            }
            completeActivePerformanceTraceIfNeeded()
        }

        status = .ready
        releasePipeline(owner: .liveRecording)
    }

    func finishRecordingForTesting(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        archivedWindowContext: OCRContext?
    ) async {
        _ = await processRecordingResult(
            audioBuffer: audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator,
            archivedWindowContext: archivedWindowContext,
            shouldPaste: false
        )
    }

    private func processRecordingResult(
        audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?,
        archivedWindowContext: OCRContext?,
        shouldPaste: Bool
    ) async -> Bool {
        let transcriptionResult = await transcribedTextForRecording(
            audioBuffer,
            recordingSessionCoordinator: recordingSessionCoordinator
        )

        guard let text = transcriptionResult.rawTranscription else {
            activePerformanceTrace?.transcriptionEndAt = .now
            return false
        }

        activePerformanceTrace?.transcriptionEndAt = .now
        let windowContext = archivedWindowContext
        if cleanupEnabled && canAttemptCleanup {
            activeCleanupAttempted = true
            activePerformanceTrace?.cleanupStartAt = .now
            status = .cleaningUp
            if shouldPaste {
                overlay.show(message: .cleaningUp)
            }
            if frontmostWindowContextEnabled, windowContext == nil {
                ocrLogger.info("capture.missing_context", "No frontmost-window OCR context was captured.")
            }
        }

        let cleanupResult = await cleanedTranscriptionResult(text, windowContext: windowContext)
        let finalText = cleanupResult.text
        activeCleanupAttempted = cleanupResult.attemptedCleanup
        if cleanupResult.attemptedCleanup {
            activePerformanceTrace?.cleanupEndAt = .now
        }

        if shouldPaste {
            let pasteResult = textPaster.paste(text: finalText)
            if pasteResult == .copiedToClipboard {
                showClipboardFallbackMessage()
            }
        }

        return true
    }

    private func transcribedTextForRecording(
        _ audioBuffer: [Float],
        recordingSessionCoordinator: RecordingSessionCoordinator?
    ) async -> RecordingTranscriptionResult {
        if let recordingSessionCoordinator {
            let summary = await recordingSessionCoordinator.finish()

            if summary.usedFallback == false,
               let filteredTranscript = recordingSessionCoordinator.filteredTranscript,
               filteredTranscript.isEmpty == false {
                return RecordingTranscriptionResult(rawTranscription: filteredTranscript)
            }
        }

        return RecordingTranscriptionResult(rawTranscription: await transcribeAudioBuffer(audioBuffer))
    }

    private func transcribeAudioBuffer(_ audioBuffer: [Float]) async -> String? {
        if let transcribeAudioBufferOverride {
            return transcribeAudioBufferOverride(audioBuffer)
        }

        return await transcriber.transcribe(audioBuffer: audioBuffer)
    }

    func cleanedTranscription(_ text: String) async -> String {
        let result = await cleanedTranscriptionResult(text, windowContext: nil)
        return result.text
    }

    private func showClipboardFallbackMessage() {
        overlay.show(message: .clipboardFallback)
        clipboardFallbackDismissTask?.cancel()
        clipboardFallbackDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            self?.overlay.dismiss(ifShowing: .clipboardFallback)
        }
    }

    @ObservationIgnored
    private let settingsController = SettingsWindowController()
    @ObservationIgnored
    private let promptEditorController = PromptEditorController()
    @ObservationIgnored
    private let debugLogWindowController = DebugLogWindowController()

    func showSettings() {
        uiLogger.info("settings_window.open_requested", "Settings window open requested.")
        settingsController.show(appState: self)
    }

    func showPromptEditor() {
        uiLogger.info("prompt_editor.open_requested", "Prompt editor open requested.")
        promptEditorController.show(appState: self)
    }

    func showDebugLog() {
        uiLogger.info("debug_window.open_requested", "Debug log window open requested.")
        debugLogStore.refresh()
        debugLogWindowController.show(debugLogStore: debugLogStore)
    }

    private var shortcutBindings: [ChordAction: KeyChord] {
        [
            .pushToTalk: pushToTalkChord,
            .toggleToTalk: toggleToTalkChord
        ]
    }

    private func persistShortcutBindingsIfNeeded() {
        try? chordBindingStore.setBinding(pushToTalkChord, for: .pushToTalk)
        try? chordBindingStore.setBinding(toggleToTalkChord, for: .toggleToTalk)
    }

    private var canAttemptCleanup: Bool {
        textCleanupManager.isReady
    }

    var shouldLoadLocalCleanupModels: Bool {
        cleanupEnabled
    }

    private func cleanedTranscriptionResult(
        _ text: String,
        windowContext: OCRContext?
    ) async -> CleanupResult {
        if let cleanedTranscriptionResultOverride {
            return await cleanedTranscriptionResultOverride(text, windowContext)
        }

        guard cleanupEnabled else {
            return (text: text, prompt: cleanupPrompt, attemptedCleanup: false, cleanupUsedFallback: false)
        }

        let activeCleanupPrompt: String
        if canAttemptCleanup {
            let promptBuildStart = Date.now
            activeCleanupPrompt = cleanupPromptBuilder.buildPrompt(
                basePrompt: cleanupPrompt,
                windowContext: windowContext,
                preferredTranscriptions: correctionStore.preferredTranscriptions,
                commonlyMisheard: correctionStore.commonlyMisheard,
                includeWindowContext: frontmostWindowContextEnabled
            )
            activePerformanceTrace?.promptBuildDuration = Date.now.timeIntervalSince(promptBuildStart)
        } else {
            activeCleanupPrompt = cleanupPrompt
        }

        let cleanedResult = await textCleaner.cleanWithPerformance(
            text: text,
            prompt: activeCleanupPrompt,
            modelKind: textCleanupManager.selectedCleanupModelKind
        )
        activePerformanceTrace?.modelCallDuration = cleanedResult.performance.modelCallDuration
        activePerformanceTrace?.postProcessDuration = cleanedResult.performance.postProcessDuration
        return (
            text: cleanedResult.text,
            prompt: activeCleanupPrompt,
            attemptedCleanup: canAttemptCleanup,
            cleanupUsedFallback: cleanedResult.usedFallback
        )
    }

    var ocrCustomWords: [String] {
        correctionStore.preferredOCRCustomWords
    }

    private func beginPerformanceTrace() {
        var trace = PerformanceTrace(sessionID: UUID().uuidString)
        trace.hotkeyDetectedAt = .now
        activePerformanceTrace = trace
        activeCleanupAttempted = false
    }

    private func completeActivePerformanceTraceIfNeeded() {
        guard var trace = activePerformanceTrace else {
            return
        }

        if trace.pasteEndAt == nil {
            trace.pasteEndAt = .now
        }

        performanceLogger.notice(
            "dictation.completed",
            "Dictation pipeline completed.",
            fields: trace.fields(
                speechModelID: speechModel,
                cleanupBackend: cleanupBackend,
                cleanupAttempted: activeCleanupAttempted
            )
        )

        activePerformanceTrace = nil
        activeCleanupAttempted = false
        recordingOCRPrefetch.cancel()
    }

    func updateShortcut(_ chord: KeyChord, for action: ChordAction) {
        let previousPushChord = pushToTalkChord
        let previousToggleChord = toggleToTalkChord

        do {
            try chordBindingStore.setBinding(chord, for: action)
            shortcutErrorMessage = nil

            switch action {
            case .pushToTalk:
                pushToTalkChord = chord
            case .toggleToTalk:
                toggleToTalkChord = chord
            }

            hotkeyMonitor.updateBindings(shortcutBindings)
            hotkeyLogger.notice(
                "shortcut.updated",
                "Shortcut updated.",
                fields: ["action": action.rawValue, "displayString": chord.displayString]
            )
        } catch {
            pushToTalkChord = previousPushChord
            toggleToTalkChord = previousToggleChord
            shortcutErrorMessage = "That shortcut is already in use."
            hotkeyLogger.warning(
                "shortcut.update_rejected",
                "Shortcut update rejected because the binding is already in use.",
                fields: ["action": action.rawValue, "displayString": chord.displayString]
            )
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        hotkeyMonitor.setSuspended(isActive)
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        modelLogger.notice("cleanup.toggle_changed", "Cleanup enabled state changed.", fields: ["enabled": String(enabled)])
        Task {
            await refreshCleanupModelState()
        }
    }

    func updateCleanupBackend(_ backend: CleanupBackendOption) {
        cleanupBackend = backend
        modelLogger.notice("cleanup.backend_changed", "Cleanup backend changed.", fields: ["cleanupBackend": backend.rawValue])
        Task {
            await refreshCleanupModelState()
        }
    }

    func prepareForTermination() {
        recordingOCRPrefetch.cancel()
        textCleanupManager.shutdownBackend()
    }

    func acquirePipeline(for owner: PipelineOwner) -> Bool {
        guard pipelineOwner == nil else {
            return false
        }

        pipelineOwner = owner
        return true
    }

    func releasePipeline(owner: PipelineOwner) {
        guard pipelineOwner == owner else {
            return
        }

        pipelineOwner = nil
    }

    private func refreshCleanupModelState() async {
        guard cleanupEnabled else {
            modelLogger.info("cleanup.disabled", "Cleanup disabled; unloading local cleanup models.")
            textCleanupManager.unloadModel()
            return
        }

        let shouldLoadLocalModels = shouldLoadLocalCleanupModels
        modelLogger.info(
            "cleanup.policy",
            "Cleanup backend policy evaluated.",
            fields: [
                "cleanupBackend": cleanupBackend.rawValue,
                "shouldLoadLocalModels": String(shouldLoadLocalModels)
            ]
        )

        if shouldLoadLocalModels {
            await textCleanupManager.loadModel()
        } else {
            textCleanupManager.unloadModel()
        }
    }

    private var currentLogContext: AppLogContext {
        AppLogContext(appSessionID: appSessionID)
            .merged(with: activePerformanceTrace?.logContext ?? .empty)
    }

    @ObservationIgnored
    private lazy var appLogger = logSystem.logger(category: .app) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var hotkeyLogger = logSystem.logger(category: .hotkey) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var permissionsLogger = logSystem.logger(category: .permissions) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var recordingLogger = logSystem.logger(category: .recording) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var transcriptionLogger = logSystem.logger(category: .transcription) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var ocrLogger = logSystem.logger(category: .ocr) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var modelLogger = logSystem.logger(category: .model) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var performanceLogger = logSystem.logger(category: .performance) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    @ObservationIgnored
    private lazy var uiLogger = logSystem.logger(category: .ui) { [weak self] in
        self?.currentLogContext ?? .empty
    }

    func loadSpeechModel(name: String) async {
        await modelManager.loadModel(name: name)
        let nextPresentation = Self.nextSpeechModelPresentation(
            managerState: modelManager.state,
            managerError: modelManager.error,
            currentStatus: status,
            currentErrorMessage: errorMessage
        )
        status = nextPresentation.status
        errorMessage = nextPresentation.errorMessage
    }

    static func nextSpeechModelPresentation(
        managerState: ModelManagerState,
        managerError: Error?,
        currentStatus: AppStatus,
        currentErrorMessage: String?
    ) -> (status: AppStatus, errorMessage: String?) {
        switch managerState {
        case .error:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let preservedErrorMessage = shouldClearSpeechModelError ? nil : currentErrorMessage
            return (
                .error,
                preservedErrorMessage
            )
        case .ready:
            let shouldClearSpeechModelError = currentErrorMessage?.hasPrefix(speechModelErrorPrefix) == true
            let nextStatus: AppStatus = shouldClearSpeechModelError && currentStatus == .error
                ? .ready
                : currentStatus
            return (
                nextStatus,
                shouldClearSpeechModelError ? nil : currentErrorMessage
            )
        case .idle, .loading:
            return (currentStatus, currentErrorMessage)
        }
    }
}
