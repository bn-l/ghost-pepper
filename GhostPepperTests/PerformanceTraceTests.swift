import XCTest
@testable import GhostPepper

@MainActor
final class PerformanceTraceTests: XCTestCase {
    func testSummaryReportsExpectedStageDurations() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 100)
        var trace = PerformanceTrace(sessionID: "session-1", startedAt: startedAt)

        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.08)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(1.30)
        trace.micColdAt = startedAt.addingTimeInterval(1.55)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.55)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(2.05)
        trace.cleanupStartAt = startedAt.addingTimeInterval(2.05)
        trace.cleanupEndAt = startedAt.addingTimeInterval(2.42)
        trace.ocrCaptureDuration = 0.41
        trace.promptBuildDuration = 0.02
        trace.modelCallDuration = 0.64
        trace.postProcessDuration = 0.21
        trace.pasteStartAt = startedAt.addingTimeInterval(2.43)
        trace.pasteEndAt = startedAt.addingTimeInterval(2.59)

        let summary = trace.summary(
            speechModelID: "parakeet-v3",
            cleanupBackendID: CleanupBackendDefaults.localModelsID,
            cleanupAttempted: true
        )

        XCTAssertTrue(summary.contains("sessionID=session-1"))
        XCTAssertTrue(summary.contains("speechModelID=parakeet-v3"))
        XCTAssertTrue(summary.contains("hotkeyToMicLiveMS=80"))
        XCTAssertTrue(summary.contains("hotkeyLiftToMicColdMS=250"))
        XCTAssertTrue(summary.contains("transcriptionMS=500"))
        XCTAssertTrue(summary.contains("cleanupMS=370"))
        XCTAssertTrue(summary.contains("ocrMS=410"))
        XCTAssertTrue(summary.contains("promptBuildMS=20"))
        XCTAssertTrue(summary.contains("modelCallMS=640"))
        XCTAssertTrue(summary.contains("postProcessMS=210"))
        XCTAssertTrue(summary.contains("pasteMS=160"))
        XCTAssertTrue(summary.contains("totalMS=2590"))
    }

    func testSummaryMarksSkippedCleanupWhenItWasNotAttempted() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 200)
        var trace = PerformanceTrace(sessionID: "session-2", startedAt: startedAt)
        trace.hotkeyDetectedAt = startedAt
        trace.micLiveAt = startedAt.addingTimeInterval(0.04)
        trace.hotkeyLiftedAt = startedAt.addingTimeInterval(0.80)
        trace.micColdAt = startedAt.addingTimeInterval(1.00)
        trace.transcriptionStartAt = startedAt.addingTimeInterval(1.00)
        trace.transcriptionEndAt = startedAt.addingTimeInterval(1.48)
        trace.pasteStartAt = startedAt.addingTimeInterval(1.49)
        trace.pasteEndAt = startedAt.addingTimeInterval(1.63)

        let summary = trace.summary(
            speechModelID: "openai_whisper-small.en",
            cleanupBackendID: CleanupBackendDefaults.localModelsID,
            cleanupAttempted: false
        )

        XCTAssertTrue(summary.contains("cleanupMS=skipped"))
    }
}
