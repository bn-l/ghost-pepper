import Foundation
import Observation

enum AudioInputSelectionState: Equatable {
    case idle
    case connecting
    case waitingForFrames
    case ready
    case noFramesReceived
    case silentInput
    case deviceMissing
    case failed(String)
}

@MainActor
@Observable
final class AudioInputCoordinator {
    private(set) var inputDevices: [AudioInputDevice] = []
    private(set) var selectedDeviceUID: String?
    private(set) var level: Float = 0
    private(set) var selectionState: AudioInputSelectionState = .idle

    var logger: AppLogger?

    var stateDescription: String {
        let deviceName = selectedDevice?.name ?? "the selected microphone"
        switch selectionState {
        case .idle:
            return "Microphone preview is idle."
        case .connecting:
            return "Connecting to \(deviceName)..."
        case .waitingForFrames:
            return "Connected to \(deviceName). Waiting for audio..."
        case .ready:
            return selectedDevice?.isContinuityCandidate == true
                ? "Ready. Ghost Pepper is receiving audio from the Continuity microphone."
                : "Ready. Ghost Pepper is receiving audio."
        case .noFramesReceived:
            return "No audio frames arrived from \(deviceName). Reconnect it and try again."
        case .silentInput:
            return "Audio frames arrived from \(deviceName), but the signal stayed silent."
        case .deviceMissing:
            return "The selected microphone is unavailable."
        case .failed(let message):
            return message
        }
    }

    var selectedDevice: AudioInputDevice? {
        guard let selectedDeviceUID else {
            return nil
        }

        return inputDevices.first(where: { $0.uid == selectedDeviceUID })
    }

    private let defaults: UserDefaults
    private let deviceManager: AudioDeviceManaging
    private let sessionFactory: @Sendable () -> AudioInputCapturing
    private let microphonePermissionStatusProvider: () -> MicrophonePermissionStatus
    private let deviceObserverQueue = DispatchQueue(label: "GhostPepper.AudioInputCoordinator.Observers")
    private var deviceListObservation: AudioHardwareObserving?
    private var selectedDeviceStateObservations: [AudioHardwareObserving] = []
    private var previewSession: AudioInputCapturing?
    private var previewRequested = false
    private var previewSuspended = false
    private var selectionGeneration = 0
    private var frameTimeoutTask: Task<Void, Never>?
    private var silenceTimeoutTask: Task<Void, Never>?
    private var continuityWarningTask: Task<Void, Never>?
    private let frameTimeoutDuration: Duration
    private let silenceTimeoutDuration: Duration
    private let continuityWarningDuration: Duration
    private var previewIntervalState: AppLogIntervalState?
    private var firstFrameLogged = false
    private var sawNonSilentAudio = false
    private var activeSelectionID: String?

    private static let preferredInputDeviceUIDDefaultsKey = "preferredInputDeviceUID"
    private static let silenceThreshold: Float = 0.003

    init(
        defaults: UserDefaults = .standard,
        deviceManager: AudioDeviceManaging = AudioDeviceManager.shared,
        sessionFactory: @escaping @Sendable () -> AudioInputCapturing = { HALAudioInputSession() },
        microphonePermissionStatusProvider: @escaping () -> MicrophonePermissionStatus = PermissionChecker.microphoneStatus,
        frameTimeoutDuration: Duration = .seconds(8),
        silenceTimeoutDuration: Duration = .seconds(3),
        continuityWarningDuration: Duration = .seconds(5)
    ) {
        self.defaults = defaults
        self.deviceManager = deviceManager
        self.sessionFactory = sessionFactory
        self.microphonePermissionStatusProvider = microphonePermissionStatusProvider
        self.frameTimeoutDuration = frameTimeoutDuration
        self.silenceTimeoutDuration = silenceTimeoutDuration
        self.continuityWarningDuration = continuityWarningDuration

        deviceListObservation = deviceManager.addInputDeviceListObserver(queue: deviceObserverQueue) { [weak self] in
            Task { @MainActor in
                self?.handleDeviceListChange()
            }
        }

        refreshDevices()
    }

