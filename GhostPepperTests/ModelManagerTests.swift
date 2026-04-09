import XCTest
@testable import GhostPepper

@MainActor
final class ModelManagerTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() {
                return
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Condition was not met before timeout.", file: file, line: line)
    }

    func testModelManagerRetriesTimedOutSpeechModelLoadOnce() async {
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        var attempts = 0
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in
                attempts += 1
                if attempts == 1 {
                    throw timeoutError
                }
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel(name: "openai_whisper-small.en")

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
    }

    func testModelManagerProcessesQueuedModelSwitchAfterCurrentLoadFinishes() async {
        let loadedNames = LockedStringArray()
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { descriptor in
                await loadedNames.append(descriptor.name)
                try? await Task.sleep(for: .milliseconds(75))
            },
            loadRetryDelayOverride: {}
        )

        let firstLoad = Task { @MainActor in
            await manager.loadModel(name: "openai_whisper-small.en")
        }

        try? await Task.sleep(for: .milliseconds(10))
        await manager.loadModel(name: "fluid_parakeet-v3")
        await firstLoad.value
        await waitUntil {
            manager.modelName == "fluid_parakeet-v3" && manager.state == .ready
        }

        let names = await loadedNames.get()
        XCTAssertEqual(names, ["openai_whisper-small.en", "fluid_parakeet-v3"])
        XCTAssertNil(manager.error)
    }
}

private actor LockedStringArray {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func get() -> [String] {
        values
    }
}
