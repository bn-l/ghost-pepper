import XCTest
@testable import GhostPepper

private final class ScheduledCallStore: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(TimeInterval, @Sendable () -> Void)] = []

    func append(delay: TimeInterval, work: @escaping @Sendable () -> Void) {
        lock.withLock {
            calls.append((delay, work))
        }
    }

    func count() -> Int {
        lock.withLock { calls.count }
    }

    func firstDelay() -> TimeInterval? {
        lock.withLock { calls.first?.0 }
    }

    func allDelays() -> [TimeInterval] {
        lock.withLock { calls.map(\.0) }
    }

    func popFirst() -> (@Sendable () -> Void)? {
        lock.withLock {
            guard !calls.isEmpty else {
                return nil
            }

            return calls.removeFirst().1
        }
    }
}

private final class OptionalActionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ action: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.action = action
        }
    }

    func isEmpty() -> Bool {
        lock.withLock { action == nil }
    }

    func run() {
        lock.withLock { action }?()
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock {
            count += 1
        }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

private final class QueueBox<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element]

    init(_ elements: [Element]) {
        self.elements = elements
    }

    func popFirst() -> Element? {
        lock.withLock {
            guard !elements.isEmpty else {
                return nil
            }

            return elements.removeFirst()
        }
    }
}

private final class ValueBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}

@MainActor
final class PostPasteLearningCoordinatorTests: XCTestCase {
    func testCoordinatorStartsPollingImmediatelyAfterPaste() async throws {
        XCTAssertEqual(PostPasteLearningCoordinator.observationWindow, 15)
        XCTAssertEqual(PostPasteLearningCoordinator.pollInterval, 1)
        XCTAssertEqual(PostPasteLearningCoordinator.quiescencePeriod, 2)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let revisitCallCount = CounterBox()
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in
                scheduledCalls.append(delay: delay, work: work)
            },
            revisit: { _ in
                revisitCallCount.increment()
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertEqual(scheduledCalls.count(), 1)
        XCTAssertEqual(scheduledCalls.firstDelay(), 0)
        XCTAssertEqual(revisitCallCount.value(), 0)

        await runNextScheduledCall(scheduledCalls)
        _ = await waitUntil { revisitCallCount.value() == 1 }

        XCTAssertEqual(revisitCallCount.value(), 1)
    }