    deinit {
        MainActor.assumeIsolated {
            deviceListObservation?.invalidate()
            selectedDeviceStateObservations.forEach { $0.invalidate() }
            frameTimeoutTask?.cancel()
            silenceTimeoutTask?.cancel()
            continuityWarningTask?.cancel()
        }
    }

    func refreshDevices() {
        let previousSelectedDevice = selectedDevice
        inputDevices = deviceManager.listInputDevices()

        let persistedUID = defaults.string(forKey: Self.preferredInputDeviceUIDDefaultsKey)
        let resolvedUID = if let persistedUID,
                             inputDevices.contains(where: { $0.uid == persistedUID }) {
            persistedUID
        } else {
            deviceManager.defaultInputDevice()?.uid ?? inputDevices.first?.uid
        }

        selectedDeviceUID = resolvedUID
        if let resolvedUID {
            defaults.set(resolvedUID, forKey: Self.preferredInputDeviceUIDDefaultsKey)
        }

        updateSelectedDeviceObservers()

        if let previousSelectedDevice,
           inputDevices.contains(where: { $0.uid == previousSelectedDevice.uid }) == false {
            if let replacementDevice = selectedDevice {
                log(
                    event: "selection.fallback_after_disappearance",
                    "Selected audio input disappeared: name=\(previousSelectedDevice.name) uid=\(previousSelectedDevice.uid). Falling back to name=\(replacementDevice.name) uid=\(replacementDevice.uid)"
                )
            } else {
                log(
                    event: "selection.disappeared",
                    "Selected audio input disappeared: name=\(previousSelectedDevice.name) uid=\(previousSelectedDevice.uid)"
                )
            }
        }

        if resolvedUID == nil {
            selectionState = .deviceMissing
            level = 0
            log(event: "inventory.empty", "No audio input devices are available.")
            return
        }

        if let selectedDevice, selectedDevice.isAlive == false {
            selectionState = .deviceMissing
            level = 0
            log(event: "selection.not_alive", "Selected audio input device is not alive: name=\(selectedDevice.name) uid=\(selectedDevice.uid)")
            return
        }

        if previewRequested && !previewSuspended {
            restartPreview()
        }
    }

    func selectDevice(uid: String) {
        guard selectedDeviceUID != uid else {
            return
        }

        selectedDeviceUID = uid
        defaults.set(uid, forKey: Self.preferredInputDeviceUIDDefaultsKey)
        updateSelectedDeviceObservers()

        if let selectedDevice {
            log(
                event: "selection.requested",
                "Audio device selection requested: name=\(selectedDevice.name) uid=\(selectedDevice.uid) id=\(selectedDevice.id) transport=\(selectedDevice.transportDescription) continuity=\(selectedDevice.isContinuityCandidate)"
            )
        } else {
            log(event: "selection.requested_missing", "Audio device selection requested for missing uid=\(uid)")
        }

        if previewRequested && !previewSuspended {
            restartPreview()
        }
    }

    func setPreviewActive(_ active: Bool) {
        previewRequested = active
        if active {
            restartPreview()
        } else {
            Task {
                await stopPreview(resetState: true)
            }
        }
    }

    func pausePreviewForCapture() async {
        previewSuspended = true
        await stopPreview(resetState: false)
    }

    func resumePreviewAfterCapture() {
        previewSuspended = false
        if previewRequested {
            restartPreview()
        }
    }

    private func handleDeviceListChange() {
        log(event: "inventory.changed", "Audio device list changed. Refreshing available microphones.")
        refreshDevices()
    }

