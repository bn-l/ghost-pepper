import Foundation
import OSLog

enum AppLogCategory: String, CaseIterable, Codable, Identifiable {
    case app
    case audio
    case permissions
    case hotkey
    case recording
    case transcription
    case cleanup
    case ocr
    case paste
    case learning
    case model
    case ui
    case performance
    case storage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .app:
            return "App"
        case .audio:
            return "Audio"
        case .permissions:
            return "Permissions"
        case .hotkey:
            return "Hotkey"
        case .recording:
            return "Recording"
        case .transcription:
            return "Transcription"
        case .cleanup:
            return "Cleanup"
        case .ocr:
            return "OCR"
        case .paste:
            return "Paste"
        case .learning:
            return "Learning"
        case .model:
            return "Model"
        case .ui:
            return "UI"
        case .performance:
            return "Performance"
        case .storage:
            return "Storage"
        }
    }
}

enum AppLogLevel: String, CaseIterable, Codable, Identifiable {
    case trace
    case info
    case notice
    case warning
    case error

    var id: String { rawValue }

    var displayName: String {
        rawValue.capitalized
    }

    var osLogType: OSLogType {
        switch self {
        case .trace:
            return .debug
        case .info:
            return .info
        case .notice:
            return .default
        case .warning:
            return .default
        case .error:
            return .error
        }
    }
}

enum ObservabilityMode: String, CaseIterable, Identifiable {
    case info
    case trace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info:
            return "Info"
        case .trace:
            return "Trace"
        }
    }
}

struct ObservabilityConfig: Equatable {
    static let defaultsKey = "observabilityMode"
    static let launchArgument = "--ghost-pepper-observability=trace"
    static let launchArgumentTrace = "--ghost-pepper-trace-logs"
    static let environmentKey = "GHOST_PEPPER_OBSERVABILITY"

    let mode: ObservabilityMode

    var includesTrace: Bool {
        mode == .trace
    }

    static func resolve(
        defaults: UserDefaults = .standard,
        processInfo: ProcessInfo = .processInfo
    ) -> ObservabilityConfig {
        let arguments = processInfo.arguments
        if arguments.contains(Self.launchArgument) || arguments.contains(Self.launchArgumentTrace) {
            return ObservabilityConfig(mode: .trace)
        }

        if let environmentValue = processInfo.environment[Self.environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           environmentValue.caseInsensitiveCompare("trace") == .orderedSame {
            return ObservabilityConfig(mode: .trace)
        }

        let persistedMode = ObservabilityMode(
            rawValue: defaults.string(forKey: Self.defaultsKey) ?? ""
        ) ?? .info
        return ObservabilityConfig(mode: persistedMode)
    }
}

struct AppLogContext: Codable, Equatable {
    var appSessionID: String? = nil
    var hotkeyInteractionID: String? = nil
    var audioSelectionID: String? = nil
    var recordingSessionID: String? = nil
    var transcriptionSessionID: String? = nil
    var cleanupSessionID: String? = nil
    var pasteSessionID: String? = nil

    static let empty = AppLogContext()

    func merged(with other: AppLogContext) -> AppLogContext {
        AppLogContext(
            appSessionID: other.appSessionID ?? appSessionID,
            hotkeyInteractionID: other.hotkeyInteractionID ?? hotkeyInteractionID,
            audioSelectionID: other.audioSelectionID ?? audioSelectionID,
            recordingSessionID: other.recordingSessionID ?? recordingSessionID,
            transcriptionSessionID: other.transcriptionSessionID ?? transcriptionSessionID,
            cleanupSessionID: other.cleanupSessionID ?? cleanupSessionID,
            pasteSessionID: other.pasteSessionID ?? pasteSessionID
        )
    }

    var fields: [String: String] {
        var fields: [String: String] = [:]
        fields["appSessionID"] = appSessionID
        fields["hotkeyInteractionID"] = hotkeyInteractionID
        fields["audioSelectionID"] = audioSelectionID
        fields["recordingSessionID"] = recordingSessionID
        fields["transcriptionSessionID"] = transcriptionSessionID
        fields["cleanupSessionID"] = cleanupSessionID
        fields["pasteSessionID"] = pasteSessionID
        return fields.compactMapValues { $0 }
    }

