import Foundation

struct PerformanceTrace {
    let sessionID: String
    let hotkeyInteractionID: String
    let recordingSessionID: String
    let transcriptionSessionID: String
    let cleanupSessionID: String
    let pasteSessionID: String
    let startedAt: Date

    var hotkeyDetectedAt: Date?
    var micLiveAt: Date?
    var hotkeyLiftedAt: Date?
    var micColdAt: Date?
    var transcriptionStartAt: Date?
    var transcriptionEndAt: Date?
    var cleanupStartAt: Date?
    var cleanupEndAt: Date?
    var ocrCaptureDuration: TimeInterval?
    var promptBuildDuration: TimeInterval?
    var modelCallDuration: TimeInterval?
    var postProcessDuration: TimeInterval?
    var pasteStartAt: Date?
    var pasteEndAt: Date?

    init(sessionID: String, startedAt: Date = .now) {
        self.sessionID = sessionID
        self.hotkeyInteractionID = "\(sessionID)-hotkey"
        self.recordingSessionID = "\(sessionID)-recording"
        self.transcriptionSessionID = "\(sessionID)-transcription"
        self.cleanupSessionID = "\(sessionID)-cleanup"
        self.pasteSessionID = "\(sessionID)-paste"
        self.startedAt = startedAt
    }

    var logContext: AppLogContext {
        AppLogContext(
            hotkeyInteractionID: hotkeyInteractionID,
            recordingSessionID: recordingSessionID,
            transcriptionSessionID: transcriptionSessionID,
            cleanupSessionID: cleanupSessionID,
            pasteSessionID: pasteSessionID
        )
    }

    func fields(
        speechModelID: String,
        cleanupBackend: CleanupBackendOption,
        cleanupAttempted: Bool
    ) -> [String: String] {
        [
            "sessionID": sessionID,
            "speechModelID": speechModelID,
            "cleanupBackend": cleanupBackend.rawValue,
            "hotkeyToMicLiveMS": durationMilliseconds(from: hotkeyDetectedAt, to: micLiveAt),
            "hotkeyLiftToMicColdMS": durationMilliseconds(from: hotkeyLiftedAt, to: micColdAt),
            "transcriptionMS": durationMilliseconds(from: transcriptionStartAt, to: transcriptionEndAt),
            "cleanupMS": cleanupAttempted ? durationMilliseconds(from: cleanupStartAt, to: cleanupEndAt) : "skipped",
            "ocrMS": cleanupAttempted ? durationMilliseconds(ocrCaptureDuration) : "skipped",
            "promptBuildMS": cleanupAttempted ? durationMilliseconds(promptBuildDuration) : "skipped",
            "modelCallMS": cleanupAttempted ? durationMilliseconds(modelCallDuration) : "skipped",
            "postProcessMS": cleanupAttempted ? durationMilliseconds(postProcessDuration) : "skipped",
            "pasteMS": durationMilliseconds(from: pasteStartAt, to: pasteEndAt),
            "totalMS": durationMilliseconds(from: startedAt, to: pasteEndAt)
        ]
    }

    func summary(
        speechModelID: String,
        cleanupBackend: CleanupBackendOption,
        cleanupAttempted: Bool
    ) -> String {
        let fields = fields(
            speechModelID: speechModelID,
            cleanupBackend: cleanupBackend,
            cleanupAttempted: cleanupAttempted
        )
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
    }

    private func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else {
            return "n/a"
        }

        return Self.format(duration: end.timeIntervalSince(start))
    }

    private func duration(from start: Date, to end: Date?) -> String {
        guard let end else {
            return "n/a"
        }

        return Self.format(duration: end.timeIntervalSince(start))
    }

    private func duration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "n/a"
        }

        return Self.format(duration: duration)
    }

    private func durationMilliseconds(from start: Date?, to end: Date?) -> String {
        guard let start, let end else {
            return "n/a"
        }

        return String(Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func durationMilliseconds(from start: Date, to end: Date?) -> String {
        guard let end else {
            return "n/a"
        }

        return String(Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private func durationMilliseconds(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "n/a"
        }

        return String(Int((duration * 1000).rounded()))
    }

    private static func format(duration: TimeInterval) -> String {
        "\(Int((duration * 1000).rounded()))ms"
    }
}