    private func updateSelectedDeviceObservers() {
        selectedDeviceStateObservations.forEach { $0.invalidate() }
        selectedDeviceStateObservations = []

        guard let selectedDevice else {
            return
        }

        selectedDeviceStateObservations = deviceManager.addStateObservers(
            for: selectedDevice,
            queue: deviceObserverQueue
        ) { [weak self] in
            Task { @MainActor in
                self?.handleSelectedDeviceStateChange()
            }
        }
    }

    private func handleSelectedDeviceStateChange() {
        guard let selectedDeviceUID else {
            selectionState = .deviceMissing
            return
        }

        if let refreshedDevice = deviceManager.inputDevice(uid: selectedDeviceUID) {
            if let index = inputDevices.firstIndex(where: { $0.uid == refreshedDevice.uid }) {
                inputDevices[index] = refreshedDevice
            } else {
                inputDevices.append(refreshedDevice)
            }

            if refreshedDevice.isAlive == false {
                selectionState = .deviceMissing
                level = 0
                log(event: "selection.became_unavailable", "Selected audio input became unavailable: name=\(refreshedDevice.name) uid=\(refreshedDevice.uid)")
                Task {
                    await stopPreview(resetState: false)
                }
            } else {
                log(
                    event: "selection.state_changed",
                    "Selected audio input state changed: name=\(refreshedDevice.name) uid=\(refreshedDevice.uid) transport=\(refreshedDevice.transportDescription)"
                )
            }
        } else {
            selectionState = .deviceMissing
            level = 0
            log(event: "selection.disappeared", "Selected audio input disappeared: uid=\(selectedDeviceUID)")
            Task {
                await stopPreview(resetState: false)
            }
        }
    }

    private func restartPreview() {
        guard previewRequested, !previewSuspended else {
            return
        }

        guard microphonePermissionStatusProvider() == .authorized else {
            selectionState = .failed("Microphone access is required before Ghost Pepper can preview the selected input.")
            level = 0
            return
        }

        guard let selectedDevice else {
            selectionState = .deviceMissing
            level = 0
            return
        }

        selectionGeneration += 1
        let generation = selectionGeneration
        activeSelectionID = UUID().uuidString
        firstFrameLogged = false
        sawNonSilentAudio = false
        level = 0
        selectionState = .connecting
        frameTimeoutTask?.cancel()
        silenceTimeoutTask?.cancel()
        continuityWarningTask?.cancel()

        previewIntervalState = logger?.beginInterval(
            "audio_selection",
            "Starting audio preview for the selected device.",
            fields: logFields(for: selectedDevice)
        )
        log(
            event: "preview.starting",
            "Starting audio preview for name=\(selectedDevice.name) uid=\(selectedDevice.uid) id=\(selectedDevice.id) transport=\(selectedDevice.transportDescription) continuity=\(selectedDevice.isContinuityCandidate)"
        )

        Task { [weak self] in
            guard let self else { return }
            await self.stopPreview(resetState: false)

            let session = sessionFactory()
            session.onSamples = { [weak self] batch in
                Task { @MainActor in
                    self?.handleSampleBatch(batch, generation: generation)
                }
            }

            previewSession = session

            do {
                let format = try await session.start(device: selectedDevice)
                guard generation == selectionGeneration else {
                    await session.stop()
                    return
                }

                selectionState = .waitingForFrames
                log(
                    event: "preview.connected",
                    "Audio preview connected sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount) continuity=\(selectedDevice.isContinuityCandidate)"
                )
                scheduleTimeouts(for: selectedDevice, generation: generation)
            } catch {
                guard generation == selectionGeneration else {
                    return
                }

                selectionState = .failed("Could not start audio preview: \(error.localizedDescription)")
                level = 0
                finishPreviewInterval()
                log(event: "preview.failed", "Audio preview failed: \(error.localizedDescription)", error: error)
            }
        }
    }

