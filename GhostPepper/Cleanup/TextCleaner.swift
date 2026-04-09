import Foundation

struct TextCleanerPerformance {
    let modelCallDuration: TimeInterval?
    let postProcessDuration: TimeInterval?
}

struct TextCleanerTranscript: Equatable {
    let prompt: String
    let inputText: String
    let rawOutput: String
}

struct TextCleanerResult {
    let text: String
    let performance: TextCleanerPerformance
    let transcript: TextCleanerTranscript?
    let usedFallback: Bool

    init(
        text: String,
        performance: TextCleanerPerformance,
        transcript: TextCleanerTranscript? = nil,
        usedFallback: Bool = false
    ) {
        self.text = text
        self.performance = performance
        self.transcript = transcript
        self.usedFallback = usedFallback
    }
}

final class TextCleaner {
    nonisolated(unsafe) private static let thinkBlockExpression = #/(?is)<think\b[^>]*>.*?<\/think>/#
    nonisolated(unsafe) private static let leadingThinkTagExpression = #/(?is)^\s*<think\b[^>]*>/#
    private static let promptCharacterLimitByModel: [LocalCleanupModelKind: Int] = [
        .qwen35_0_8b_q4_k_m: 700,
        .qwen35_2b_q4_k_m: 1_200,
        .qwen35_4b_q4_k_m: 2_000,
    ]

    private let localBackend: CleanupBackend
    private let correctionStore: CorrectionStore
    var logger: AppLogger?

    static let defaultPrompt = """
    Clean up a speech transcription for direct use as typed text.

    Rules:
    1. Keep the full meaning and include everything the speaker intended to say.
    2. Remove filler words such as um, uh, like, you know, basically, literally, sort of, and kind of when they are obvious fillers.
    3. Only delete corrected text when the speaker explicitly restarts with phrases like "scratch that", "never mind", or "no let me start over".
    4. Fix obvious transcription mistakes for names, commands, files, models, and jargon when context clearly supports the correction.
    5. Clean up punctuation, capitalization, spacing, and obvious typos.
    6. If the speaker is intentionally spelling something or dictating punctuation, keep that intent.
    7. Do not summarize, answer, add commentary, or omit real content. If unsure, keep it.

    Examples:
    Input: "So um like the meeting is at 3pm you know on Tuesday"
    Output: So the meeting is at 3pm on Tuesday

    Input: "Hey Becca I have an email. Scratch that, this email is for Pete. Hey Pete, this is my email."
    Output: Hey Pete, this is my email.
    """

    @MainActor
    init(
        localBackend: CleanupBackend,
        correctionStore: CorrectionStore = CorrectionStore()
    ) {
        self.localBackend = localBackend
        self.correctionStore = correctionStore
    }

    @MainActor
    convenience init(
        cleanupManager: TextCleaningManaging,
        correctionStore: CorrectionStore = CorrectionStore()
    ) {
        self.init(
            localBackend: LocalLLMCleanupBackend(cleanupManager: cleanupManager),
            correctionStore: correctionStore
        )
    }

    @MainActor
    func clean(text: String, prompt: String? = nil) async -> String {
        let result = await cleanWithPerformance(text: text, prompt: prompt)
        return result.text
    }

