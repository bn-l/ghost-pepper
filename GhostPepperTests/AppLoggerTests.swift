import XCTest
@testable import GhostPepper

final class AppLoggerTests: XCTestCase {
    func testLoggerEmitsStructuredRecordWithContextAndFields() throws {
        let context = AppLogContext(appSessionID: "app-1", recordingSessionID: "recording-1")
        let logging = makeTestLogger(category: .recording, context: context)

        logging.logger.notice(
            "recording.started",
            "Recording started.",
            fields: ["deviceUID": "builtin"]
        )

        let record = try XCTUnwrap(logging.observer.records.first)
        XCTAssertEqual(record.category, .recording)
        XCTAssertEqual(record.level, .notice)
        XCTAssertEqual(record.event, "recording.started")
        XCTAssertEqual(record.message, "Recording started.")
        XCTAssertEqual(record.fields["deviceUID"], "builtin")
        XCTAssertEqual(record.context.appSessionID, "app-1")
        XCTAssertEqual(record.context.recordingSessionID, "recording-1")
    }

    func testLoggerSuppressesTraceRecordsInInfoMode() {
        let logging = makeTestLogger(category: .audio, mode: .info)

        logging.logger.trace("preview.first_frames", "Received first audio frames.")

        XCTAssertTrue(logging.observer.records.isEmpty)
    }

    func testLoggerEmitsTraceRecordsInTraceMode() {
        let logging = makeTestLogger(category: .audio, mode: .trace)

        logging.logger.trace("preview.first_frames", "Received first audio frames.")

        XCTAssertEqual(logging.observer.records.map(\.event), ["preview.first_frames"])
    }

    func testLoggerIntervalsEmitStartAndEndRecords() {
        let logging = makeTestLogger(category: .audio, mode: .trace)

        let interval = logging.logger.beginInterval(
            "audio_selection",
            "Starting audio preview.",
            fields: ["deviceUID": "builtin"]
        )
        logging.logger.endInterval(interval, "Audio preview completed.")

        XCTAssertEqual(
            logging.observer.records.map(\.event),
            ["audio_selection.start", "audio_selection.end"]
        )
        XCTAssertEqual(logging.observer.records.first?.fields["deviceUID"], "builtin")
        XCTAssertNotNil(logging.observer.records.last?.fields["durationMS"])
    }

    func testEncodedMessagesRoundTripWithoutDroppingFields() throws {
        let record = AppLogRecord(
            timestamp: Date(timeIntervalSince1970: 1_234_567),
            category: .ocr,
            level: .warning,
            event: "capture.failed",
            message: "Frontmost-window OCR failed.",
            fields: ["permission": "screen-recording"],
            context: AppLogContext(appSessionID: "app-1"),
            error: AppLogErrorMetadata(error: NSError(domain: NSOSStatusErrorDomain, code: -1))
        )

        let decoded = try XCTUnwrap(AppLogRecord.decode(from: record.encodedMessage))
        XCTAssertEqual(decoded, record)
    }
}