    func testCoordinatorRejectsLargeRewriteDiffs() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledWork = OptionalActionStore()
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { _, work in scheduledWork.set(work) },
            revisit: { _ in
                PostPasteLearningObservation(
                    text: "This sentence was rewritten into something unrelated"
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        scheduledWork.run()
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorStoresHighConfidenceNarrowReplacement() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ])
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                guard let text = observations.popFirst() else {
                    return nil
                }
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(scheduledCalls, count: 3)
        _ = await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertEqual(
            correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    func testCoordinatorUsesInjectedSchedulerInsteadOfRealSleep() {
        let correctionStore = CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        let scheduledCalls = ScheduledCallStore()
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in
                scheduledCalls.append(delay: delay, work: work)
            },
            revisit: { _ in
                XCTFail("Revisit should not run until the test triggers the scheduled work")
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertEqual(scheduledCalls.allDelays(), [0])
    }

    func testCoordinatorDoesNotScheduleWhenLearningIsDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledWork = OptionalActionStore()
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            learningEnabled: false,
            scheduler: { _, work in
                scheduledWork.set(work)
            },
            revisit: { _ in
                XCTFail("Disabled learning should not trigger text-field revisit")
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertTrue(scheduledWork.isEmpty())
        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorRejectsChangesOutsideThePastedWords() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later"
        ])
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                let text = observations.popFirst()!
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(scheduledCalls, count: 3)
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorRejectsThreeWordReplacement() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow"
        ])
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                let text = observations.popFirst()!
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession(
            pastedText: "please email just see vincent tomorrow",
            focusedElementText: "please email just see vincent tomorrow"
        ))
        await runScheduledCalls(scheduledCalls, count: 3)
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorIgnoresPunctuationOnlyEdits() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "like approved it",
            "like approved it",
            "like approved it",
            "like approved it",
            "like approved it"
        ])
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                let text = observations.popFirst()!
                return PostPasteLearningObservation(text: text)
            }
        )

        coordinator.handlePaste(samplePasteSession(
            pastedText: "like? approved it",
            focusedElementText: "like? approved it"
        ))
        await runScheduledCalls(scheduledCalls, count: 3)
        _ = await waitUntil(timeout: 0.2) {
            !correctionStore.commonlyMisheard.isEmpty
        }

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testInferredReplacementIgnoresPunctuationOnlyChanges() {
        let replacement = PostPasteLearningCoordinator.inferredReplacement(
            from: "like? approved it",
            to: "like approved it",
            constrainedTo: "like? approved it"
        )

        XCTAssertNil(replacement)
    }

    func testCoordinatorLogsScheduledAndLearnedCorrection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ])
        let logging = makeTestLogger(category: .learning)
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                let text = observations.popFirst()!
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )
        coordinator.logger = logging.logger

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(scheduledCalls, count: 3)
        _ = await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertTrue(logging.observer.records.contains(where: { $0.event == "learning.poll_scheduled" }))
        XCTAssertTrue(logging.observer.records.contains(where: { $0.event == "learning.replacement_learned" }))
        XCTAssertFalse(logging.observer.records.contains(where: { $0.searchableText.contains("just see") || $0.searchableText.contains("Jesse") }))
    }

    func testCoordinatorLogsWhyLearningSkippedWhenPollingWindowExpires() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let logging = makeTestLogger(category: .learning)
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                nil
            }
        )
        coordinator.logger = logging.logger

        coordinator.handlePaste(samplePasteSession())
        let maximumPollCount = Int(
            PostPasteLearningCoordinator.observationWindow / PostPasteLearningCoordinator.pollInterval
        ) + 1
        await runScheduledCalls(scheduledCalls, count: maximumPollCount)
        let expiredLogged = await waitUntil(timeout: 2) {
            logging.observer.records.contains(where: { $0.event == "learning.poll_expired" })
        }

        XCTAssertTrue(expiredLogged)
    }

    func testCoordinatorNotifiesWhenItLearnsCorrection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox([
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ])
        let learnedReplacement = ValueBox<MisheardReplacement?>(nil)
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                let text = observations.popFirst()!
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )
        coordinator.onLearnedCorrection = { replacement in
            learnedReplacement.set(replacement)
        }

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(scheduledCalls, count: 3)
        _ = await waitUntil { learnedReplacement.get() == MisheardReplacement(wrong: "just see", right: "Jesse") }

        XCTAssertEqual(learnedReplacement.get(), MisheardReplacement(wrong: "just see", right: "Jesse"))
    }

    func testCoordinatorCanLearnAfterLateInitialSnapshotCapture() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        let scheduledCalls = ScheduledCallStore()
        let observations = QueueBox<PostPasteLearningObservation?>([
            nil,
            PostPasteLearningObservation(text: "just see approved it"),
            PostPasteLearningObservation(text: "Jesse approved it"),
            PostPasteLearningObservation(text: "Jesse approved it"),
            PostPasteLearningObservation(text: "Jesse approved it")
        ])
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append(delay: delay, work: work) },
            revisit: { _ in
                observations.popFirst() ?? nil
            }
        )

        coordinator.handlePaste(samplePasteSession(focusedElementText: nil))

        await runScheduledCalls(scheduledCalls, count: 5)
        _ = await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertEqual(
            correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    private func samplePasteSession(
        pastedText: String = "just see approved it",
        focusedElementText: String? = "just see approved it"
    ) -> PasteSession {
        PasteSession(
            pastedText: pastedText,
            pastedAt: Date(timeIntervalSince1970: 1_742_751_200),
            frontmostAppBundleIdentifier: "com.example.app",
            frontmostWindowID: 42,
            frontmostWindowFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            focusedElementFrame: CGRect(x: 20, y: 40, width: 300, height: 120),
            focusedElementText: focusedElementText
        )
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() {
                return true
            }

            try? await Task.sleep(for: .milliseconds(10))
        }

        return condition()
    }

    private func runScheduledCalls(
        _ scheduledCalls: ScheduledCallStore,
        count: Int
    ) async {
        for _ in 0..<count {
            await runNextScheduledCall(scheduledCalls)
        }
    }

    private func runNextScheduledCall(
        _ scheduledCalls: ScheduledCallStore
    ) async {
        let deadline = Date.now.addingTimeInterval(0.5)
        while scheduledCalls.count() == 0, Date.now < deadline {
            await Task.yield()
        }

        XCTAssertGreaterThan(scheduledCalls.count(), 0)
        scheduledCalls.popFirst()?()
        await Task.yield()
    }
}
