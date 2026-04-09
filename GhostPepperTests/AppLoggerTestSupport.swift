import Foundation
@testable import GhostPepper

final class RecordingLogObserver: AppLogRecordObserving {
    private let lock = NSLock()
    private var storedRecords: [AppLogRecord] = []

    var records: [AppLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storedRecords
    }

    func didRecord(_ record: AppLogRecord) {
        lock.lock()
        storedRecords.append(record)
        lock.unlock()
    }
}

struct StaticAppLogStoreReader: AppLogStoreReading {
    let result: Result<[AppLogRecord], Error>

    func entries(since date: Date) throws -> [AppLogRecord] {
        try result.get()
    }
}

func makeTestLogger(
    category: AppLogCategory,
    mode: ObservabilityMode = .trace,
    context: AppLogContext = .empty
) -> (logger: AppLogger, observer: RecordingLogObserver) {
    let system = AppLogSystem(configProvider: { ObservabilityConfig(mode: mode) })
    let observer = RecordingLogObserver()
    system.observer = observer
    return (
        system.logger(category: category) { context },
        observer
    )
}
