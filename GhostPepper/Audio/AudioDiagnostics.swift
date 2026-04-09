import Foundation
import OSLog

enum AudioDiagnostics {
    static let subsystem = AppLogSystem.defaultSubsystem
    static let logger = Logger(subsystem: subsystem, category: AppLogCategory.audio.displayName)
    static let signposter = OSSignposter(logger: logger)
}
