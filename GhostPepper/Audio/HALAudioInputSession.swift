import AudioToolbox
import CoreAudio
import Foundation
import OSLog

struct AudioInputBufferBatch: Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channelCount: UInt32
    let rms: Float
}

struct AudioInputStreamFormat: Sendable, Equatable {
    let sampleRate: Double
    let channelCount: UInt32
}

protocol AudioInputCapturing: AnyObject, Sendable {
    var onSamples: (@Sendable (AudioInputBufferBatch) -> Void)? { get set }

    func start(device: AudioInputDevice) async throws -> AudioInputStreamFormat
    func stop() async
}

enum AudioInputSessionError: LocalizedError {
    case componentUnavailable
    case cannotEnableInput(OSStatus)
    case cannotDisableOutput(OSStatus)
    case cannotBindDevice(OSStatus)
    case cannotReadDeviceFormat(OSStatus)
    case cannotSetClientFormat(OSStatus)
    case cannotInstallCallback(OSStatus)
    case cannotInitialize(OSStatus)
    case cannotStart(OSStatus)

    var errorDescription: String? {
        switch self {
        case .componentUnavailable:
            return "Could not create the HAL audio input unit."
        case .cannotEnableInput(let status):
            return "Could not enable audio input (OSStatus \(status))."
        case .cannotDisableOutput(let status):
            return "Could not disable audio output (OSStatus \(status))."
        case .cannotBindDevice(let status):
            return "Could not bind the selected microphone (OSStatus \(status))."
        case .cannotReadDeviceFormat(let status):
            return "Could not read the microphone format (OSStatus \(status))."
        case .cannotSetClientFormat(let status):
            return "Could not configure the microphone stream format (OSStatus \(status))."
        case .cannotInstallCallback(let status):
            return "Could not install the audio input callback (OSStatus \(status))."
        case .cannotInitialize(let status):
            return "Could not initialize the audio input session (OSStatus \(status))."
        case .cannotStart(let status):
            return "Could not start the audio input session (OSStatus \(status))."
        }
    }
}

private final class AudioInputRenderBuffer: @unchecked Sendable {
    let bufferListPointer: UnsafeMutablePointer<AudioBufferList>
    let bufferData: UnsafeMutableRawPointer

    init(byteCount: Int) {
        bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        bufferData = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<Float>.alignment
        )
        bufferListPointer.initialize(
            to: AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(byteCount),
                    mData: bufferData
                )
            )
        )
    }

    deinit {
        bufferListPointer.deinitialize(count: 1)
        bufferListPointer.deallocate()
        bufferData.deallocate()
    }
}

private final class AudioInputCallbackContext {
    weak var session: HALAudioInputSession?

    init(session: HALAudioInputSession) {
        self.session = session
    }
}

final class HALAudioInputSession: AudioInputCapturing, @unchecked Sendable {
    var onSamples: (@Sendable (AudioInputBufferBatch) -> Void)?

    private let operationQueue: DispatchQueue
    private let deliveryQueue: DispatchQueue
    private let renderLock = NSLock()
    private var audioUnit: AudioUnit?
    private var renderBuffer: AudioInputRenderBuffer?
    private var activeFormat: AudioInputStreamFormat?
    private lazy var callbackContextPointer: UnsafeMutableRawPointer = UnsafeMutableRawPointer(
        Unmanaged.passRetained(AudioInputCallbackContext(session: self)).toOpaque()
    )

    init(
        operationQueue: DispatchQueue = DispatchQueue(label: "GhostPepper.Audio.HALAudioInputSession"),
        deliveryQueue: DispatchQueue = DispatchQueue(label: "GhostPepper.Audio.HALAudioInputSession.Delivery")
    ) {
        self.operationQueue = operationQueue
        self.deliveryQueue = deliveryQueue
    }

    deinit {
        teardown()
        Unmanaged<AudioInputCallbackContext>.fromOpaque(callbackContextPointer).release()
    }

    func start(device: AudioInputDevice) async throws -> AudioInputStreamFormat {
        try await withCheckedThrowingContinuation { continuation in
            operationQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    let format = try self.startSynchronously(device: device)
                    continuation.resume(returning: format)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            operationQueue.async { [weak self] in
                self?.teardown()
                continuation.resume()
            }
        }
    }

