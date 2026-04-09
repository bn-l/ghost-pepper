import AppKit
import SwiftUI

@MainActor
final class DebugLogWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?

    func show(debugLogStore: DebugLogStore) {
        if let window {
            if let hostingController = window.contentViewController as? NSHostingController<DebugLogWindowView> {
                hostingController.rootView = DebugLogWindowView(debugLogStore: debugLogStore)
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Debug Log"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.contentViewController = NSHostingController(
            rootView: DebugLogWindowView(debugLogStore: debugLogStore)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct DebugLogWindowView: View {
    let debugLogStore: DebugLogStore

    @State private var shouldFollowTail = true
    @State private var selectedCategory = CategoryFilter.all
    @State private var selectedLevel = LevelFilter.all
    @State private var sessionFilter = ""
    @State private var searchFilter = ""
    @State private var exportError: String?

    private let bottomAnchorID = "debug-log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Category", selection: $selectedCategory) {
                    ForEach(CategoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 150)

                Picker("Level", selection: $selectedLevel) {
                    ForEach(LevelFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .frame(width: 130)

                TextField("Session ID", text: $sessionFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)

                TextField("Search", text: $searchFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
            }

            HStack {
                Button("Refresh") {
                    debugLogStore.refresh()
                }

                Button("Copy Visible") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(debugLogStore.formattedText(for: visibleEntries), forType: .string)
                }
                .disabled(visibleEntries.isEmpty)

                Button("Export Text...") {
                    export(text: debugLogStore.formattedText(for: visibleEntries), suggestedName: "ghost-pepper-debug-log.txt")
                }
                .disabled(visibleEntries.isEmpty)

                Button("Export JSON...") {
                    export(text: debugLogStore.exportJSON(for: visibleEntries), suggestedName: "ghost-pepper-debug-log.json")
                }
                .disabled(visibleEntries.isEmpty)

                Spacer()

                Text("\(visibleEntries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastRefreshError = debugLogStore.lastRefreshError {
                Text("Log refresh failed: \(lastRefreshError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let exportError {
                Text("Log export failed: \(exportError)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollViewReader { proxy in
                GeometryReader { outer in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if visibleEntries.isEmpty {
                                Text(emptyStateText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            } else {
                                ForEach(visibleEntries) { entry in
                                    Text(debugLogStore.formattedText(for: entry))
                                        .font(.system(.caption, design: .monospaced))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                        .id(entry.id)
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                                .background(
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: DebugLogBottomOffsetPreferenceKey.self,
                                            value: geometry.frame(in: .named("debug-log-scroll")).maxY
                                        )
                                    }
                                )
                        }
                    }
                    .coordinateSpace(name: "debug-log-scroll")
                    .onAppear {
                        debugLogStore.refresh()
                        scrollToBottom(with: proxy)
                    }
                    .task {
                        await refreshLoop()
                    }
                    .onChange(of: visibleEntries.count) { _, _ in
                        guard shouldFollowTail else {
                            return
                        }
                        scrollToBottom(with: proxy)
                    }
                    .onPreferenceChange(DebugLogBottomOffsetPreferenceKey.self) { bottomOffset in
                        shouldFollowTail = bottomOffset - outer.size.height <= 32
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
        .frame(minWidth: 860, minHeight: 560)
    }

    private var visibleEntries: [AppLogRecord] {
        debugLogStore.entries.filter { entry in
            let matchesCategory = selectedCategory.matches(entry.category)
            let matchesLevel = selectedLevel.matches(entry.level)
            let matchesSession = sessionFilter.isEmpty || entry.context.searchableSessionIDs.contains {
                $0.localizedCaseInsensitiveContains(sessionFilter)
            }
            let matchesSearch = searchFilter.isEmpty || entry.searchableText.localizedCaseInsensitiveContains(searchFilter)
            return matchesCategory && matchesLevel && matchesSession && matchesSearch
        }
    }

    private var emptyStateText: String {
        if debugLogStore.entries.isEmpty {
            return "No debug events have been recorded for this process."
        }

        return "No log entries match the current filters."
    }

    private func scrollToBottom(with proxy: ScrollViewProxy) {
        Task { @MainActor in
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }

    private func export(text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }
            debugLogStore.refresh()
        }
    }
}

private enum CategoryFilter: String, CaseIterable, Identifiable {
    case all
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

    var title: String {
        switch self {
        case .all:
            return "All Categories"
        case .app:
            return AppLogCategory.app.displayName
        case .audio:
            return AppLogCategory.audio.displayName
        case .permissions:
            return AppLogCategory.permissions.displayName
        case .hotkey:
            return AppLogCategory.hotkey.displayName
        case .recording:
            return AppLogCategory.recording.displayName
        case .transcription:
            return AppLogCategory.transcription.displayName
        case .cleanup:
            return AppLogCategory.cleanup.displayName
        case .ocr:
            return AppLogCategory.ocr.displayName
        case .paste:
            return AppLogCategory.paste.displayName
        case .learning:
            return AppLogCategory.learning.displayName
        case .model:
            return AppLogCategory.model.displayName
        case .ui:
            return AppLogCategory.ui.displayName
        case .performance:
            return AppLogCategory.performance.displayName
        case .storage:
            return AppLogCategory.storage.displayName
        }
    }

    func matches(_ category: AppLogCategory) -> Bool {
        switch self {
        case .all:
            return true
        default:
            return rawValue == category.rawValue
        }
    }
}

private enum LevelFilter: String, CaseIterable, Identifiable {
    case all
    case trace
    case info
    case notice
    case warning
    case error

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Levels"
        case .trace:
            return AppLogLevel.trace.displayName
        case .info:
            return AppLogLevel.info.displayName
        case .notice:
            return AppLogLevel.notice.displayName
        case .warning:
            return AppLogLevel.warning.displayName
        case .error:
            return AppLogLevel.error.displayName
        }
    }

    func matches(_ level: AppLogLevel) -> Bool {
        switch self {
        case .all:
            return true
        default:
            return rawValue == level.rawValue
        }
    }
}

private struct DebugLogBottomOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
