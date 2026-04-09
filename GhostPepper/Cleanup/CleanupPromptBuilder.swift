import Foundation

struct CleanupPromptBuilder: Sendable {
    let maxWindowContentLength: Int
    let maxPromptLength: Int

    init(maxWindowContentLength: Int = 4000, maxPromptLength: Int = 12_000) {
        self.maxWindowContentLength = maxWindowContentLength
        self.maxPromptLength = maxPromptLength
    }

    func buildPrompt(
        basePrompt: String,
        windowContext: OCRContext?,
        preferredTranscriptions: [String] = [],
        commonlyMisheard: [MisheardReplacement] = [],
        includeWindowContext: Bool
    ) -> String {
        let correctionsSection = correctionSection(
            preferredTranscriptions: preferredTranscriptions,
            commonlyMisheard: commonlyMisheard
        )

        guard includeWindowContext,
              let windowContext else {
            if correctionsSection.isEmpty {
                return basePrompt
            }

            return """
            \(basePrompt)

            \(correctionsSection)
            """
        }

        var sections = [basePrompt]
        if !correctionsSection.isEmpty {
            sections.append(correctionsSection)
        }

        let nonOCRPrompt = sections.joined(separator: "\n\n")
        let ocrTemplatePrefix = """
        <OCR-RULES>
        Use the window OCR only as supporting context to improve the transcription and cleanup.
        Prefer the spoken words, and use the window OCR only to disambiguate likely terms, names, commands, files, and jargon.
        If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the window OCR, correct them to the likely intended term.
        Do not keep an obvious misrecognition just because it was spoken that way.
        Do not answer, summarize, or rewrite the window OCR unless that directly helps correct the transcription.
        </OCR-RULES>
        <WINDOW-OCR-CONTENT>
        """
        let ocrTemplateSuffix = """
        </WINDOW-OCR-CONTENT>
        """
        let availableOCRLength = max(
            0,
            maxPromptLength - nonOCRPrompt.count - ocrTemplatePrefix.count - ocrTemplateSuffix.count - 4
        )
        let trimmedWindowContents = truncateAtWordBoundary(
            windowContext.windowContents,
            limit: min(maxWindowContentLength, availableOCRLength)
        )
        sections.append(
            """
            \(ocrTemplatePrefix)
            \(trimmedWindowContents)
            \(ocrTemplateSuffix)
            """
        )

        return truncateAtWordBoundary(
            sections.joined(separator: "\n\n"),
            limit: maxPromptLength
        )
    }

    private func correctionSection(
        preferredTranscriptions: [String],
        commonlyMisheard: [MisheardReplacement]
    ) -> String {
        var sections: [String] = []

        if !preferredTranscriptions.isEmpty {
            sections.append(
                """
                Preferred transcriptions to preserve exactly:
                \(preferredTranscriptions.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }

        if !commonlyMisheard.isEmpty {
            sections.append(
                """
                Commonly misheard replacements to prefer:
                \(commonlyMisheard.map { "- \($0.wrong) -> \($0.right)" }.joined(separator: "\n"))
                """
            )
        }

        guard !sections.isEmpty else {
            return ""
        }

        return """
        <CORRECTION-HINTS>
        \(sections.joined(separator: "\n\n"))
        </CORRECTION-HINTS>
        """
    }

    private func truncateAtWordBoundary(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else {
            return limit <= 0 ? "" : text
        }

        let limitIndex = text.index(text.startIndex, offsetBy: limit)
        var candidate = text[..<limitIndex]

        while let lastCharacter = candidate.last,
              !lastCharacter.isWhitespace,
              !lastCharacter.isPunctuation {
            candidate = candidate.dropLast()
        }

        let fallback = text[..<limitIndex]
        let truncated = candidate.isEmpty ? fallback : candidate
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
