import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hidsystem
import Synchronization

enum MicrophonePermissionStatus: Equatable {
    case authorized
    case denied
    case notDetermined
}

enum PermissionChecker {
    nonisolated(unsafe) private static let accessibilityPromptOptionKey =
        kAXTrustedCheckOptionPrompt.takeUnretainedValue()

    struct Client: Sendable {
        let checkAccessibility: @Sendable () -> Bool
        let promptAccessibility: @Sendable () -> Void
        let microphoneStatus: @Sendable () -> MicrophonePermissionStatus
        let requestMicrophoneAccess: @Sendable () async -> Bool
        let openAccessibilitySettings: @Sendable () -> Void
        let openMicrophoneSettings: @Sendable () -> Void
    }

    static let defaultClient: Client = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return Client.test
        }
        return Client.live
    }()

    private static let currentClient = Mutex(defaultClient)

    static var current: Client {
        get {
            currentClient.withLock { $0 }
        }
        set {
            currentClient.withLock { $0 = newValue }
        }
    }

    static func checkAccessibility() -> Bool {
        current.checkAccessibility()
    }

    static func promptAccessibility() {
        current.promptAccessibility()
    }

    static func microphoneStatus() -> MicrophonePermissionStatus {
        current.microphoneStatus()
    }

    static func checkMicrophone() async -> Bool {
        let status = microphoneStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await current.requestMicrophoneAccess()
        case .denied:
            return false
        }
    }

    static func openAccessibilitySettings() {
        current.openAccessibilitySettings()
    }

    static func openMicrophoneSettings() {
        current.openMicrophoneSettings()
    }

    static func checkInputMonitoring() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension PermissionChecker.Client {
    static let live = PermissionChecker.Client(
        checkAccessibility: {
            let options = [PermissionChecker.accessibilityPromptOptionKey: false] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        },
        promptAccessibility: {
            let options = [PermissionChecker.accessibilityPromptOptionKey: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        },
        microphoneStatus: {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .notDetermined:
                return .notDetermined
            default:
                return .denied
            }
        },
        requestMicrophoneAccess: {
            await AVCaptureDevice.requestAccess(for: .audio)
        },
        openAccessibilitySettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        },
        openMicrophoneSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    )

    static let test = PermissionChecker.Client(
        checkAccessibility: { false },
        promptAccessibility: {},
        microphoneStatus: { .denied },
        requestMicrophoneAccess: { false },
        openAccessibilitySettings: {},
        openMicrophoneSettings: {}
    )
}
