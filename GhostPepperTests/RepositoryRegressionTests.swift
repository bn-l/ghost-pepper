import XCTest

final class RepositoryRegressionTests: XCTestCase {
    func testRepositorySourceTreeDoesNotReintroduceRemovedRemoteFeatures() throws {
        let forbiddenTerms = [
            "PepperChat",
            "ZoBackend",
            "api.zo.computer",
            "Sparkle",
            "SPU",
            "appcast"
        ]

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pathsToScan = [
            repoRoot.appendingPathComponent("GhostPepper", isDirectory: true),
            repoRoot.appendingPathComponent("CleanupModelProbe", isDirectory: true),
            repoRoot.appendingPathComponent("README.md"),
            repoRoot.appendingPathComponent("project.yml"),
            repoRoot.appendingPathComponent("GhostPepper.xcodeproj/project.pbxproj")
        ]

        var matches: [String] = []
        for path in pathsToScan {
            if path.hasDirectoryPath {
                let enumerator = FileManager.default.enumerator(
                    at: path,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let fileURL = enumerator?.nextObject() as? URL {
                    let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard values.isRegularFile == true else {
                        continue
                    }
                    let contents = try String(contentsOf: fileURL, encoding: .utf8)
                    if let term = forbiddenTerms.first(where: contents.contains(_:)) {
                        matches.append("\(fileURL.path): \(term)")
                    }
                }
            } else {
                let contents = try String(contentsOf: path, encoding: .utf8)
                if let term = forbiddenTerms.first(where: contents.contains(_:)) {
                    matches.append("\(path.path): \(term)")
                }
            }
        }

        XCTAssertTrue(matches.isEmpty, "Found removed remote-feature references: \(matches.joined(separator: ", "))")
    }
}
