import XCTest
@testable import GhostPepper

final class TranscriptionLabStoreTests: XCTestCase {
    func testEntryRoundTripsThroughJSON() throws {
        let entry = TranscriptionLabEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_742_950_000),
            audioFileName: "sample-audio.bin",
            audioDuration: 2.5,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "The default is Qwen 3.5 4B.",
            correctedTranscription: "The default is Qwen 3.5 4B.",
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)",
            cleanupUsedFallback: false
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionLabEntry.self, from: encoded)

        XCTAssertEqual(decoded, entry)
    }

    func testStoreReturnsEntriesNewestFirst() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )

        let olderEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100),
            audioFileName: "older.bin"
        )
        let newerEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 200),
            audioFileName: "newer.bin"
        )

        try store.insert(olderEntry, audioData: Data([0x01]), stageTimings: makeStageTimings())
        try store.insert(newerEntry, audioData: Data([0x02]), stageTimings: makeStageTimings())

        let entries = try store.loadEntries()

        XCTAssertEqual(entries.map(\.id), [newerEntry.id, olderEntry.id])
    }

    func testStorePrunesOldestEntryWhenCapacityExceeded() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 2
        )

        let firstEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 100),
            audioFileName: "first.bin"
        )
        let secondEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: Date(timeIntervalSince1970: 200),
            audioFileName: "second.bin"
        )
        let thirdEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            createdAt: Date(timeIntervalSince1970: 300),
            audioFileName: "third.bin"
        )

        try store.insert(firstEntry, audioData: Data([0x01]), stageTimings: makeStageTimings())
        try store.insert(secondEntry, audioData: Data([0x02]), stageTimings: makeStageTimings())
        try store.insert(thirdEntry, audioData: Data([0x03]), stageTimings: makeStageTimings())

        let entries = try store.loadEntries()

        XCTAssertEqual(entries.map(\.id), [thirdEntry.id, secondEntry.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL(named: "first.bin").path))
    }

    func testStoreLoadsEmptyArchiveWhenIndexDoesNotExist() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )

        let entries = try store.loadEntries()

        XCTAssertTrue(entries.isEmpty)
    }

    func testStorePersistsStageTimingsForNewEntries() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let entry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            createdAt: Date(timeIntervalSince1970: 123),
            audioFileName: "timed.bin"
        )
        let stageTimings = TranscriptionLabStageTimings(
            transcriptionDuration: 0.31,
            cleanupDuration: 0.72
        )

        try store.insert(entry, audioData: Data([0x01]), stageTimings: stageTimings)

        XCTAssertEqual(
            try store.loadStageTimings()[entry.id],
            stageTimings
        )
    }

    private func makeEntry(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        audioFileName: String
    ) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: id,
            createdAt: createdAt,
            audioFileName: audioFileName,
            audioDuration: 1.5,
            windowContext: OCRContext(windowContents: "Terminal says hello"),
            rawTranscription: "raw text",
            correctedTranscription: "corrected text",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)",
            cleanupUsedFallback: false
        )
    }

    private func makeFixture() -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return Fixture(directoryURL: directoryURL)
    }

    private struct Fixture {
        let directoryURL: URL

        func audioURL(named fileName: String) -> URL {
            directoryURL.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(fileName)
        }
    }

    private func makeStageTimings() -> TranscriptionLabStageTimings {
        TranscriptionLabStageTimings(
            transcriptionDuration: 0.25,
            cleanupDuration: 0.55
        )
    }
}
