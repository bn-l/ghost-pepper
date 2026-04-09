import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isAlive: Bool
    let transportType: UInt32

    var isContinuityCandidate: Bool {
        switch transportType {
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless,
             kAudioDeviceTransportTypeContinuityCapture:
            return true
        default:
            let loweredName = name.lowercased()
            let loweredUID = uid.lowercased()
            return loweredName.contains("iphone")
                || loweredName.contains("continuity")
                || loweredUID.contains("iphone")
                || loweredUID.contains("continuity")
        }
    }

    var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeBluetooth:
            return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth-le"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay"
        case kAudioDeviceTransportTypeContinuityCaptureWired:
            return "continuity-wired"
        case kAudioDeviceTransportTypeContinuityCaptureWireless:
            return "continuity-wireless"
        case kAudioDeviceTransportTypeContinuityCapture:
            return "continuity"
        default:
            return "0x" + String(transportType, radix: 16)
        }
    }
}

protocol AudioHardwareObserving: AnyObject {
    func invalidate()
}

protocol AudioDeviceManaging: AnyObject {
    func listInputDevices() -> [AudioInputDevice]
    func defaultInputDevice() -> AudioInputDevice?
    func inputDevice(uid: String) -> AudioInputDevice?
    func addInputDeviceListObserver(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioHardwareObserving?
    func addStateObservers(
        for device: AudioInputDevice,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> [AudioHardwareObserving]
}

final class AudioDeviceManager: AudioDeviceManaging, @unchecked Sendable {
    static let shared = AudioDeviceManager()

    func listInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return []
        }

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceIDs
        ) == noErr else {
            return []
        }

        return deviceIDs.compactMap(inputDevice(deviceID:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultInputDevice() -> AudioInputDevice? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return nil
        }

        return inputDevice(deviceID: deviceID)
    }

    func inputDevice(uid: String) -> AudioInputDevice? {
        var mutableUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var translation = AudioValueTranslation(
            mInputData: &mutableUID,
            mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &translation
        ) == noErr else {
            return nil
        }

        return inputDevice(deviceID: deviceID)
    }

    func addInputDeviceListObserver(
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> AudioHardwareObserving? {
        AudioObjectPropertyObservation(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            queue: queue,
            handler: handler
        )
    }

    func addStateObservers(
        for device: AudioInputDevice,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> [AudioHardwareObserving] {
        [
            AudioObjectPropertyObservation(
                objectID: device.id,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: queue,
                handler: handler
            ),
            AudioObjectPropertyObservation(
                objectID: device.id,
                selector: kAudioDevicePropertyDeviceIsRunning,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: queue,
                handler: handler
            ),
            AudioObjectPropertyObservation(
                objectID: device.id,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                queue: queue,
                handler: handler
            )
        ]
        .compactMap { $0 }
    }

    private func inputDevice(deviceID: AudioDeviceID) -> AudioInputDevice? {
        guard hasInputChannels(deviceID: deviceID),
              let uid = deviceUID(deviceID: deviceID),
              let name = deviceName(deviceID: deviceID) else {
            return nil
        }

        return AudioInputDevice(
            id: deviceID,
            uid: uid,
            name: name,
            isAlive: isDeviceAlive(deviceID: deviceID),
            transportType: transportType(deviceID: deviceID)
        )
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rawPointer) == noErr else {
            return false
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func deviceUID(deviceID: AudioDeviceID) -> String? {
        stringProperty(
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        )
    }

    private func deviceName(deviceID: AudioDeviceID) -> String? {
        stringProperty(
            selector: kAudioDevicePropertyDeviceNameCFString,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        )
    }

    private func isDeviceAlive(deviceID: AudioDeviceID) -> Bool {
        uint32Property(
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) != 0
    }

    private func transportType(deviceID: AudioDeviceID) -> UInt32 {
        uint32Property(
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) ?? kAudioDeviceTransportTypeUnknown
    }

    private func stringProperty(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }

        return value?.takeRetainedValue() as String?
    }

    private func uint32Property(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }

        return value
    }
}

private final class AudioObjectPropertyObservation: AudioHardwareObserving {
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var isActive = false

    init?(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) {
        self.objectID = objectID
        self.address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        self.queue = queue
        self.block = { _, _ in
            handler()
        }

        var mutableAddress = self.address
        guard AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        ) == noErr else {
            return nil
        }

        isActive = true
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        guard isActive else {
            return
        }

        var mutableAddress = address
        AudioObjectRemovePropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        )
        isActive = false
    }
}