    var searchableSessionIDs: [String] {
        [
            appSessionID,
            hotkeyInteractionID,
            audioSelectionID,
            recordingSessionID,
            transcriptionSessionID,
            cleanupSessionID,
            pasteSessionID
        ].compactMap { $0 }
    }
}

struct AppLogErrorMetadata: Codable, Equatable {
    let domain: String
    let code: Int
    let description: String

    init(error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        description = nsError.localizedDescription
    }
}

struct AppLogRecord: Identifiable, Codable, Equatable {
    static let messagePrefix = "GPLOG "

    let id: UUID
    let timestamp: Date
    let category: AppLogCategory
    let level: AppLogLevel
    let event: String
    let message: String
    let fields: [String: String]
    let context: AppLogContext
    let error: AppLogErrorMetadata?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        category: AppLogCategory,
        level: AppLogLevel,
        event: String,
        message: String,
        fields: [String: String] = [:],
        context: AppLogContext = .empty,
        error: AppLogErrorMetadata? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.event = event
        self.message = message
        self.fields = fields
        self.context = context
        self.error = error
    }

    func merged(with additionalFields: [String: String]) -> AppLogRecord {
        AppLogRecord(
            id: id,
            timestamp: timestamp,
            category: category,
            level: level,
            event: event,
            message: message,
            fields: fields.merging(additionalFields, uniquingKeysWith: { _, new in new }),
            context: context,
            error: error
        )
    }

