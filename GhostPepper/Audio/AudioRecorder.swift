@preconcurrency import AVFoundation
import Foundation

final class AudioRecorder: @unchecked Sendable {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onConvertedAudioChunk: (([Float]) -> Void)?
    var logger: AppLogger?

    private let bufferLock = NSLock()
    private let conversionQueue = DispatchQueue(label: "GhostPepper.AudioRecorder.Conversion")
    private let preferredInputDeviceUIDProvider: () -> String?
    private let deviceManager: AudioDeviceManaging
    private let sessionFactory: @Sendable () -> AudioInputCapturing
    private var session: AudioInputCapturing?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// The accumulated audio samples captured during recording.
    /// Accessible for reading within the module (internal) so tests can inspect it.
    var audioBuffer: [Float] = []

    /// Target format for WhisperKit: 16 kHz, mono, Float32.
    private lazy var targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }()

    init(
        preferredInputDeviceUIDProvider: @escaping () -> String? = {
            UserDefaults.standard.string(forKey: "preferredInputDeviceUID")
        },
        deviceManager: AudioDeviceManaging = AudioDeviceManager.shared,
        sessionFactory: @escaping @Sendable () -> AudioInputCapturing = { HALAudioInputSession() }
    ) {
        self.preferredInputDeviceUIDProvider = preferredInputDeviceUIDProvider
        self.deviceManager = deviceManager
        self.sessionFactory = sessionFactory
    }

    /// Audio capture is now started asynchronously on a dedicated queue, so prewarming is a no-op.
    func prewarm() {}

    static func serializeAudioBuffer(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    static func serializePlayableArchiveAudioBuffer(_ samples: [Float]) -> Data {
        let sampleRate = UInt32(16_000)
        let channelCount = UInt16(1)
        let bitsPerSample = UInt16(16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample) / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let riffChunkSize = UInt32(36 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(contentsOf: riffChunkSize.littleEndianBytes)
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(contentsOf: UInt32(16).littleEndianBytes)
        data.append(contentsOf: UInt16(1).littleEndianBytes)
        data.append(contentsOf: channelCount.littleEndianBytes)
        data.append(contentsOf: sampleRate.littleEndianBytes)
        data.append(contentsOf: byteRate.littleEndianBytes)
        data.append(contentsOf: blockAlign.littleEndianBytes)
        data.append(contentsOf: bitsPerSample.littleEndianBytes)
        data.append("data".data(using: .ascii)!)
        data.append(contentsOf: UInt32(dataSize).littleEndianBytes)

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            data.append(contentsOf: scaled.littleEndianBytes)
        }

        return data
    }

    static func deserializeAudioBuffer(from data: Data) throws -> [Float] {
        let stride = MemoryLayout<Float>.stride
        guard data.count.isMultiple(of: stride) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return data.withUnsafeBytes { rawBuffer in
            let floatBuffer = rawBuffer.bindMemory(to: Float.self)
            return Array(floatBuffer)
        }
    }

    static func deserializeArchivedAudioBuffer(from data: Data) throws -> [Float] {
        if data.starts(with: Data("RIFF".utf8)) {
            return try deserializeWAVAudioBuffer(from: data)
        }

        return try deserializeAudioBuffer(from: data)
    }

    /// Clears the in-memory audio buffer.
    func resetBuffer() {
        bufferLock.withLock {
            audioBuffer = []
        }
    }

    /// Starts capturing audio from the preferred input device.
    /// Audio is converted to 16 kHz mono Float32 and appended to `audioBuffer`.
    func startRecording() async throws {
        resetBuffer()
        sourceFormat = nil
        converter = nil

        if let session {
            await session.stop()
            self.session = nil
        }

        let device = try resolveRecordingDevice()
        let session = sessionFactory()
        self.session = session
        session.onSamples = { [weak self] batch in
            self?.handleInputBatch(batch)
        }

        let format = try await session.start(device: device)
        logger?.notice(
            "recording.ready",
            "Recording ready using the selected input device.",
            fields: [
                "deviceName": device.name,
                "deviceUID": device.uid,
                "deviceID": String(device.id),
                "sampleRate": String(Int(format.sampleRate)),
                "channelCount": String(format.channelCount),
                "continuity": String(device.isContinuityCandidate)
            ]
        )
        onRecordingStarted?()
    }

    /// Stops capturing audio and returns the recorded buffer.
    func stopRecording() async -> [Float] {
        let session = self.session
        self.session = nil
        await session?.stop()

        await withCheckedContinuation { continuation in
            conversionQueue.async {
                continuation.resume()
            }
        }

        onRecordingStopped?()

        let result = bufferLock.withLock { audioBuffer }
        logger?.info(
            "recording.stopped",
            "Recording stopped.",
            fields: [
                "sampleCount": String(result.count),
                "durationMS": String(Int((Double(result.count) / 16.0).rounded()))
            ]
        )
        return result
    }

    // MARK: - Private

    private func resolveRecordingDevice() throws -> AudioInputDevice {
        if let preferredUID = preferredInputDeviceUIDProvider(),
           let preferredDevice = deviceManager.inputDevice(uid: preferredUID),
           preferredDevice.isAlive {
            return preferredDevice
        }

        if let defaultDevice = deviceManager.defaultInputDevice(),
           defaultDevice.isAlive {
            return defaultDevice
        }

        guard let fallbackDevice = deviceManager.listInputDevices().first(where: \.isAlive) else {
            throw AudioRecorderError.noInputAvailable
        }
        return fallbackDevice
    }

    private func handleInputBatch(_ batch: AudioInputBufferBatch) {
        conversionQueue.async { [weak self] in
            guard let self else { return }
            let convertedFrames = self.convert(samples: batch.samples, sampleRate: batch.sampleRate)
            guard !convertedFrames.isEmpty else {
                return
            }

            self.appendConvertedFrames(convertedFrames)
        }
    }

    private func convert(samples: [Float], sampleRate: Double) -> [Float] {
        let inputFormat = sourceFormat(for: sampleRate)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return []
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = inputBuffer.floatChannelData?.pointee {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        let converter = converter(for: inputFormat)
        return convert(buffer: inputBuffer, using: converter)
    }

    private func sourceFormat(for sampleRate: Double) -> AVAudioFormat {
        if let sourceFormat, sourceFormat.sampleRate == sampleRate {
            return sourceFormat
        }

        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
        sourceFormat = inputFormat
        converter = nil
        return inputFormat
    }

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter {
        if let converter,
           converter.inputFormat.sampleRate == inputFormat.sampleRate {
            return converter
        }

        let nextConverter = AVAudioConverter(from: inputFormat, to: targetFormat)!
        converter = nextConverter
        return nextConverter
    }

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> [Float] {
        let frameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * (targetFormat.sampleRate / buffer.format.sampleRate)
        ) + 1

        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return []
        }

        var conversionError: NSError?
        var allConsumed = false

        converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            logger?.warning("recording.conversion_failed", "Audio sample-rate conversion failed.", error: conversionError)
            return []
        }

        guard let channelData = convertedBuffer.floatChannelData,
              convertedBuffer.frameLength > 0 else {
            return []
        }

        return Array(
            UnsafeBufferPointer(
                start: channelData[0],
                count: Int(convertedBuffer.frameLength)
            )
        )
    }

    #if DEBUG
    func test_convert(samples: [Float], sampleRate: Double = 16_000) {
        let convertedFrames = convert(samples: samples, sampleRate: sampleRate)
        appendConvertedFrames(convertedFrames)
    }
    #endif

    private func appendConvertedFrames(_ frames: [Float]) {
        bufferLock.withLock {
            audioBuffer.append(contentsOf: frames)
        }

        onConvertedAudioChunk?(frames)
    }
}