    private func scheduleTimeouts(for device: AudioInputDevice, generation: Int) {
        let frameTimeoutDuration = self.frameTimeoutDuration
        frameTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: frameTimeoutDuration)
            await MainActor.run {
                guard let self,
                      generation == self.selectionGeneration,
                      self.selectionState == .waitingForFrames else {
                    return
                }

                self.selectionState = .noFramesReceived
                self.level = 0
                self.finishPreviewInterval()
                self.log(
                    event: "preview.no_frames",
                    "Audio preview timed out with no frames: name=\(device.name) uid=\(device.uid) continuity=\(device.isContinuityCandidate)"
                )
            }
        }

        if device.isContinuityCandidate {
            let continuityWarningDuration = self.continuityWarningDuration
            continuityWarningTask = Task { [weak self] in
                try? await Task.sleep(for: continuityWarningDuration)
                await MainActor.run {
                    guard let self,
                          generation == self.selectionGeneration,
                          self.selectionState == .connecting || self.selectionState == .waitingForFrames else {
                        return
                    }

                    self.log(
                        event: "preview.continuity_slow_start",
                        "Continuity audio input is still starting: name=\(device.name) uid=\(device.uid)"
                    )
                }
            }
        }
    }

    private func handleSampleBatch(_ batch: AudioInputBufferBatch, generation: Int) {
        guard generation == selectionGeneration else {
            return
        }

        if !firstFrameLogged {
            firstFrameLogged = true
            log(
                event: "preview.first_frames",
                "Received first audio frames sampleRate=\(Int(batch.sampleRate)) channels=\(batch.channelCount) rms=\(String(format: "%.4f", batch.rms))"
            )
        }

        frameTimeoutTask?.cancel()
        level = min(batch.rms * 10, 1.0)

        if batch.rms > Self.silenceThreshold {
            sawNonSilentAudio = true
            if selectionState != .ready {
                selectionState = .ready
                finishPreviewInterval()
                log(event: "preview.ready", "Audio preview is ready and receiving non-silent input.")
            }
            silenceTimeoutTask?.cancel()
            return
        }

        guard silenceTimeoutTask == nil else {
            return
        }

        let silenceTimeoutDuration = self.silenceTimeoutDuration
        silenceTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: silenceTimeoutDuration)
            await MainActor.run {
                guard let self,
                      generation == self.selectionGeneration,
                      self.sawNonSilentAudio == false else {
                    return
                }

                self.selectionState = .silentInput
                self.finishPreviewInterval()
                self.log(event: "preview.silent_input", "Audio preview received frames but the signal stayed silent.")
            }
        }
    }

    private func stopPreview(resetState: Bool) async {
        frameTimeoutTask?.cancel()
        frameTimeoutTask = nil
        silenceTimeoutTask?.cancel()
        silenceTimeoutTask = nil
        continuityWarningTask?.cancel()
        continuityWarningTask = nil
        firstFrameLogged = false
        sawNonSilentAudio = false

        if let previewSession {
            await previewSession.stop()
            self.previewSession = nil
        }

        if resetState {
            selectionState = .idle
            level = 0
            finishPreviewInterval()
            activeSelectionID = nil
        }
    }

    private func finishPreviewInterval() {
        if let previewIntervalState {
            logger?.endInterval(previewIntervalState, "Audio preview interval completed.")
            self.previewIntervalState = nil
        }
    }

    private func log(
        event: String,
        _ message: String,
        error: Error? = nil
    ) {
        let fields = selectedDevice.map(logFields(for:)) ?? [:]
        if let error {
            logger?.warning(event, message, fields: fields, error: error)
        } else {
            logger?.info(event, message, fields: fields)
        }
    }

    private func logFields(for device: AudioInputDevice) -> [String: String] {
        var fields = [
            "deviceName": device.name,
            "deviceUID": device.uid,
            "deviceID": String(device.id),
            "transport": device.transportDescription,
            "continuity": String(device.isContinuityCandidate),
            "isAlive": String(device.isAlive)
        ]
        if let activeSelectionID {
            fields["audioSelectionID"] = activeSelectionID
        }
        return fields
    }
}
