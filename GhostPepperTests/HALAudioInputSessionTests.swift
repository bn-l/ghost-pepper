import XCTest
@testable import GhostPepper

final class HALAudioInputSessionTests: XCTestCase {
    func testLateInputCallbackAfterStopReturnsNoErr() async {
        let session = HALAudioInputSession()

        await session.stop()
        let status = session.invokeInputCallbackForTesting(frameCount: 16)

        XCTAssertEqual(status, noErr)
    }

    func testAudioInputSessionErrorsExposeDistinctDescriptions() {
        XCTAssertEqual(
            AudioInputSessionError.cannotEnableInput(-1).errorDescription,
            "Could not enable audio input (OSStatus -1)."
        )
        XCTAssertEqual(
            AudioInputSessionError.cannotStart(-2).errorDescription,
            "Could not start the audio input session (OSStatus -2)."
        )
    }
}
