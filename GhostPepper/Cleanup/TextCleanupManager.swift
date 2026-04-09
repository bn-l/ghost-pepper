import Foundation
@preconcurrency import LLM
import Observation

private extension CleanupModelProbeThinkingMode {
    var llmThinkingMode: ThinkingMode {
        switch self {
        case .none:
            return .none
        case .suppressed:
            return .suppressed
        case .enabled:
            return .enabled
        }
    }
}

enum CleanupModelState: Equatable {
    case idle
    case downloading(kind: LocalCleanupModelKind, progress: Double)
    case loadingModel
    case ready
    case error
}

@MainActor
protocol TextCleaningManaging: AnyObject {
    func clean(text: String, prompt: String?, modelKind: LocalCleanupModelKind?) async throws -> String
}

typealias CleanupModelProbeExecutionOverride = @MainActor (
    _ text: String,
    _ prompt: String,
    _ modelKind: LocalCleanupModelKind,
    _ thinkingMode: CleanupModelProbeThinkingMode
) async throws -> CleanupModelProbeRawResult

enum CleanupModelRecommendation: Equatable {
    case veryFast
    case fast
    case full

    var label: String {
        switch self {
        case .veryFast:
            return "Very fast"
        case .fast:
            return "Fast"
        case .full:
            return "Full"
        }
    }
}

enum LocalCleanupModelKind: String, CaseIterable, Equatable, Identifiable {
    case qwen35_0_8b_q4_k_m
    case qwen35_2b_q4_k_m
    case qwen35_4b_q4_k_m

    var id: String { rawValue }

    static var fast: LocalCleanupModelKind { .qwen35_2b_q4_k_m }
    static var full: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
}

struct CleanupModelDescriptor: Equatable {
    let kind: LocalCleanupModelKind
    let displayName: String
    let sizeDescription: String
    let fileName: String
    let url: String
    let maxTokenCount: Int32
    let recommendation: CleanupModelRecommendation?
}

private final class LoadedLLMBox: @unchecked Sendable {
    let llm: LLM

    init(_ llm: LLM) {
        self.llm = llm
    }
}

private enum CleanupModelLoader {
    static func load(
        from path: URL,
        maxTokenCount: Int32,
        systemPrompt: String
    ) async -> LoadedLLMBox? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let llm = LLM(from: path, maxTokenCount: maxTokenCount) else {
                    continuation.resume(returning: nil)
                    return
                }

                llm.useResolvedTemplate(systemPrompt: systemPrompt)
                continuation.resume(returning: LoadedLLMBox(llm))
            }
        }
    }
}