    @MainActor
    func cleanWithPerformance(
        text: String,
        prompt: String? = nil,
        modelKind: LocalCleanupModelKind? = nil
    ) async -> TextCleanerResult {
        let basePrompt = prompt ?? Self.defaultPrompt
        let activePrompt = Self.effectivePrompt(
            basePrompt: basePrompt,
            modelKind: modelKind
        )
        let correctionEngine = DeterministicCorrectionEngine(
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard
        )
        let correctedText = correctionEngine.applyPreCleanupCorrections(to: text)
        let formattedInput = Self.formatCleanupInput(userInput: correctedText)
        if correctedText != text {
            logger?.info("deterministic.pre_cleanup_applied", "Applied deterministic corrections before local cleanup.")
        }

        let modelCallStart = Date.now
        do {
            let cleanedText = try await localBackend.clean(
                text: formattedInput,
                prompt: activePrompt,
                modelKind: modelKind
            )
            let modelCallDuration = Date.now.timeIntervalSince(modelCallStart)
            let postProcessStart = Date.now
            let sanitizedText = Self.sanitizeCleanupOutput(cleanedText)

            if sanitizedText != cleanedText {
                logger?.info("sanitize.reasoning_tags_removed", "Stripped model reasoning tags from cleanup output.")
            }

            let finalText = correctionEngine.applyPostCleanupCorrections(to: sanitizedText)
            if finalText != sanitizedText {
                logger?.info("deterministic.post_cleanup_applied", "Applied deterministic corrections after local cleanup.")
            }
            return TextCleanerResult(
                text: finalText,
                performance: TextCleanerPerformance(
                    modelCallDuration: modelCallDuration,
                    postProcessDuration: Date.now.timeIntervalSince(postProcessStart)
                ),
                transcript: TextCleanerTranscript(
                    prompt: activePrompt,
                    inputText: formattedInput,
                    rawOutput: cleanedText
                ),
                usedFallback: false
            )
        } catch let error as CleanupBackendError {
            let postProcessStart = Date.now
            let finalText = correctionEngine.applyPostCleanupCorrections(to: correctedText)
            let postProcessDuration = Date.now.timeIntervalSince(postProcessStart)

            switch error {
            case .unavailable:
                logger?.warning("backend.unavailable", "Cleanup backend unavailable, returning deterministic corrections only.")
                if finalText != correctedText {
                    logger?.info("deterministic.fallback_applied", "Applied deterministic corrections without a cleanup model.")
                }
                return TextCleanerResult(
                    text: finalText,
                    performance: TextCleanerPerformance(
                        modelCallDuration: nil,
                        postProcessDuration: postProcessDuration
                    ),
                    usedFallback: true
                )
            case .unusableOutput(let rawOutput):
                let modelCallDuration = Date.now.timeIntervalSince(modelCallStart)
                logger?.warning("backend.unusable_output", "Cleanup model returned unusable output, falling back to deterministic corrections.")
                if finalText != correctedText {
                    logger?.info("deterministic.unusable_output_applied", "Applied deterministic corrections after unusable cleanup output.")
                }
                return TextCleanerResult(
                    text: finalText,
                    performance: TextCleanerPerformance(
                        modelCallDuration: modelCallDuration,
                        postProcessDuration: postProcessDuration
                    ),
                    transcript: TextCleanerTranscript(
                        prompt: activePrompt,
                        inputText: formattedInput,
                        rawOutput: rawOutput
                    ),
                    usedFallback: true
                )
            }
        } catch {
            logger?.warning("backend.failed", "Cleanup backend unavailable, returning deterministic corrections only.", error: error)
            let postProcessStart = Date.now
            let finalText = correctionEngine.applyPostCleanupCorrections(to: correctedText)
            if finalText != correctedText {
                logger?.info("deterministic.unexpected_failure_applied", "Applied deterministic corrections after unexpected cleanup failure.")
            }
            return TextCleanerResult(
                text: finalText,
                performance: TextCleanerPerformance(
                    modelCallDuration: nil,
                    postProcessDuration: Date.now.timeIntervalSince(postProcessStart)
                ),
                usedFallback: true
            )
        }
    }

    static func effectivePrompt(
        basePrompt: String,
        modelKind: LocalCleanupModelKind?
    ) -> String {
        guard let modelKind,
              let characterLimit = promptCharacterLimitByModel[modelKind],
              basePrompt.count > characterLimit else {
            return basePrompt
        }

        let truncatedPrompt = String(basePrompt.prefix(characterLimit))
        if let boundary = truncatedPrompt.lastIndex(where: \.isWhitespace),
           boundary > truncatedPrompt.startIndex {
            return String(truncatedPrompt[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return truncatedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeCleanupOutput(_ text: String) -> String {
        var sanitizedText = text

        sanitizedText = sanitizedText.replacing(Self.thinkBlockExpression, with: "")
        if let match = sanitizedText.firstMatch(of: Self.leadingThinkTagExpression) {
            sanitizedText = String(sanitizedText[..<match.range.lowerBound])
        }

        return sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatCleanupInput(userInput: String) -> String {
        """
        <USER-INPUT>
        \(userInput)
        </USER-INPUT>
        """
    }
}
