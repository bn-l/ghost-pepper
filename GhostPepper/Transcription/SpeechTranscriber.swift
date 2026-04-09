import Foundation

/// Transcribes audio buffers using the currently selected speech backend.
///
/// Serializes transcription requests so only one runs at a time.
actor SpeechTranscriber {
    private let modelManager: ModelManager

    /// Whether the underlying model is ready for transcription.
    @MainActor
    var isReady: Bool {
        modelManager.isReady
    }

    /// Whisper artifacts to filter out of transcription results.
    private static let artifacts: Set<String> = [
        "[BLANK_AUDIO]",
        "[NO_SPEECH]",
        "(blank audio)",
        "(no speech)",
        "[MUSIC]",
        "(music)",
        "[APPLAUSE]",
        "(applause)",
        "[LAUGHTER]",
        "(laughter)",
    ]

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Removes Whisper hallucination artifacts like [BLANK_AUDIO] from text.
    static func removeArtifacts(from text: String) -> String {
        var cleaned = text
        for artifact in artifacts {
            cleaned = cleaned.replacingOccurrences(
                of: artifact,
                with: "",
                options: [.caseInsensitive, .literal]
            )
        }

        return cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Transcribes a 16 kHz mono PCM float audio buffer into text.
    ///
    /// - Parameter audioBuffer: Array of Float samples at 16 kHz sample rate, mono.
    /// - Returns: The transcribed text, or nil if the buffer is empty,
    ///   the model is not ready, or transcription produced no output.
    func transcribe(audioBuffer: [Float]) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }
        return await modelManager.transcribe(audioBuffer: audioBuffer)
    }
}