    var encodedMessage: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return Self.messagePrefix + #"{"event":"encoding_failure","message":"Failed to encode AppLogRecord"}"#
        }
        return Self.messagePrefix + text
    }

    var searchableText: String {
        let errorText = error.map { "\($0.domain) \($0.code) \($0.description)" } ?? ""
        let fieldText = fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let contextText = context.fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return [event, message, fieldText, contextText, errorText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func decode(from composedMessage: String) -> AppLogRecord? {
        guard composedMessage.hasPrefix(Self.messagePrefix) else {
            return nil
        }

        let payload = String(composedMessage.dropFirst(Self.messagePrefix.count))
        guard let data = payload.data(using: .utf8) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(AppLogRecord.self, from: data)
    }
}

struct AppLogIntervalState {
    static let signpostName: StaticString = "AppInterval"

    let event: String
    let startRecord: AppLogRecord
    let signposter: OSSignposter
    let state: OSSignpostIntervalState
}

protocol AppLogRecordObserving: AnyObject {
    func didRecord(_ record: AppLogRecord)
}

final class AppLogSystem: @unchecked Sendable {
    static let defaultSubsystem = "com.github.matthartman.ghostpepper"

    private let subsystem: String
    private let configProvider: () -> ObservabilityConfig
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var loggers: [AppLogCategory: Logger] = [:]
    private var signposters: [AppLogCategory: OSSignposter] = [:]

    weak var observer: AppLogRecordObserving?

    init(
        subsystem: String = AppLogSystem.defaultSubsystem,
        configProvider: @escaping () -> ObservabilityConfig,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.subsystem = subsystem
        self.configProvider = configProvider
        self.now = now
    }

    func logger(
        category: AppLogCategory,
        contextProvider: @escaping () -> AppLogContext = { .empty }
    ) -> AppLogger {
        AppLogger(
            system: self,
            category: category,
            contextProvider: contextProvider
        )
    }

    fileprivate func record(
        category: AppLogCategory,
        level: AppLogLevel,
        event: String,
        message: String,
        fields: [String: String],
        context: AppLogContext,
        error: Error?
    ) {
        guard level != .trace || configProvider().includesTrace else {
            return
        }

        let record = AppLogRecord(
            timestamp: now(),
            category: category,
            level: level,
            event: event,
            message: message,
            fields: fields,
            context: context,
            error: error.map(AppLogErrorMetadata.init(error:))
        )

        observer?.didRecord(record)
        let logger = logger(for: category)
        logger.log(level: level.osLogType, "\(record.encodedMessage, privacy: .public)")
    }

    fileprivate func beginInterval(
        category: AppLogCategory,
        event: String,
        message: String,
        fields: [String: String],
        context: AppLogContext
    ) -> AppLogIntervalState {
        let signposter = signposter(for: category)
        let state = signposter.beginInterval(AppLogIntervalState.signpostName, id: signposter.makeSignpostID())
        let startRecord = AppLogRecord(
            timestamp: now(),
            category: category,
            level: .info,
            event: "\(event).start",
            message: message,
            fields: fields,
            context: context
        )
        observer?.didRecord(startRecord)
        logger(for: category).log(level: startRecord.level.osLogType, "\(startRecord.encodedMessage, privacy: .public)")
        return AppLogIntervalState(
            event: event,
            startRecord: startRecord,
            signposter: signposter,
            state: state
        )
    }

    fileprivate func endInterval(
        _ interval: AppLogIntervalState,
        category: AppLogCategory,
        message: String,
        fields: [String: String],
        context: AppLogContext
    ) {
        interval.signposter.endInterval(AppLogIntervalState.signpostName, interval.state)
        let durationMilliseconds = Int(
            now().timeIntervalSince(interval.startRecord.timestamp) * 1000
        )
        record(
            category: category,
            level: .info,
            event: "\(interval.event).end",
            message: message,
            fields: fields.merging(["durationMS": String(durationMilliseconds)], uniquingKeysWith: { _, new in new }),
            context: context,
            error: nil
        )
    }

    private func logger(for category: AppLogCategory) -> Logger {
        lock.lock()
        defer { lock.unlock() }

        return loggerLocked(for: category)
    }

    private func loggerLocked(for category: AppLogCategory) -> Logger {
        if let logger = loggers[category] {
            return logger
        }

        let logger = Logger(subsystem: subsystem, category: category.displayName)
        loggers[category] = logger
        return logger
    }

    private func signposter(for category: AppLogCategory) -> OSSignposter {
        lock.lock()
        defer { lock.unlock() }

        if let signposter = signposters[category] {
            return signposter
        }

        let signposter = OSSignposter(logger: loggerLocked(for: category))
        signposters[category] = signposter
        return signposter
    }
}

struct AppLogger: @unchecked Sendable {
    private let system: AppLogSystem
    private let category: AppLogCategory
    private let contextProvider: () -> AppLogContext

    init(
        system: AppLogSystem,
        category: AppLogCategory,
        contextProvider: @escaping () -> AppLogContext
    ) {
        self.system = system
        self.category = category
        self.contextProvider = contextProvider
    }

    func scoped(contextProvider: @escaping () -> AppLogContext) -> AppLogger {
        AppLogger(system: system, category: category) {
            self.contextProvider().merged(with: contextProvider())
        }
    }

    func scoped(category: AppLogCategory, contextProvider: @escaping () -> AppLogContext) -> AppLogger {
        AppLogger(system: system, category: category) {
            self.contextProvider().merged(with: contextProvider())
        }
    }

    func trace(_ event: String, _ message: String, fields: [String: String] = [:]) {
        log(level: .trace, event: event, message: message, fields: fields, error: nil)
    }

    func info(_ event: String, _ message: String, fields: [String: String] = [:]) {
        log(level: .info, event: event, message: message, fields: fields, error: nil)
    }

    func notice(_ event: String, _ message: String, fields: [String: String] = [:]) {
        log(level: .notice, event: event, message: message, fields: fields, error: nil)
    }

    func warning(_ event: String, _ message: String, fields: [String: String] = [:], error: Error? = nil) {
        log(level: .warning, event: event, message: message, fields: fields, error: error)
    }

    func error(_ event: String, _ message: String, fields: [String: String] = [:], error: Error? = nil) {
        log(level: .error, event: event, message: message, fields: fields, error: error)
    }

    func beginInterval(_ event: String, _ message: String, fields: [String: String] = [:]) -> AppLogIntervalState {
        system.beginInterval(
            category: category,
            event: event,
            message: message,
            fields: fields,
            context: contextProvider()
        )
    }

    func endInterval(_ interval: AppLogIntervalState, _ message: String, fields: [String: String] = [:]) {
        system.endInterval(
            interval,
            category: category,
            message: message,
            fields: fields,
            context: contextProvider()
        )
    }

    private func log(
        level: AppLogLevel,
        event: String,
        message: String,
        fields: [String: String],
        error: Error?
    ) {
        system.record(
            category: category,
            level: level,
            event: event,
            message: message,
            fields: fields,
            context: contextProvider(),
            error: error
        )
    }
}
