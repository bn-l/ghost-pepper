import Foundation
@preconcurrency import FluidAudio
import Observation
@preconcurrency import WhisperKit

/// Manages local speech model lifecycle: download, load, and readiness state.
@MainActor
@Observable
final class ModelManager {
    private final class FluidAudioManagerBox: @unchecked Sendable {
        let manager: AsrManager

        init(manager: AsrManager) {
            self.manager = manager
        }
    }

    typealias ModelLoadOverride = @MainActor (SpeechModelDescriptor) async throws -> Void
    typealias RetryDelayOverride = @MainActor () async -> Void

    @ObservationIgnored
    private(set) var whisperKit: WhisperKit?
    @ObservationIgnored
    private var fluidAudioManager: FluidAudioManagerBox?
    @ObservationIgnored
    private var sortformerModels: SortformerModels?

    private(set) var state: ModelManagerState = .idle
    private(set) var downloadProgress: Double?
    private(set) var modelName: String
    private(set) var error: Error?

    var logger: AppLogger?

    var isReady: Bool {
        state == .ready
    }

    static let availableModels = SpeechModelCatalog.availableModels
    private static let retryDelayDuration: Duration = .milliseconds(500)

    var cachedModelNames: Set<String> {
        Self.availableModels.reduce(into: Set<String>()) { names, model in
            if Self.modelIsCached(model) {
                names.insert(model.name)
            }
        }
    }

    private let modelLoadOverride: ModelLoadOverride?
    private let loadRetryDelayOverride: RetryDelayOverride?

    init(
        modelName: String = SpeechModelCatalog.defaultModelID,
        modelLoadOverride: ModelLoadOverride? = nil,
        loadRetryDelayOverride: RetryDelayOverride? = nil
    ) {
        self.modelName = modelName
        self.modelLoadOverride = modelLoadOverride
        self.loadRetryDelayOverride = loadRetryDelayOverride
    }

    func loadModel(name: String? = nil) async {
        let requestedName = name ?? modelName
        guard let requestedModel = SpeechModelCatalog.model(named: requestedName) else {
            let missingModelError = NSError(
                domain: "GhostPepper.ModelManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unknown speech model \(requestedName)"]
            )
            error = missingModelError
            state = .error
            return
        }

        if requestedName != modelName && state == .ready {
            resetLoadedModels()
        } else if state == .ready {
            return
        }
        modelName = requestedName

        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil
        logger?.info("speech.load_started", "Loading speech model.", fields: ["modelName": modelName])

