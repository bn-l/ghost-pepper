import Foundation

protocol PrivacyMaintaining: Sendable {
    func run(defaults: UserDefaults)
}

struct PrivacyMaintenance: PrivacyMaintaining {
    private static let cleanupVersionDefaultsKey = "privacyCleanupVersion"
    private static let currentCleanupVersion = 1
    private static let staleDefaultsKeys = [
        ["pepper", "Chat", "Host"].joined(),
        ["pepper", "Chat", "Api", "Key"].joined(),
        ["pepper", "Chat", "Include", "Screen", "Context"].joined(),
        ["chordBinding.", "pepper", "Chat"].joined()
    ]

    private let applicationSupportURL: URL?
    static let defaultClient: PrivacyMaintenance = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return PrivacyMaintenance(applicationSupportURL: nil)
        }

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        return PrivacyMaintenance(applicationSupportURL: appSupport)
    }()

    init(
        applicationSupportURL: URL?
    ) {
        self.applicationSupportURL = applicationSupportURL
    }

    func run(defaults: UserDefaults) {
        guard defaults.integer(forKey: Self.cleanupVersionDefaultsKey) < Self.currentCleanupVersion else {
            return
        }

        if let applicationSupportURL {
            let baseURL = applicationSupportURL.appendingPathComponent("GhostPepper", isDirectory: true)
            removeItemIfPresent(at: baseURL.appendingPathComponent("transcription-lab", isDirectory: true))
            removeItemIfPresent(at: baseURL.appendingPathComponent("debug-log.json"))
        }

        for key in Self.staleDefaultsKeys {
            defaults.removeObject(forKey: key)
        }

        defaults.set(Self.currentCleanupVersion, forKey: Self.cleanupVersionDefaultsKey)
    }

    private func removeItemIfPresent(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        try? FileManager.default.removeItem(at: url)
    }
}
