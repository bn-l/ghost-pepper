import XCTest
@testable import GhostPepper

private actor OCRPrefetchCaptureSpy {
    var callCount = 0

    func recordCall() {
        callCount += 1
    }
}

@MainActor
final class RecordingOCRPrefetchTests: XCTestCase {
    func testStartLaunchesCaptureBeforeResolve() async {
        let spy = OCRPrefetchCaptureSpy()
        let prefetch = RecordingOCRPrefetch { _ in
            await spy.recordCall()
            try? await Task.sleep(for: .milliseconds(50))
            return OCRContext(windowContents: "captured")
        }

        prefetch.start(customWords: ["Ghost Pepper"])
        try? await Task.sleep(for: .milliseconds(10))

        let count = await spy.callCount
        XCTAssertEqual(count, 1)
    }

    func testResolveReturnsCapturedContextAndElapsedTime() async {
        let prefetch = RecordingOCRPrefetch { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return OCRContext(windowContents: "captured")
        }

        prefetch.start(customWords: [])
        let result = await prefetch.resolve()

        XCTAssertEqual(result?.context?.windowContents, "captured")
        XCTAssertNotNil(result?.elapsed)
    }
}