// MARK: - Errors

private extension AudioRecorder {
    static func deserializeWAVAudioBuffer(from data: Data) throws -> [Float] {
        guard data.count >= 44,
              data.starts(with: Data("RIFF".utf8)),
              data.dropFirst(8).starts(with: Data("WAVE".utf8)) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        var offset = 12
        var audioFormat: UInt16?
        var bitsPerSample: UInt16?
        var channelCount: UInt16?
        var sampleData = Data()

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<(offset + 4)]
            let chunkSize = UInt32(littleEndian: data[(offset + 4)..<(offset + 8)].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 8

            guard offset + Int(chunkSize) <= data.count else {
                throw AudioRecorderPersistenceError.invalidSerializedAudioData
            }

            let chunkData = data[offset..<(offset + Int(chunkSize))]
            let chunkID = String(decoding: chunkIDData, as: UTF8.self)

            if chunkID == "fmt " {
                guard chunkData.count >= 16 else {
                    throw AudioRecorderPersistenceError.invalidSerializedAudioData
                }

                audioFormat = UInt16(littleEndian: chunkData[chunkData.startIndex..<(chunkData.startIndex + 2)].withUnsafeBytes { $0.load(as: UInt16.self) })
                channelCount = UInt16(littleEndian: chunkData[(chunkData.startIndex + 2)..<(chunkData.startIndex + 4)].withUnsafeBytes { $0.load(as: UInt16.self) })
                bitsPerSample = UInt16(littleEndian: chunkData[(chunkData.startIndex + 14)..<(chunkData.startIndex + 16)].withUnsafeBytes { $0.load(as: UInt16.self) })
            } else if chunkID == "data" {
                sampleData = Data(chunkData)
            }

            offset += Int(chunkSize)
            if chunkSize.isMultiple(of: 2) == false {
                offset += 1
            }
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              sampleData.count.isMultiple(of: 2) else {
            throw AudioRecorderPersistenceError.invalidSerializedAudioData
        }

        return sampleData.withUnsafeBytes { rawBuffer in
            let int16Buffer = rawBuffer.bindMemory(to: Int16.self)
            return int16Buffer.map { Float($0) / Float(Int16.max) }
        }
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

enum AudioRecorderError: Error, LocalizedError {
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No audio input device available."
        }
    }
}

enum AudioRecorderPersistenceError: Error {
    case invalidSerializedAudioData
}
