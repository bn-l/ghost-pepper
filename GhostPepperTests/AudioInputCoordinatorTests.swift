import XCTest
import CoreAudio
@testable import GhostPepper

private final class FakeAudioHardwareObservation: AudioHardwareObserving {
    func invalidate() {}
}

private final class FakeAudioDeviceManager: AudioDeviceManaging {
    var devices: [AudioInputDevice]
    var defaultDeviceUID: String?
    var listObserver: (() -> Void)?
    var stateObservers: [String: () -> Void] = [:]

    init(devices: [AudioInputDevice], defaultDeviceUID: String? = nil) {
        self.devices = devices
        self.defaultDeviceUID = defaultDeviceUID
    }

    func listInputDevices() -> [AudioInputDevice] {
        devices
    }

    func defaultInputDevice() -> AudioInputDevice? {
        if let defaultDeviceUID {
            return inputDevice(uid: defaultDeviceUID)
        }

        return devices.first
    }

    func inputDevice(uid: String) -> AudioInputDevice? {
        devices.first(where: { $0.uid == uid })
    }

    func addInputDeviceListObserver(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioHardwareObserving? {
        listObserver = {
            queue.async(execute: handler)
        }
        return FakeAudioHardwareObservation()
    }

    func addStateObservers(
        for device: AudioInputDevice,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> [AudioHardwareObserving] {
        stateObservers[device.uid] = {
            queue.async(execute: handler)
        }
        return [FakeAudioHardwareObservation()]
    }

    func triggerDeviceListChange() {
        listObserver?()
    }

    func triggerStateChange(for uid: String) {
        stateObservers[uid]?()
    }
}

private final class FakeAudioInputSession: AudioInputCapturing, @unchecked Sendable {
    var onSamples: (@Sendable (AudioInputBufferBatch) -> Void)?
    var startDelay: Duration = .zero
    var startError: Error?
    var startResult = AudioInputStreamFormat(sampleRate: 48_000, channelCount: 1)
    private(set) var startedDevices: [AudioInputDevice] = []
    private(set) var stopCallCount = 0

    func start(device: AudioInputDevice) async throws -> AudioInputStreamFormat {
        startedDevices.append(device)
        if startDelay > .zero {
            try? await Task.sleep(for: startDelay)
        }
        if let startError {
            throw startError
        }
        return startResult
    }

    func stop() async {
        stopCallCount += 1
    }

    func emit(samples: [Float], sampleRate: Double = 48_000, rms: Float? = nil) {
        let calculatedRMS: Float
        if let rms {
            calculatedRMS = rms
        } else if samples.isEmpty {
            calculatedRMS = 0
        } else {
            let sum = samples.reduce(Float.zero) { partialResult, sample in
                partialResult + (sample * sample)
            }
            calculatedRMS = sqrtf(sum / Float(samples.count))
        }

        onSamples?(
            AudioInputBufferBatch(
                samples: samples,
                sampleRate: sampleRate,
                channelCount: 1,
                rms: calculatedRMS
            )
        )
    }
}

@MainActor
final class AudioInputCoordinatorTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeDevice(
        uid: String,
        name: String,
        transportType: UInt32 = kAudioDeviceTransportTypeBuiltIn,
        isAlive: Bool = true
    ) -> AudioInputDevice {
        let hashedID = uid.utf8.reduce(UInt32(5381)) { partialResult, byte in
            ((partialResult << 5) &+ partialResult) &+ UInt32(byte)
        }
        return AudioInputDevice(
            id: AudioDeviceID(max(hashedID, 1)),
            uid: uid,
            name: name,
            isAlive: isAlive,
            transportType: transportType
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date.now.addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date.now < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTFail("Condition was not met before timeout.", file: file, line: line)
    }

    func testCoordinatorPersistsPreferredDeviceUIDSelection() throws {
        let defaults = try makeDefaults()
        let builtIn = makeDevice(uid: "builtin", name: "MacBook Microphone")
        let iphone = makeDevice(
            uid: "iphone-mic",
            name: "Ben's iPhone Microphone",
            transportType: kAudioDeviceTransportTypeContinuityCaptureWireless
        )
        let deviceManager = FakeAudioDeviceManager(
            devices: [builtIn, iphone],
            defaultDeviceUID: builtIn.uid
        )
        let session = FakeAudioInputSession()
        let coordinator = AudioInputCoordinator(
            defaults: defaults,
            deviceManager: deviceManager,
            sessionFactory: { session },
            microphonePermissionStatusProvider: { .authorized }
        )

        XCTAssertEqual(coordinator.selectedDeviceUID, builtIn.uid)

        coordinator.selectDevice(uid: iphone.uid)

        XCTAssertEqual(coordinator.selectedDeviceUID, iphone.uid)
        XCTAssertEqual(defaults.string(forKey: "preferredInputDeviceUID"), iphone.uid)
        XCTAssertTrue(coordinator.selectedDevice?.isContinuityCandidate == true)
    }

    func testPreviewTransitionsFromConnectingToReadyAfterReceivingNonSilentAudio() async throws {
        let defaults = try makeDefaults()
        let iphone = makeDevice(
            uid: "iphone-mic",
            name: "Ben's iPhone Microphone",
            transportType: kAudioDeviceTransportTypeContinuityCaptureWireless
        )
        let deviceManager = FakeAudioDeviceManager(devices: [iphone], defaultDeviceUID: iphone.uid)
        let session = FakeAudioInputSession()
        session.startDelay = .milliseconds(100)
        let logging = makeTestLogger(category: .audio)
        let coordinator = AudioInputCoordinator(
            defaults: defaults,
            deviceManager: deviceManager,
            sessionFactory: { session },
            microphonePermissionStatusProvider: { .authorized }
        )
        coordinator.logger = logging.logger

        coordinator.setPreviewActive(true)
        XCTAssertEqual(coordinator.selectionState, .connecting)

        await waitUntil {
            coordinator.selectionState == .waitingForFrames
        }

        session.emit(samples: [0.2, 0.15, -0.2], rms: 0.18)

        await waitUntil {
            coordinator.selectionState == .ready
        }

        XCTAssertGreaterThan(coordinator.level, 0)
        XCTAssertTrue(logging.observer.records.contains(where: { $0.event == "preview.starting" }))
        XCTAssertTrue(logging.observer.records.contains(where: { $0.event == "preview.first_frames" }))
        XCTAssertTrue(logging.observer.records.contains(where: { $0.event == "preview.ready" }))
    }

    func testPreviewMarksNoFramesReceivedWhenInputNeverStartsDeliveringAudio() async throws {
        let defaults = try makeDefaults()
        let builtIn = makeDevice(uid: "builtin", name: "MacBook Microphone")
        let deviceManager = FakeAudioDeviceManager(devices: [builtIn], defaultDeviceUID: builtIn.uid)
        let session = FakeAudioInputSession()
        let coordinator = AudioInputCoordinator(
            defaults: defaults,
            deviceManager: deviceManager,
            sessionFactory: { session },
            microphonePermissionStatusProvider: { .authorized },
            frameTimeoutDuration: .milliseconds(50),
            silenceTimeoutDuration: .milliseconds(50)
        )

        coordinator.setPreviewActive(true)

        await waitUntil {
            coordinator.selectionState == .noFramesReceived
        }
    }

    func testPreviewMarksSilentInputWhenFramesArriveWithoutSignal() async throws {
        let defaults = try makeDefaults()
        let builtIn = makeDevice(uid: "builtin", name: "MacBook Microphone")
        let deviceManager = FakeAudioDeviceManager(devices: [builtIn], defaultDeviceUID: builtIn.uid)
        let session = FakeAudioInputSession()
        let coordinator = AudioInputCoordinator(
            defaults: defaults,
            deviceManager: deviceManager,
            sessionFactory: { session },
            microphonePermissionStatusProvider: { .authorized },
            frameTimeoutDuration: .milliseconds(250),
            silenceTimeoutDuration: .milliseconds(50)
        )

        coordinator.setPreviewActive(true)
        await waitUntil {
            coordinator.selectionState == .waitingForFrames
        }

        session.emit(samples: [0, 0, 0, 0], rms: 0)

        await waitUntil {
            coordinator.selectionState == .silentInput
        }
    }

    func testPreviewTransitionsToDeviceMissingWhenSelectedMicrophoneDisappears() async throws {
        let defaults = try makeDefaults()
        let builtIn = makeDevice(uid: "builtin", name: "MacBook Microphone")
        let deviceManager = FakeAudioDeviceManager(devices: [builtIn], defaultDeviceUID: builtIn.uid)
        let session = FakeAudioInputSession()
        let logging = makeTestLogger(category: .audio)
        let coordinator = AudioInputCoordinator(
            defaults: defaults,
            deviceManager: deviceManager,
            sessionFactory: { session },
            microphonePermissionStatusProvider: { .authorized }
        )
        coordinator.logger = logging.logger

        coordinator.setPreviewActive(true)
        await waitUntil {
            coordinator.selectionState == .waitingForFrames
        }

        deviceManager.devices = []
        deviceManager.triggerDeviceListChange()

        await waitUntil {
            coordinator.selectionState == .deviceMissing
        }

        XCTAssertTrue(
            logging.observer.records.contains(where: {
                $0.event == "selection.became_unavailable" || $0.event == "selection.disappeared"
            })
        )
    }

    func testContinuityTransportIsTaggedAsContinuityCandidate() {
        let continuityDevice = makeDevice(
            uid: "iphone-mic",
            name: "Ben's iPhone Microphone",
            transportType: kAudioDeviceTransportTypeContinuityCaptureWireless
        )
        let usbDevice = makeDevice(
            uid: "usb-mic",
            name: "USB Microphone",
            transportType: kAudioDeviceTransportTypeUSB
        )

        XCTAssertTrue(continuityDevice.isContinuityCandidate)
        XCTAssertFalse(usbDevice.isContinuityCandidate)
    }
}