        do {
            do {
                try await loadRequestedModel(requestedModel)
            } catch {
                guard Self.isRetryableLoadError(error) else {
                    throw error
                }

                logger?.warning("speech.load_retry", "Speech model load timed out. Retrying once.", fields: ["modelName": modelName], error: error)
                clearLoadedModelInstances()
                await retryLoadDelay()
                try await loadRequestedModel(requestedModel)
            }
            self.state = .ready
            logger?.notice("speech.load_succeeded", "Speech model loaded successfully.", fields: ["modelName": modelName])
        } catch {
            self.error = error
            self.state = .error
            logger?.error("speech.load_failed", "Speech model failed to load.", fields: ["modelName": modelName], error: error)
        }
    }

    private func loadRequestedModel(_ requestedModel: SpeechModelDescriptor) async throws {
        if let modelLoadOverride {
            try await modelLoadOverride(requestedModel)
            return
        }

        switch requestedModel.backend {
        case .whisperKit:
            try await loadWhisperModel(named: requestedModel.name)
        case .fluidAudio:
            try await loadFluidAudioModel(requestedModel)
        }
    }

    func transcribe(audioBuffer: [Float]) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }
        guard let model = SpeechModelCatalog.model(named: modelName) else { return nil }

        do {
            switch model.backend {
            case .whisperKit:
                guard let whisperKit else { return nil }
                let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioBuffer)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = SpeechTranscriber.removeArtifacts(from: text)
                return cleaned.isEmpty ? nil : cleaned
            case .fluidAudio:
                guard let fluidAudioManager else { return nil }
                let cleaned = try await Self.transcribeWithFluidAudioManager(fluidAudioManager, audioBuffer: audioBuffer)
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {
            logger?.warning("speech.transcription_failed", "Speech transcription failed.", fields: ["modelName": modelName], error: error)
            return nil
        }
    }

    func makeRecordingSessionCoordinator() async -> RecordingSessionCoordinator? {
        guard let model = SpeechModelCatalog.model(named: modelName),
              model.supportsSpeakerFiltering,
              fluidAudioManager != nil else {
            return nil
        }

        do {
            let diarizerModels = try await loadSortformerModels()
            let diarizer = SortformerDiarizer()
            diarizer.initialize(models: diarizerModels)
            let session = FluidAudioSpeechSession { [weak self] audioBuffer in
                await self?.transcribe(audioBuffer: audioBuffer)
            }

            return RecordingSessionCoordinator(
                session: session,
                processAudioChunk: { samples in
                    do {
                        _ = try diarizer.processSamples(samples)
                    } catch {
                        self.logger?.warning("speaker_filter.chunk_failed", "Speaker filtering diarization chunk failed.", error: error)
                    }
                },
                finish: {
                    diarizer.timeline.finalize()
                    return Self.diarizationSpans(from: diarizer.timeline.segments)
                },
                cleanup: {
                    diarizer.cleanup()
                }
            )
        } catch {
            logger?.warning("speaker_filter.load_failed", "Speaker filtering diarizer failed to load.", error: error)
            return nil
        }
    }

    private func loadWhisperModel(named modelName: String) async throws {
        let modelsDir = Self.whisperModelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let needsDownload = !Self.modelIsCached(SpeechModelCatalog.model(named: modelName)!)
        if needsDownload {
            let progressHandler: @Sendable (Progress) -> Void = { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: modelsDir,
                progressCallback: progressHandler
            )
            downloadProgress = nil
        }

        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
    }

    nonisolated
    private static func transcribeWithFluidAudioManager(
        _ managerBox: FluidAudioManagerBox,
        audioBuffer: [Float]
    ) async throws -> String {
        let result = try await managerBox.manager.transcribe(audioBuffer, source: .microphone)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadFluidAudioModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let version: AsrModelVersion
        switch fluidAudioVariant {
        case .parakeetV3:
            version = .v3
        }

        let models = try await AsrModels.downloadAndLoad(version: version) { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        downloadProgress = nil
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        fluidAudioManager = FluidAudioManagerBox(manager: manager)
    }

    private func resetLoadedModels() {
        clearLoadedModelInstances()
        state = .idle
    }

    private func clearLoadedModelInstances() {
        whisperKit = nil
        fluidAudioManager = nil
        sortformerModels = nil
        downloadProgress = nil
    }

    private func retryLoadDelay() async {
        if let loadRetryDelayOverride {
            await loadRetryDelayOverride()
            return
        }

        try? await Task.sleep(for: Self.retryDelayDuration)
    }

    private func loadSortformerModels() async throws -> SortformerModels {
        if let sortformerModels {
            return sortformerModels
        }

        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        sortformerModels = models
        return models
    }

    private static func diarizationSpans(from segmentsBySpeaker: [[SortformerSegment]]) -> [DiarizationSummary.Span] {
        segmentsBySpeaker
            .enumerated()
            .flatMap { speakerIndex, segments in
                segments.map { segment in
                    DiarizationSummary.Span(
                        speakerID: "Speaker \(speakerIndex)",
                        startTime: TimeInterval(segment.startTime),
                        endTime: TimeInterval(segment.endTime)
                    )
                }
            }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private static func isRetryableLoadError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("timed out") {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isRetryableLoadError(underlyingError) {
            return true
        }

        return false
    }

    private static func modelIsCached(_ model: SpeechModelDescriptor) -> Bool {
        switch model.backend {
        case .whisperKit:
            let modelPath = model.cachePathComponents.reduce(whisperModelsRootDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: true)
            }
            return FileManager.default.fileExists(atPath: modelPath.path)
        case .fluidAudio:
            guard let fluidAudioVariant = model.fluidAudioVariant else {
                return false
            }
            switch fluidAudioVariant {
            case .parakeetV3:
                return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            }
        }
    }

    private static var whisperModelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/whisper-models", isDirectory: true)
    }

    private static var whisperModelsRootDirectory: URL {
        whisperModelsDirectory.appendingPathComponent("models", isDirectory: true)
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
