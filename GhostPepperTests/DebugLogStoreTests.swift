import XCTest
@testable import GhostPepper

@MainActor
final class DebugLogStoreTests: XCTestCase {
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date.now.addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Condition was not met before timeout.", file: file, line: line)
    }

    func testStoreLoadsEntriesFromReaderAndCapsCapacity() async {
        let entries = [
            AppLogRecord(
                timestamp: Date(timeIntervalSinceReferenceDate: 10),
                category: .hotkey,
                level: .info,
                event: "hotkey.one",
                message: "first"
            ),
            AppLogRecord(
                timestamp: Date(timeIntervalSinceReferenceDate: 11),
                category: .ocr,
                level: .info,
                event: "ocr.two",
                message: "second"
            ),
            AppLogRecord(
                timestamp: Date(timeIntervalSinceReferenceDate: 12),
                category: .cleanup,
                level: .warning,
                event: "cleanup.three",
                message: "third"
            )
        ]
        let store = DebugLogStore(
            maxEntries: 2,
            reader: StaticAppLogStoreReader(result: .success(entries))
        )

        store.refresh()
        await waitUntil {
            store.entries.map(\.message) == ["second", "third"]
        }

        XCTAssertEqual(store.entries.map(\.message), ["second", "third"])
    }

    func testFormattedTextIncludesCategoryLevelEventAndFields() async {
        let entry = AppLogRecord(
            timestamp: Date(timeIntervalSinceReferenceDate: 10),
            category: .performance,
            level: .notice,
            event: "dictation.completed",
            message: "Dictation pipeline completed.",
            fields: ["speechModelID": "parakeet-v3"],
            context: AppLogContext(appSessionID: "app-1", recordingSessionID: "recording-1")
        )
        let store = DebugLogStore(reader: StaticAppLogStoreReader(result: .success([entry])))

        store.refresh()
        await waitUntil {
            store.entries.count == 1
        }

        let text = store.formattedText

        XCTAssertTrue(text.contains("[Performance] [Notice] dictation.completed"))
        XCTAssertTrue(text.contains("Dictation pipeline completed."))
        XCTAssertTrue(text.contains("speechModelID=parakeet-v3"))
        XCTAssertTrue(text.contains("appSessionID=app-1"))
        XCTAssertTrue(text.contains("recordingSessionID=recording-1"))
    }

    func testRefreshStoresLastErrorWhenReaderFails() async {
        enum SampleError: LocalizedError {
            case failed

            var errorDescription: String? {
                "reader failed"
            }
        }

        let store = DebugLogStore(
            reader: StaticAppLogStoreReader(result: .failure(SampleError.failed))
        )

        store.refresh()
        await waitUntil {
            store.lastRefreshError == "reader failed"
        }

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.lastRefreshError, "reader failed")
    }

    func testExportJSONSerializesVisibleEntries() async {
        let entries = [
            AppLogRecord(
                timestamp: Date(timeIntervalSinceReferenceDate: 10),
                category: .audio,
                level: .info,
                event: "preview.ready",
                message: "Audio preview is ready.",
                fields: ["deviceUID": "builtin"]
            )
        ]
        let store = DebugLogStore(reader: StaticAppLogStoreReader(result: .success(entries)))

        store.refresh()
        await waitUntil {
            store.entries.count == 1
        }

        let json = store.exportJSON(for: store.entries)

        XCTAssertTrue(json.contains("\"event\" : \"preview.ready\""))
        XCTAssertTrue(json.contains("\"deviceUID\" : \"builtin\""))
    }
}