actor CleanupProbeExecutionGate {
    private static let maxQueuedWaiters = 4
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async throws {
        if !isRunning {
            isRunning = true
            return
        }

        if waiters.count >= Self.maxQueuedWaiters {
            throw CleanupModelProbeError.queueSaturated
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isRunning = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func withGate<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }
}

@MainActor
@Observable
final class TextCleanupManager: TextCleaningManaging {
    private(set) var state: CleanupModelState = .idle {
        didSet {
            guard oldValue == .loadingModel,
                  state != .loadingModel else {
                return
            }

            let waiters = activeLoadWaiters
            activeLoadWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    private(set) var errorMessage: String?
    var selectedCleanupModelKind: LocalCleanupModelKind {
        didSet {
            defaults.set(selectedCleanupModelKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
        }
    }

    var logger: AppLogger?

    private(set) var activeLLM: LLM?
    private(set) var activeLoadedModelKind: LocalCleanupModelKind?

    static let compactModel = CleanupModelDescriptor(
        kind: .qwen35_0_8b_q4_k_m,
        displayName: "Qwen 3.5 0.8B Q4_K_M (Very fast)",
        sizeDescription: "~535 MB",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
        maxTokenCount: 2048,
        recommendation: .veryFast
    )

    static let recommendedFastModel = CleanupModelDescriptor(
        kind: .qwen35_2b_q4_k_m,
        displayName: "Qwen 3.5 2B Q4_K_M (Fast)",
        sizeDescription: "~1.3 GB",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
        maxTokenCount: 2048,
        recommendation: .fast
    )

    static let recommendedFullModel = CleanupModelDescriptor(
        kind: .qwen35_4b_q4_k_m,
        displayName: "Qwen 3.5 4B Q4_K_M (Full)",
        sizeDescription: "~2.8 GB",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
        maxTokenCount: 4096,
        recommendation: .full
    )

    static let cleanupModels = [
        compactModel,
        recommendedFastModel,
        recommendedFullModel,
    ]
    static let fastModel = recommendedFastModel
    static let fullModel = recommendedFullModel

    static func cleanupModelKind(matchingArchivedName archivedName: String) -> LocalCleanupModelKind {
        if let exactMatch = cleanupModels.first(where: { $0.displayName == archivedName }) {
            return exactMatch.kind
        }

        if archivedName.contains("0.8B") {
            return .qwen35_0_8b_q4_k_m
        }

        if archivedName.contains("2B") || archivedName.contains("1.7B") {
            return .qwen35_2b_q4_k_m
        }

        return .qwen35_4b_q4_k_m
    }

    var isReady: Bool { state == .ready }
    var selectedCleanupModelDisplayName: String {
        descriptor(for: selectedCleanupModelKind)?.displayName ?? selectedCleanupModelKind.rawValue
    }

    var hasUsableModelForCurrentPolicy: Bool {
        isModelAvailable(selectedCleanupModelKind)
    }

    private static let selectedCleanupModelDefaultsKey = "selectedCleanupModelKind"

    private let defaults: UserDefaults
    private let probeTimeoutSeconds: TimeInterval
    private let cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool]
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?
    private let probeExecutionGate = CleanupProbeExecutionGate()
    private var activeLoadWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        defaults: UserDefaults = .standard,
        selectedCleanupModelKind: LocalCleanupModelKind? = nil,
        probeTimeoutSeconds: TimeInterval = 30.0,
        cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool] = [:],
        probeExecutionOverride: CleanupModelProbeExecutionOverride? = nil,
        backendShutdownOverride: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.cleanupModelAvailabilityOverrides = cleanupModelAvailabilityOverrides
        self.probeExecutionOverride = probeExecutionOverride
        self.backendShutdownOverride = backendShutdownOverride

        let storedKind = LocalCleanupModelKind(
            rawValue: defaults.string(forKey: Self.selectedCleanupModelDefaultsKey) ?? ""
        ) ?? .qwen35_0_8b_q4_k_m
        let initialKind = selectedCleanupModelKind ?? storedKind
        self.selectedCleanupModelKind = initialKind
        defaults.set(initialKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
    }

    func selectedModelKind(wordCount: Int, isQuestion: Bool) -> LocalCleanupModelKind? {
        isModelAvailable(selectedCleanupModelKind) ? selectedCleanupModelKind : nil
    }

    var statusText: String {
        switch state {
        case .idle:
            return ""
        case .downloading(_, let progress):
            let pct = Int(progress * 100)
            return "Downloading cleanup models (\(pct)%)..."
        case .loadingModel:
            return "Loading cleanup models..."
        case .ready:
            return ""
        case .error:
            return errorMessage ?? "Cleanup model error"
        }
    }

    private var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    private func modelPath(for fileName: String) -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    func clean(text: String, prompt: String? = nil, modelKind: LocalCleanupModelKind? = nil) async throws -> String {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)

        guard probeExecutionOverride != nil || model(for: requestedModelKind) != nil else {
            logger?.info(
                "cleanup.skipped_model_not_ready",
                "Skipped local cleanup because the requested model was not ready.",
                fields: ["modelKind": requestedModelKind.rawValue]
            )
            throw CleanupBackendError.unavailable
        }

        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        do {
            let result = try await probe(
                text: text,
                prompt: activePrompt,
                modelKind: requestedModelKind,
                thinkingMode: .suppressed
            )
            let cleaned = result.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "..." {
                logger?.warning(
                    "cleanup.unusable_output",
                    "Discarded local cleanup output because it was unusable.",
                    fields: ["modelDisplayName": descriptor(for: requestedModelKind)?.displayName ?? requestedModelKind.rawValue]
                )
                throw CleanupBackendError.unusableOutput(rawOutput: result.rawOutput)
            }
            return cleaned
        } catch let error as CleanupBackendError {
            throw error
        } catch let error as CleanupModelProbeError {
            switch error {
            case .modelUnavailable:
                throw CleanupBackendError.unavailable
            case .queueSaturated, .timedOut, .cancelled:
                logger?.warning("cleanup.probe_unavailable", "Cleanup probe did not complete successfully.", error: error)
                throw CleanupBackendError.unavailable
            }
        } catch {
            logger?.warning("cleanup.probe_failed", "Local cleanup probe failed before producing usable output.", error: error)
            throw CleanupBackendError.unavailable
        }
    }

    func probe(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async throws -> CleanupModelProbeRawResult {
        try await probeExecutionGate.withGate {
            if let probeExecutionOverride = self.probeExecutionOverride {
                return try await self.withTimeout(seconds: self.probeTimeoutSeconds) {
                    try await probeExecutionOverride(text, prompt, modelKind, thinkingMode)
                }
            }

            guard let llm = self.model(for: modelKind) else {
                self.logger?.info(
                    "cleanup.probe_skipped_model_not_ready",
                    "Skipped local cleanup probe because the model was not ready.",
                    fields: ["modelKind": modelKind.rawValue]
                )
                throw CleanupModelProbeError.modelUnavailable(modelKind)
            }

            llm.useResolvedTemplate(systemPrompt: prompt)
            llm.history = []

            let start = Date.now
            do {
                let rawOutput = try await self.withTimeout(seconds: self.probeTimeoutSeconds) {
                    await llm.respond(to: text, thinking: thinkingMode.llmThinkingMode)
                    return llm.output
                }
                let elapsed = Date.now.timeIntervalSince(start)
                self.logger?.notice(
                    "cleanup.probe_finished",
                    "Local cleanup finished.",
                    fields: [
                        "elapsedMS": String(Int((elapsed * 1000).rounded())),
                        "modelDisplayName": self.descriptor(for: modelKind)?.displayName ?? modelKind.rawValue
                    ]
                )
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: self.descriptor(for: modelKind)?.displayName ?? modelKind.rawValue,
                    rawOutput: rawOutput,
                    elapsed: elapsed
                )
            } catch {
                let elapsed = Date.now.timeIntervalSince(start)
                self.logger?.warning(
                    "cleanup.probe_failed_with_timing",
                    "Local cleanup failed.",
                    fields: ["elapsedMS": String(Int((elapsed * 1000).rounded()))],
                    error: error
                )
                throw error
            }
        }
    }

    func loadModel() async {
        await loadModel(kind: selectedCleanupModelKind)
    }

    func downloadMissingModels() async {
        guard state == .idle || state == .error || state == .ready else { return }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        for descriptor in Self.cleanupModels {
            let path = modelPath(for: descriptor.fileName)
            guard !FileManager.default.fileExists(atPath: path.path) else {
                continue
            }

            do {
                try await downloadModel(kind: descriptor.kind, url: descriptor.url, to: path)
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                logger?.error("model.download_failed", self.errorMessage ?? "Failed to download cleanup model.", error: error)
                return
            }
        }

        state = .idle
        await loadModel()
    }

    func loadModel(kind: LocalCleanupModelKind) async {
        if activeLoadedModelKind == kind && (activeLLM != nil || probeExecutionOverride != nil) {
            state = .ready
            errorMessage = nil
            return
        }

        if state == .loadingModel {
            await waitForActiveLoad()
            if activeLoadedModelKind == kind && (activeLLM != nil || probeExecutionOverride != nil) {
                state = .ready
                errorMessage = nil
                return
            }
        }

        guard state == .idle || state == .error || state == .ready else { return }

        if let override = availabilityOverride(for: kind), !override {
            errorMessage = "Failed to load the selected cleanup model."
            state = .error
            return
        }

        if probeExecutionOverride != nil {
            activeLLM = nil
            activeLoadedModelKind = kind
            state = .ready
            errorMessage = nil
            return
        }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        guard let descriptor = descriptor(for: kind) else {
            errorMessage = "Unknown cleanup model."
            state = .error
            logger?.error("model.unknown", "Attempted to load an unknown cleanup model.", fields: ["modelKind": kind.rawValue])
            return
        }
        let path = modelPath(for: descriptor.fileName)
        logger?.info("model.load_started", "Loading local cleanup model.", fields: ["modelDisplayName": descriptor.displayName])

        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try await downloadModel(kind: kind, url: descriptor.url, to: path)
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                logger?.error("model.download_failed", self.errorMessage ?? "Failed to download cleanup model.", error: error)
                return
            }
        }

        state = .loadingModel
        activeLLM = nil
        activeLoadedModelKind = nil

        let loadedModelBox = await CleanupModelLoader.load(
            from: path,
            maxTokenCount: descriptor.maxTokenCount,
            systemPrompt: TextCleaner.defaultPrompt
        )

        guard let loadedModel = loadedModelBox?.llm else {
            errorMessage = "Failed to load the selected cleanup model."
            state = .error
            logger?.warning("model.unavailable", "Local cleanup model unavailable.", fields: ["modelDisplayName": descriptor.displayName])
            return
        }

        loadedModel.temp = 0.1
        loadedModel.update = { (_: String?) in }
        loadedModel.postprocess = { (_: String) in }
        activeLLM = loadedModel
        activeLoadedModelKind = kind
        state = .ready
        errorMessage = nil
        logger?.notice("model.ready", "Local cleanup model ready.", fields: ["modelDisplayName": descriptor.displayName])
    }

    func unloadModel() {
        activeLLM = nil
        activeLoadedModelKind = nil
        state = .idle
        errorMessage = nil
        logger?.info("model.unloaded", "Unloaded local cleanup models.")
    }

    func shutdownBackend() {
        unloadModel()
        if let backendShutdownOverride {
            backendShutdownOverride()
        } else {
            LLM.shutdownBackend()
        }
        logger?.info("model.backend_shutdown", "Shutdown llama backend.")
    }

    var cachedModelKinds: Set<LocalCleanupModelKind> {
        Set(Self.cleanupModels.compactMap { descriptor in
            if let override = availabilityOverride(for: descriptor.kind) {
                return override ? descriptor.kind : nil
            }

            return FileManager.default.fileExists(atPath: modelPath(for: descriptor.fileName).path)
                ? descriptor.kind
                : nil
        })
    }

    private func downloadModel(kind: LocalCleanupModelKind, url urlString: String, to destination: URL) async throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        state = .downloading(kind: kind, progress: 0)

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(kind: kind, progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    private func model(for modelKind: LocalCleanupModelKind) -> LLM? {
        activeLoadedModelKind == modelKind ? activeLLM : nil
    }

    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor? {
        Self.cleanupModels.first(where: { $0.kind == modelKind })
    }

    private func availabilityOverride(for modelKind: LocalCleanupModelKind) -> Bool? {
        guard !cleanupModelAvailabilityOverrides.isEmpty else {
            return nil
        }

        return cleanupModelAvailabilityOverrides[modelKind] ?? false
    }

    private func waitForActiveLoad() async {
        guard state == .loadingModel else {
            return
        }

        await withCheckedContinuation { continuation in
            activeLoadWaiters.append(continuation)
        }
    }

    private enum TimedResult<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await withThrowingTaskGroup(of: TimedResult<T>.self) { group in
                group.addTask {
                    .value(try await operation())
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    return .timedOut
                }

                guard let result = try await group.next() else {
                    throw CleanupModelProbeError.cancelled
                }

                group.cancelAll()

                switch result {
                case .value(let value):
                    return value
                case .timedOut:
                    throw CleanupModelProbeError.timedOut(seconds)
                }
            }
        } catch is CancellationError {
            throw CleanupModelProbeError.cancelled
        }
    }

    private func isModelAvailable(_ modelKind: LocalCleanupModelKind) -> Bool {
        if let override = availabilityOverride(for: modelKind) {
            return override
        }

        if activeLoadedModelKind == modelKind && activeLLM != nil {
            return true
        }

        guard let descriptor = descriptor(for: modelKind) else {
            return false
        }

        return FileManager.default.fileExists(atPath: modelPath(for: descriptor.fileName).path)
    }
}

// MARK: - Download Progress

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call
    }
}
