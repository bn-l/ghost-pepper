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

    private let localBackend: CleanupBackend
    private let correctionStore: CorrectionStore
    var logger: AppLogger?

    static let defaultPrompt = """
    Your job is to clean up transcribed audio. The audio transcription engine can make mistakes and will sometimes transcribe things in a way that is not how they should be written in text.

    Repeat back EVERYTHING the user says.

    Your FIRM RULES are:
    1. Delete filler words like: um, uh, like, you know, basically, literally, sort of, kind of
    2. ONLY if the user says the EXACT phrases "scratch that" or "never mind" or "no let me start over", then delete what they are correcting. Otherwise keep the wording and meaning the same, but correct obvious recognition misses for names, models, commands, files, and jargon when supporting context clearly shows the intended term.
    3. Use the context from the OCR window and other information you are provided about commonly mistranscribed words to inform your transcription.
    4. Fix obvious typographical errors, but do not fix turns of phrase just because they don't sound right to you.
    5. Clean up punctuation. Sentences should be properly punctuated.
    6. The output should appear to be competently and professionally written by a human, as they would normally type it.
    7. If it sounds like the user is trying to manually insert punctuation or spell something, you should honor that request.
    8. You must use the OCR output to check weird phrases.
    9. You may not change the user's word selection, unless you believe that the transcription was in error.
    10. You must reproduce the entire transcript of what the user said.

    CRITICAL: Do NOT delete sentences. Do NOT remove context. Do NOT summarize. If you are unsure whether to keep or delete something, KEEP IT.

    Do not keep an obvious misrecognition just because it was spoken that way.

    <EXAMPLES>
    Input: "So um like the meeting is at 3pm you know on Tuesday"
    Output: So the meeting is at 3pm on Tuesday

    Input: "Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?"
    Output: Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?

    Input: "Hey Becca I have an email. Scratch that, this email is for Pete. Hey Pete, this is my email."
    Output: Hey Pete, this is my email.

    Input: "What is a synonym for whisper?"
    Output: What is a synonym for whisper?

    Input: "It is four twenty five pm"
    Output: It is 4:25PM

    Input: "I've been working on this and I'm stuck. Any ideas?"
    Output: I've been working on this and I'm stuck. Any ideas?
    </EXAMPLES>
    """

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
        _ = modelKind
        return basePrompt
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
