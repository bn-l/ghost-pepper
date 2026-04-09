import Foundation
import Observation
import OSLog

protocol AppLogStoreReading {
    func entries(since date: Date) throws -> [AppLogRecord]
}

private enum DebugLogRefreshOutcome {
    case success([AppLogRecord])
    case failure(String)
}

struct UnifiedAppLogStoreReader: AppLogStoreReading {
    let subsystem: String
    let storeProvider: () throws -> OSLogStore

    init(
        subsystem: String = AppLogSystem.defaultSubsystem,
        storeProvider: @escaping () throws -> OSLogStore = {
            try OSLogStore(scope: .currentProcessIdentifier)
        }
    ) {
        self.subsystem = subsystem
        self.storeProvider = storeProvider
    }

    func entries(since date: Date) throws -> [AppLogRecord] {
        let store = try storeProvider()
        let position = store.position(date: date)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store
            .getEntries(at: position, matching: predicate)
            .compactMap { entry in
                guard let logEntry = entry as? OSLogEntryLog else {
                    return nil
                }

                return AppLogRecord.decode(from: logEntry.composedMessage)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }
}

@MainActor
@Observable
final class DebugLogStore {
    private(set) var entries: [AppLogRecord] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?

    private let maxEntries: Int
    private let lookbackInterval: TimeInterval
    private let reader: AppLogStoreReading
    private let formatter: DateFormatter
    private let refreshQueue = DispatchQueue(label: "GhostPepper.DebugLogStore.Refresh", qos: .utility)
    private var refreshGeneration = 0

    init(
        maxEntries: Int = 250,
        lookbackInterval: TimeInterval = 30 * 60,
        reader: AppLogStoreReading = UnifiedAppLogStoreReader()
    ) {
        self.maxEntries = maxEntries
        self.lookbackInterval = lookbackInterval
        self.reader = reader
        self.formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
    }

    var formattedText: String {
        formattedText(for: entries)
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let cutoff = Date.now.addingTimeInterval(-lookbackInterval)
        let reader = self.reader
        let maxEntries = self.maxEntries

        isRefreshing = true

        refreshQueue.async {
            let result: DebugLogRefreshOutcome
            do {
                let loadedEntries = try reader.entries(since: cutoff)
                if loadedEntries.count > maxEntries {
                    result = .success(Array(loadedEntries.suffix(maxEntries)))
                } else {
                    result = .success(loadedEntries)
                }
            } catch {
                result = .failure(error.localizedDescription)
            }

            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.refreshGeneration else {
                    return
                }

                self.isRefreshing = false

                switch result {
                case .success(let entries):
                    self.entries = entries
                    self.lastRefreshError = nil
                case .failure(let errorDescription):
                    self.entries = []
                    self.lastRefreshError = errorDescription
                }
            }
        }
    }

    func formattedText(for entries: [AppLogRecord]) -> String {
        entries.map { entry in
            let header = "[\(formatter.string(from: entry.timestamp))] [\(entry.category.displayName)] [\(entry.level.displayName)] \(entry.event)"
            let fieldText = entry.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let contextText = entry.context.fields
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            let errorText = entry.error.map { "errorDomain=\($0.domain) errorCode=\($0.code) errorDescription=\($0.description)" } ?? ""

            return [header, entry.message, fieldText, contextText, errorText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    func exportJSON(for entries: [AppLogRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}
