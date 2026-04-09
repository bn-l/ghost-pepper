import XCTest
import ApplicationServices
@testable import GhostPepper

private final class ActionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [@MainActor @Sendable () -> Void] = []

    func append(_ action: @escaping @MainActor @Sendable () -> Void) {
        lock.withLock {
            actions.append(action)
        }
    }

    func count() -> Int {
        lock.withLock { actions.count }
    }

    func popFirst() -> (@MainActor @Sendable () -> Void)? {
        lock.withLock {
            guard !actions.isEmpty else {
                return nil
            }

            return actions.removeFirst()
        }
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock {
            value += 1
        }
    }

    func get() -> Int {
        lock.withLock { value }
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) {
        self.value = value
    }

    func set(_ value: String) {
        lock.withLock {
            self.value = value
        }
    }

    func get() -> String {
        lock.withLock { value }
    }
}

@MainActor
final class TextPasterTests: XCTestCase {
    func testContainsLikelyPasteTargetAcceptsTerminalStyleFocusedTextArea() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXTextAreaRole as String,
            isEnabled: nil,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsWindowWithFocusedTextDescendant() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXTextAreaRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: true,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsGroupedWindowWithoutFocusedInput() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: nil,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: false,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: nil,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: false
                        )
                    ]
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetAcceptsGroupedEditorWithSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXGroupRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: true,
                    valueIsSettable: true,
                    children: [
                        TextPaster.AccessibilitySnapshot(
                            role: kAXGroupRole as String,
                            isEnabled: true,
                            isEditable: nil,
                            isFocused: false,
                            hasSelectedTextRange: true,
                            valueIsSettable: true
                        )
                    ]
                )
            ]
        )

        XCTAssertTrue(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsFocusedBackgroundGroupWithoutSettableValue() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXGroupRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: true,
            hasSelectedTextRange: true,
            valueIsSettable: false
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testContainsLikelyPasteTargetRejectsWindowWithoutEditableSignals() {
        let snapshot = TextPaster.AccessibilitySnapshot(
            role: kAXWindowRole as String,
            isEnabled: true,
            isEditable: nil,
            isFocused: false,
            hasSelectedTextRange: false,
            valueIsSettable: false,
            children: [
                TextPaster.AccessibilitySnapshot(
                    role: kAXButtonRole as String,
                    isEnabled: true,
                    isEditable: nil,
                    isFocused: false,
                    hasSelectedTextRange: false,
                    valueIsSettable: false
                )
            ]
        )

        XCTAssertFalse(TextPaster.containsLikelyPasteTarget(startingAt: snapshot))
    }

    func testSaveAndRestoreClipboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        let paster = TextPaster(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let saved = paster.saveClipboard()
        XCTAssertNotNil(saved)

        pasteboard.clearContents()
        pasteboard.setString("new content", forType: .string)

        paster.restoreClipboard(saved!)
        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteLeavesTranscriptOnClipboardWhenFocusedInputIsUnavailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        var scheduledActions = 0
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { false },
            prepareCommandV: {
                XCTFail("prepareCommandV should not be called when no focused input is available")
                return nil
            },
            schedule: { _, _ in
                scheduledActions += 1
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(scheduledActions, 0)

        pasteboard.releaseGlobally()
    }

    func testPasteDoesNotReportPasteStartWhenFocusedInputIsUnavailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let pasteStartCount = CounterBox()
        let pasteEndCount = CounterBox()
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { false },
            prepareCommandV: {
                XCTFail("prepareCommandV should not be called when no focused input is available")
                return nil
            }
        )
        paster.onPasteStart = {
            pasteStartCount.increment()
        }
        paster.onPasteEnd = {
            pasteEndCount.increment()
        }

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(pasteStartCount.get(), 0)
        XCTAssertEqual(pasteEndCount.get(), 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")

        pasteboard.releaseGlobally()
    }

    func testPasteSchedulesCommandVAndRestoresClipboardWhenFocusedInputIsAvailable() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let scheduledActions = ActionQueue()
        let postedCommandV = CounterBox()
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                {
                    postedCommandV.increment()
                    return true
                }
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(postedCommandV.get(), 0)
        XCTAssertEqual(scheduledActions.count(), 1)

        guard let postPasteAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        postPasteAction()

        XCTAssertEqual(postedCommandV.get(), 1)
        XCTAssertEqual(scheduledActions.count(), 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")

        guard let restoreClipboardAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        restoreClipboardAction()

        XCTAssertEqual(pasteboard.string(forType: .string), "original content")

        pasteboard.releaseGlobally()
    }

    func testPasteLeavesTranscriptAvailableWhenCommandVPostingFails() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let scheduledActions = ActionQueue()
        let pasteEndCount = CounterBox()
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                { false }
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.onPasteEnd = {
            pasteEndCount.increment()
        }

        let result = paster.paste(text: "new content")

        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(scheduledActions.count(), 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")

        guard let postPasteAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        postPasteAction()

        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
        XCTAssertEqual(pasteEndCount.get(), 1)

        pasteboard.releaseGlobally()
    }

    func testPasteCapturesSessionAfterPasteDelay() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let currentSnapshot = StringBox("before paste")
        let scheduledActions = ActionQueue()
        let expectation = expectation(description: "paste session captured")
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: {
                { true }
            },
            pasteSessionProvider: { text, date in
            PasteSession(
                pastedText: text,
                pastedAt: date,
                frontmostAppBundleIdentifier: "com.example.app",
                frontmostWindowID: 42,
                frontmostWindowFrame: nil,
                focusedElementFrame: nil,
                focusedElementText: currentSnapshot.get()
            )
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.onPaste = { session in
            XCTAssertEqual(session.focusedElementText, "after paste")
            expectation.fulfill()
        }

        let result = paster.paste(text: "Jesse")
        XCTAssertEqual(result, .pasted)
        XCTAssertEqual(scheduledActions.count(), 1)

        currentSnapshot.set("after paste")

        guard let postPasteAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        postPasteAction()

        XCTAssertEqual(scheduledActions.count(), 1)

        guard let captureSessionAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        captureSessionAction()

        wait(for: [expectation], timeout: 1)
        pasteboard.releaseGlobally()
    }

    func testPasteSkipsPasteSessionCaptureWhenCaptureIsDisabled() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let scheduledActions = ActionQueue()
        let capturedPasteCount = CounterBox()
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: { { true } },
            pasteSessionProvider: { text, date in
                PasteSession(
                    pastedText: text,
                    pastedAt: date,
                    frontmostAppBundleIdentifier: "com.example.app",
                    frontmostWindowID: 42,
                    frontmostWindowFrame: nil,
                    focusedElementFrame: nil,
                    focusedElementText: "after paste"
                )
            },
            schedule: { _, action in
                scheduledActions.append(action)
            }
        )
        paster.shouldCapturePasteSession = { false }
        paster.onPaste = { _ in
            capturedPasteCount.increment()
        }

        let result = paster.paste(text: "Jesse")
        XCTAssertEqual(result, .pasted)

        guard let postPasteAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        postPasteAction()

        guard let restoreAction = try? XCTUnwrap(scheduledActions.popFirst()) else {
            return
        }
        restoreAction()

        XCTAssertEqual(capturedPasteCount.get(), 0)
        pasteboard.releaseGlobally()
    }

    func testDefaultSchedulerRunsPasteCallbacksOnMainActor() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("original content", forType: .string)

        let expectation = expectation(description: "paste completed on main actor")
        let paster = TextPaster(
            pasteboard: pasteboard,
            canPasteIntoFocusedElement: { true },
            prepareCommandV: { { true } }
        )
        paster.onPasteEnd = {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(pasteboard.string(forType: .string), "original content")
            expectation.fulfill()
        }

        XCTAssertEqual(paster.paste(text: "new content"), .pasted)

        wait(for: [expectation], timeout: 2)
        pasteboard.releaseGlobally()
    }
}
