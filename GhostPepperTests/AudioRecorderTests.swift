import XCTest
import CoreAudio
@testable import GhostPepper

private final class RecorderFakeDeviceManager: AudioDeviceManaging {
    let devices: [AudioInputDevice]
    let defaultDeviceUID: String?

    init(devices: [AudioInputDevice], defaultDeviceUID: String? = nil) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
    }

    func listInputDevices() -> [AudioInputDevice] {
        devices
    }

    func defaultInputDevice() -> AudioInputDevice? {
        guard let defaultDeviceUID else {
            return devices.first
        }
        return inputDevice(uid: defaultDeviceUID)
    }

    func inputDevice(uid: String) -> AudioInputDevice? {
        devices.first(where: { $0.uid == uid })
    }

    func addInputDeviceListObserver(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioHardwareObserving? {
        nil
    }

    func addStateObservers(
        for device: AudioInputDevice,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> [AudioHardwareObserving] {
        []
    }
}

private final class RecorderFakeSession: AudioInputCapturing, @unchecked Sendable {
    var onSamples: (@Sendable (AudioInputBufferBatch) -> Void)?
    private(set) var startedDevices: [AudioInputDevice] = []
    private(set) var stopCallCount = 0

    func start(device: AudioInputDevice) async throws -> AudioInputStreamFormat {
        startedDevices.append(device)
        return AudioInputStreamFormat(sampleRate: 16_000, channelCount: 1)
    }

    func stop() async {
        stopCallCount += 1
    }
}

final class AudioRecorderTests: XCTestCase {
    private func makeDevice(uid: String, name: String) -> AudioInputDevice {
        let hashedID = uid.utf8.reduce(UInt32(5381)) { partialResult, byte in
            ((partialResult << 5) &+ partialResult) &+ UInt32(byte)
        }
        return AudioInputDevice(
            id: AudioDeviceID(max(hashedID, 1)),
            uid: uid,
            name: name,
            isAlive: true,
            transportType: kAudioDeviceTransportTypeBuiltIn
        )
    }

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

        let data = AudioRecorder.serializeAudioBuffer(samples)
        let decoded = try AudioRecorder.deserializeAudioBuffer(from: data)

        XCTAssertEqual(decoded, samples)
    }

    func testPlayableArchiveSerializationCreatesWAVDataThatRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
        let riffHeader = String(decoding: data.prefix(4), as: UTF8.self)
        let waveHeader = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        let decoded = try AudioRecorder.deserializeArchivedAudioBuffer(from: data)

        XCTAssertEqual(riffHeader, "RIFF")
        XCTAssertEqual(waveHeader, "WAVE")
        XCTAssertEqual(decoded.count, samples.count)
        for (decodedSample, expectedSample) in zip(decoded, samples) {
            XCTAssertEqual(decodedSample, expectedSample, accuracy: 0.0001)
        }
    }

    func testArchivedAudioRejectsMalformedRIFFChunkSize() {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]
        var data = AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
        let invalidChunkSize = UInt32(0)
        let invalidChunkSizeData = withUnsafeBytes(of: invalidChunkSize.littleEndian) { Data($0) }
        data.replaceSubrange(4..<8, with: invalidChunkSizeData)

        XCTAssertThrowsError(try AudioRecorder.deserializeArchivedAudioBuffer(from: data)) { error in
            XCTAssertEqual(error as? AudioRecorderPersistenceError, .invalidSerializedAudioData)
        }
    }

    func testArchivedAudioRejectsEmptyPCMDataChunk() {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(36).littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(16_000).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt32(32_000).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(0).littleEndian) { Data($0) })

        XCTAssertThrowsError(try AudioRecorder.deserializeArchivedAudioBuffer(from: data)) { error in
            XCTAssertEqual(error as? AudioRecorderPersistenceError, .invalidSerializedAudioData)
        }
    }

    func testConvertedSamplesAreDeliveredToChunkCallback() throws {
        let recorder = AudioRecorder()
        var deliveredChunks: [[Float]] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredChunks.append(chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredChunks, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testChunkDeliveryStillAccumulatesFinalAudioBuffer() throws {
        let recorder = AudioRecorder()
        var deliveredSamples: [Float] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredSamples.append(contentsOf: chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredSamples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(recorder.audioBuffer, [0.1, 0.2, 0.3, 0.4])
    }

    func testRecorderUsesPreferredInputDeviceUIDWhenStartingCapture() async throws {
        let builtIn = makeDevice(uid: "builtin", name: "MacBook Microphone")
        let preferred = makeDevice(uid: "preferred", name: "iPhone Microphone")
        let deviceManager = RecorderFakeDeviceManager(
            devices: [builtIn, preferred],
            defaultDeviceUID: builtIn.uid
        )
        let session = RecorderFakeSession()
        let recorder = AudioRecorder(
            preferredInputDeviceUIDProvider: { preferred.uid },
            deviceManager: deviceManager,
            sessionFactory: { session }
        )

        try await recorder.startRecording()
        _ = await recorder.stopRecording()

        XCTAssertEqual(session.startedDevices.map(\.uid), [preferred.uid])
        XCTAssertEqual(session.stopCallCount, 1)
    }
}