    private func startSynchronously(device: AudioInputDevice) throws -> AudioInputStreamFormat {
        teardown()

        let interval = AudioDiagnostics.signposter.beginInterval(
            "AUHALStart",
            id: AudioDiagnostics.signposter.makeSignpostID()
        )
        AudioDiagnostics.logger.debug(
            "Preparing AUHAL input session for \(device.name, privacy: .public) uid=\(device.uid, privacy: .public) transport=\(device.transportDescription, privacy: .public)"
        )

        let componentDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, [componentDescription]) else {
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.componentUnavailable
        }

        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else {
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.componentUnavailable
        }

        var enableInput: UInt32 = 1
        var status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotEnableInput(status)
        }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            0,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotDisableOutput(status)
        }

        var deviceID = device.id
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotBindDevice(status)
        }

        var deviceFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            1,
            &deviceFormat,
            &propertySize
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotReadDeviceFormat(status)
        }

        var desiredFormat = AudioStreamBasicDescription(
            mSampleRate: deviceFormat.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &desiredFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotSetClientFormat(status)
        }

        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback,
            inputProcRefCon: callbackContextPointer
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotInstallCallback(status)
        }

        var maxFramesPerSlice: UInt32 = 0
        propertySize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maxFramesPerSlice,
            &propertySize
        )
        if maxFramesPerSlice == 0 {
            maxFramesPerSlice = 4096
        }

        let bufferByteCount = Int(maxFramesPerSlice) * MemoryLayout<Float>.size
        let renderBuffer = AudioInputRenderBuffer(byteCount: bufferByteCount)

        status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotInitialize(status)
        }

        status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
            throw AudioInputSessionError.cannotStart(status)
        }

        let activeFormat = AudioInputStreamFormat(
            sampleRate: desiredFormat.mSampleRate,
            channelCount: desiredFormat.mChannelsPerFrame
        )
        renderLock.withLock {
            audioUnit = unit
            self.renderBuffer = renderBuffer
            self.activeFormat = activeFormat
        }

        AudioDiagnostics.logger.debug(
            "AUHAL ready sampleRate=\(desiredFormat.mSampleRate, privacy: .public) channels=\(desiredFormat.mChannelsPerFrame, privacy: .public)"
        )
        AudioDiagnostics.signposter.endInterval("AUHALStart", interval)
        return activeFormat
    }

    private func teardown() {
        renderLock.withLock {
            if let unit = audioUnit {
                AudioOutputUnitStop(unit)
                AudioUnitUninitialize(unit)
                AudioComponentInstanceDispose(unit)
                audioUnit = nil
            }

            renderBuffer = nil
            activeFormat = nil
        }
    }

    fileprivate func handleInput(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        let (renderStatus, batch): (OSStatus, AudioInputBufferBatch?) = renderLock.withLock {
            guard let audioUnit,
                  let renderBuffer,
                  let activeFormat else {
                return (noErr, nil)
            }

            let bufferListPointer = renderBuffer.bufferListPointer
            bufferListPointer.pointee.mBuffers.mDataByteSize = inNumberFrames * UInt32(MemoryLayout<Float>.size)

            let renderStatus = AudioUnitRender(
                audioUnit,
                ioActionFlags,
                inTimeStamp,
                inBusNumber,
                inNumberFrames,
                bufferListPointer
            )
            guard renderStatus == noErr,
                  let data = bufferListPointer.pointee.mBuffers.mData else {
                return (renderStatus, nil)
            }

            let frameCount = Int(inNumberFrames)
            let samplePointer = data.assumingMemoryBound(to: Float.self)
            let samples = Array(UnsafeBufferPointer(start: samplePointer, count: frameCount))

            var sum: Float = 0
            for sample in samples {
                sum += sample * sample
            }
            let rms = sqrtf(sum / Float(max(frameCount, 1)))

            return (
                renderStatus,
                AudioInputBufferBatch(
                    samples: samples,
                    sampleRate: activeFormat.sampleRate,
                    channelCount: activeFormat.channelCount,
                    rms: rms
                )
            )
        }

        guard let batch else {
            return renderStatus
        }

        deliveryQueue.async { [onSamples] in
            onSamples?(batch)
        }
        return renderStatus
    }

    #if DEBUG
    func invokeInputCallbackForTesting(frameCount: UInt32 = 1) -> OSStatus {
        var flags = AudioUnitRenderActionFlags()
        var timeStamp = AudioTimeStamp()
        return handleInput(
            ioActionFlags: &flags,
            inTimeStamp: &timeStamp,
            inBusNumber: 1,
            inNumberFrames: frameCount
        )
    }
    #endif
}

private let halInputCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _ in
    let context = Unmanaged<AudioInputCallbackContext>.fromOpaque(refCon).takeUnretainedValue()
    guard let session = context.session else {
        return noErr
    }
    return session.handleInput(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
}
