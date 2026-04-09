import Cocoa
import ApplicationServices
import CoreGraphics

/// Represents a saved clipboard state, preserving all pasteboard items with all type representations.
struct ClipboardState {
    let data: [[(NSPasteboard.PasteboardType, Data)]]
}

enum PasteResult: Equatable {
    case pasted
    case copiedToClipboard
}

/// Pastes transcribed text into the focused text field by simulating Cmd+V.
/// Saves and restores the clipboard around the paste operation to avoid clobbering user data.
/// Requires Accessibility permission for CGEvent posting.
@MainActor
final class TextPaster {
    typealias PasteSessionProvider = @Sendable (String, Date) -> PasteSession?
    typealias PasteAction = @MainActor @Sendable () -> Bool
    typealias PasteScheduler = (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    private final class CommandVEvents: @unchecked Sendable {
        let keyDown: CGEvent
        let keyUp: CGEvent

        init?(source: CGEventSource?) {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: TextPaster.vKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: TextPaster.vKeyCode, keyDown: false) else {
                return nil
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            self.keyDown = keyDown
            self.keyUp = keyUp
        }

        func post() -> Bool {
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        }
    }

    struct AccessibilitySnapshot {
        let role: String?
        let isEnabled: Bool?
        let isEditable: Bool?
        let isFocused: Bool?
        let hasSelectedTextRange: Bool
        let valueIsSettable: Bool
        let children: [AccessibilitySnapshot]

        init(
            role: String?,
            isEnabled: Bool?,
            isEditable: Bool?,
            isFocused: Bool?,
            hasSelectedTextRange: Bool,
            valueIsSettable: Bool,
            children: [AccessibilitySnapshot] = []
        ) {
            self.role = role
            self.isEnabled = isEnabled
            self.isEditable = isEditable
            self.isFocused = isFocused
            self.hasSelectedTextRange = hasSelectedTextRange
            self.valueIsSettable = valueIsSettable
            self.children = children
        }
    }

    private struct PasteTargetAttributes {
        let role: String?
        let isEnabled: Bool?
        let isEditable: Bool?
        let isFocused: Bool?
        let hasSelectedTextRange: Bool
        let valueIsSettable: Bool
    }

    // MARK: - Timing Constants

    /// Delay after writing text to the clipboard so the pasteboard has time to publish the new value.
    static let preKeystrokeDelay: TimeInterval = 0.05

    /// Delay after simulating Cmd+V so the target app can read the clipboard before restoration.
    static let postKeystrokeDelay: TimeInterval = 0.1
    static let fallbackClipboardRestoreDelay: Duration = .seconds(30)

    // MARK: - Virtual Key Codes

    nonisolated private static let vKeyCode: CGKeyCode = 0x09
    var onPaste: ((PasteSession) -> Void)?
    var onPasteStart: (() -> Void)?
    var onPasteEnd: (() -> Void)?
    var shouldCapturePasteSession: @MainActor () -> Bool = { true }
    var logger: AppLogger?

    private let pasteSessionProvider: PasteSessionProvider
    private let pasteboard: NSPasteboard
    private let canPasteIntoFocusedElement: () -> Bool
    private let prepareCommandV: () -> PasteAction?
    private let schedule: PasteScheduler
    private var fallbackRestoreTask: Task<Void, Never>?

    init(
        pasteboard: NSPasteboard = .general,
        canPasteIntoFocusedElement: @escaping () -> Bool = { TextPaster.defaultCanPasteIntoFocusedElement() },
        prepareCommandV: @escaping () -> PasteAction? = { TextPaster.defaultCommandVPasteAction() },
        pasteSessionProvider: @escaping PasteSessionProvider = { text, date in
            FocusedElementLocator().capturePasteSession(for: text, at: date)
        },
        schedule: @escaping PasteScheduler = { delay, action in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                action()
            }
        }
    ) {
        self.pasteboard = pasteboard
        self.canPasteIntoFocusedElement = canPasteIntoFocusedElement
        self.prepareCommandV = prepareCommandV
        self.pasteSessionProvider = pasteSessionProvider
        self.schedule = schedule
    }

    // MARK: - Clipboard Operations

