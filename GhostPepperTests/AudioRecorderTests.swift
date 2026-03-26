import XCTest
@testable import GhostPepper

final class AudioRecorderTests: XCTestCase {
    func testBufferStartsEmpty() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testBufferClearsOnReset() {
        let recorder = AudioRecorder()
        recorder.audioBuffer = [1.0, 2.0, 3.0]
        recorder.resetBuffer()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testAudioBufferSerializationRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializeAudioBuffer(samples)
        let decoded = try AudioRecorder.deserializeAudioBuffer(from: data)

        XCTAssertEqual(decoded, samples)
    }
}
