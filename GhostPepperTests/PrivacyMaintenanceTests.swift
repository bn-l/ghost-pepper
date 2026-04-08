import XCTest
@testable import GhostPepper

final class PrivacyMaintenanceTests: XCTestCase {
    private let legacyHostKey = ["pepper", "Chat", "Host"].joined()
    private let legacyAPIKeyKey = ["pepper", "Chat", "Api", "Key"].joined()
    private let legacyScreenContextKey = ["pepper", "Chat", "Include", "Screen", "Context"].joined()
    private let legacyShortcutKey = ["chordBinding.", "pepper", "Chat"].joined()

    func testMigrationDeletesLegacyArchiveDirectoryAndDebugLogOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let ghostPepperDirectory = appSupport.appendingPathComponent("GhostPepper", isDirectory: true)
        let historyDirectory = ghostPepperDirectory.appendingPathComponent("transcription-lab", isDirectory: true)
        let debugLogURL = ghostPepperDirectory.appendingPathComponent("debug-log.json")

        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: debugLogURL)

        let maintenance = PrivacyMaintenance(applicationSupportURL: appSupport)
        maintenance.run(defaults: defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: historyDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugLogURL.path))

        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: debugLogURL)

        maintenance.run(defaults: defaults)

        XCTAssertTrue(FileManager.default.fileExists(atPath: historyDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugLogURL.path))
    }

    func testMigrationRemovesLegacyDefaultsKeys() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set("https://example.invalid", forKey: legacyHostKey)
        defaults.set("token", forKey: legacyAPIKeyKey)
        defaults.set(true, forKey: legacyScreenContextKey)
        defaults.set(Data(), forKey: legacyShortcutKey)

        let maintenance = PrivacyMaintenance(applicationSupportURL: nil)
        maintenance.run(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: legacyHostKey))
        XCTAssertNil(defaults.object(forKey: legacyAPIKeyKey))
        XCTAssertNil(defaults.object(forKey: legacyScreenContextKey))
        XCTAssertNil(defaults.object(forKey: legacyShortcutKey))
    }
}