    /// Saves all pasteboard items with all their type representations.
    /// - Returns: A `ClipboardState` capturing the full clipboard contents, or `nil` if the clipboard is empty.
    func saveClipboard() -> ClipboardState? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        var allItems: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in items {
            var itemData: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    itemData.append((type, data))
                }
            }
            if !itemData.isEmpty {
                allItems.append(itemData)
            }
        }

        return allItems.isEmpty ? nil : ClipboardState(data: allItems)
    }

    /// Restores a previously saved clipboard state.
    /// All `NSPasteboardItem` objects are collected first, then written in a single `writeObjects` call.
    /// - Parameter state: The clipboard state to restore.
    func restoreClipboard(_ state: ClipboardState) {
        pasteboard.clearContents()

        var pasteboardItems: [NSPasteboardItem] = []
        for itemData in state.data {
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            pasteboardItems.append(item)
        }

        if !pasteboard.writeObjects(pasteboardItems) {
            logger?.warning("paste.restore_failed", "Failed to restore the original clipboard contents.")
        }
    }

    // MARK: - Paste Flow

    /// Pastes the given text into the currently focused text field.
    ///
    /// Flow:
    /// 1. Save current clipboard
    /// 2. Write text to clipboard
    /// 3. After a short delay, simulate Cmd+V
    /// 4. After another delay, restore the original clipboard
    ///
    /// - Parameter text: The text to paste.
    func paste(text: String) -> PasteResult {
        let savedState = saveClipboard()
        let postCommandV = canPasteIntoFocusedElement() ? prepareCommandV() : nil

        guard let postCommandV else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            scheduleFallbackClipboardRestore(savedState)
            onPasteEnd?()
            return .copiedToClipboard
        }

        fallbackRestoreTask?.cancel()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onPasteStart?()

        schedule(Self.preKeystrokeDelay) { [weak self] in
            guard postCommandV() else {
                self?.logger?.warning("paste.command_v_failed", "Failed to synthesize Cmd+V events; leaving transcript on the clipboard for manual paste.")
                self?.scheduleFallbackClipboardRestore(savedState)
                self?.onPasteEnd?()
                return
            }

            self?.schedule(Self.postKeystrokeDelay) { [weak self] in
                guard let self else { return }

                if self.shouldCapturePasteSession(),
                   let pasteSession = self.pasteSessionProvider(text, .now) {
                    self.onPaste?(pasteSession)
                }

                if let savedState {
                    self.restoreClipboard(savedState)
                }

                self.onPasteEnd?()
            }
        }

        return .pasted
    }

    private func scheduleFallbackClipboardRestore(_ state: ClipboardState?) {
        fallbackRestoreTask?.cancel()

        guard let state else {
            return
        }

        let expectedChangeCount = pasteboard.changeCount
        fallbackRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.fallbackClipboardRestoreDelay)
            guard let self,
                  self.pasteboard.changeCount == expectedChangeCount else {
                return
            }

            self.restoreClipboard(state)
        }
    }

    // MARK: - Accessibility Preflight

    private static func defaultCanPasteIntoFocusedElement() -> Bool {
        FocusedElementLocator().canPasteIntoFocusedElement()
    }

    nonisolated
    static func containsLikelyPasteTarget(
        startingAt snapshot: AccessibilitySnapshot,
        maxDepth: Int = 12
    ) -> Bool {
        containsLikelyPasteTarget(
            startingAt: snapshot,
            maxDepth: maxDepth,
            attributesProvider: {
                PasteTargetAttributes(
                    role: $0.role,
                    isEnabled: $0.isEnabled,
                    isEditable: $0.isEditable,
                    isFocused: $0.isFocused,
                    hasSelectedTextRange: $0.hasSelectedTextRange,
                    valueIsSettable: $0.valueIsSettable
                )
            },
            childrenProvider: { $0.children }
        )
    }

    nonisolated
    private static func containsLikelyPasteTarget<Element>(
        startingAt element: Element,
        maxDepth: Int = 12,
        hasFocusContext: Bool = false,
        attributesProvider: (Element) -> PasteTargetAttributes,
        childrenProvider: (Element) -> [Element]
    ) -> Bool {
        guard maxDepth >= 0 else {
            return false
        }

        let currentAttributes = attributesProvider(element)
        let currentHasFocusContext = hasFocusContext || currentAttributes.isFocused == true

        if isLikelyPasteTarget(currentAttributes, hasFocusContext: currentHasFocusContext) {
            return true
        }

        guard maxDepth > 0 else {
            return false
        }

        let children = childrenProvider(element)
        let focusedChildren = children.filter { attributesProvider($0).isFocused == true }
        for child in focusedChildren {
            if containsLikelyPasteTarget(
                startingAt: child,
                maxDepth: maxDepth - 1,
                hasFocusContext: currentHasFocusContext,
                attributesProvider: attributesProvider,
                childrenProvider: childrenProvider
            ) {
                return true
            }
        }

        for child in children where attributesProvider(child).isFocused != true {
            if containsLikelyPasteTarget(
                startingAt: child,
                maxDepth: maxDepth - 1,
                hasFocusContext: currentHasFocusContext,
                attributesProvider: attributesProvider,
                childrenProvider: childrenProvider
            ) {
                return true
            }
        }

        return false
    }

    nonisolated
    private static func isLikelyPasteTarget(
        _ attributes: PasteTargetAttributes,
        hasFocusContext: Bool
    ) -> Bool {
        guard attributes.isEnabled ?? true else {
            return false
        }

        if !hasFocusContext {
            return attributes.hasSelectedTextRange && attributes.valueIsSettable
        }

        if attributes.isEditable == true {
            return true
        }

        if attributes.valueIsSettable {
            return true
        }

        let hasTextRole = isTextEntryRole(attributes.role)

        if attributes.hasSelectedTextRange {
            return hasTextRole
        }

        if hasTextRole {
            return true
        }

        return false
    }

    nonisolated
    private static func isTextEntryRole(_ role: String?) -> Bool {
        guard let role else {
            return false
        }

        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private static func attributes(for element: AXUIElement) -> PasteTargetAttributes {
        PasteTargetAttributes(
            role: stringAttribute(kAXRoleAttribute as CFString, on: element),
            isEnabled: boolAttribute(kAXEnabledAttribute as CFString, on: element),
            isEditable: boolAttribute("AXEditable" as CFString, on: element),
            isFocused: boolAttribute(kAXFocusedAttribute as CFString, on: element),
            hasSelectedTextRange: hasAttribute(kAXSelectedTextRangeAttribute as CFString, on: element),
            valueIsSettable: isAttributeSettable(kAXValueAttribute as CFString, on: element)
        )
    }

    private static func axElementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private static func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func hasAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &value) == .success
    }

    private static func isAttributeSettable(_ attribute: CFString, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success else {
            return false
        }

        return isSettable.boolValue
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [Any] else {
            return []
        }

        return children.compactMap {
            let value = $0 as CFTypeRef
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return unsafeDowncast(value, to: AXUIElement.self)
        }
    }

    // MARK: - Key Simulation

    private static func defaultCommandVPasteAction() -> PasteAction? {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let events = CommandVEvents(source: source) else {
            return nil
        }

        return {
            events.post()
        }
    }
}
