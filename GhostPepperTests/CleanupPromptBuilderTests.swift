import XCTest
@testable import GhostPepper

final class CleanupPromptBuilderTests: XCTestCase {
    func testDefaultPromptUsesPersonalPromptShape() {
        let prompt = TextCleaner.defaultPrompt

        XCTAssertTrue(prompt.hasPrefix("Clean up a speech transcription for direct use as typed text."))
        XCTAssertTrue(prompt.contains("Remove filler words such as um, uh, like, you know, basically, literally, sort of, and kind of when they are obvious fillers."))
        XCTAssertTrue(prompt.contains("Only delete corrected text when the speaker explicitly restarts with phrases like \"scratch that\", \"never mind\", or \"no let me start over\"."))
        XCTAssertTrue(prompt.contains("Fix obvious transcription mistakes for names, commands, files, models, and jargon when context clearly supports the correction."))
        XCTAssertTrue(prompt.contains("Do not summarize, answer, add commentary, or omit real content. If unsure, keep it."))
        XCTAssertTrue(prompt.contains("Examples:"))
        XCTAssertTrue(prompt.contains("Input:"))
        XCTAssertTrue(prompt.contains("Output:"))
        XCTAssertFalse(prompt.contains("<EXAMPLES>"))
        XCTAssertFalse(prompt.contains("<TASK>"))
    }

    func testBuilderIncludesWindowContentsWrapperWhenContextEnabled() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("Base prompt"))
        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
        XCTAssertTrue(prompt.contains("<WINDOW-OCR-CONTENT>"))
        XCTAssertTrue(prompt.contains("Frontmost text"))
        XCTAssertTrue(prompt.contains("</WINDOW-OCR-CONTENT>"))
    }

    func testBuilderExplainsHowToUseWindowContentsAsSupportingContext() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<OCR-RULES>"))
        XCTAssertTrue(prompt.contains("Use the window OCR only as supporting context to improve the transcription and cleanup."))
        XCTAssertTrue(prompt.contains("Prefer the spoken words, and use the window OCR only to disambiguate likely terms, names, commands, files, and jargon."))
        XCTAssertTrue(prompt.contains("If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the window OCR, correct them to the likely intended term."))
        XCTAssertTrue(prompt.contains("Do not answer, summarize, or rewrite the window OCR unless that directly helps correct the transcription."))
        XCTAssertTrue(prompt.contains("</OCR-RULES>"))
    }

    func testBuilderOmitsWindowContentsWhenContextUnavailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: nil,
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertEqual(prompt, "Base prompt")
    }

    func testBuilderTrimsLongOCRContextBeforePromptAssembly() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 12)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "abcdefghijklmnopqrstuvwxyz"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("abcdefghijkl"))
        XCTAssertFalse(prompt.contains("mnopqrstuvwxyz"))
    }

    func testBuilderTrimsOCRContextAtWordBoundaryWhenPossible() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 14)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "hello brave new world"),
            preferredTranscriptions: [],
            commonlyMisheard: [],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("hello brave"))
        XCTAssertFalse(prompt.contains("hello brave new"))
    }

    func testBuilderCapsOverallPromptLengthAfterAddingCorrectionsAndOCR() {
        let builder = CleanupPromptBuilder(maxWindowContentLength: 200, maxPromptLength: 80)
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt with some extra words to consume the prompt budget.",
            windowContext: OCRContext(windowContents: "window context with several words that would otherwise overflow the final prompt"),
            preferredTranscriptions: ["Ghost Pepper", "Jesse"],
            commonlyMisheard: [MisheardReplacement(wrong: "just see", right: "Jesse")],
            includeWindowContext: true
        )

        XCTAssertLessThanOrEqual(prompt.count, 80)
    }

    func testBuilderIncludesCorrectionListsWhenAvailable() {
        let builder = CleanupPromptBuilder()
        let prompt = builder.buildPrompt(
            basePrompt: "Base prompt",
            windowContext: OCRContext(windowContents: "Frontmost text"),
            preferredTranscriptions: ["Ghost Pepper", "Jesse"],
            commonlyMisheard: [
                MisheardReplacement(wrong: "just see", right: "Jesse"),
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")
            ],
            includeWindowContext: true
        )

        XCTAssertTrue(prompt.contains("<CORRECTION-HINTS>"))
        XCTAssertTrue(prompt.contains("Preferred transcriptions to preserve exactly:"))
        XCTAssertTrue(prompt.contains("- Ghost Pepper"))
        XCTAssertTrue(prompt.contains("- Jesse"))
        XCTAssertTrue(prompt.contains("Commonly misheard replacements to prefer:"))
        XCTAssertTrue(prompt.contains("- just see -> Jesse"))
        XCTAssertTrue(prompt.contains("- chat gbt -> ChatGPT"))
        XCTAssertFalse(prompt.contains("<REPLACEMENT>"))
        XCTAssertFalse(prompt.contains("<HEARD>"))
        XCTAssertFalse(prompt.contains("<INTENDED>"))
    }
}
