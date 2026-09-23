import XCTest
@testable import ExyteChat

final class UIListRowUpdateTests: XCTestCase {
    private let user = User(id: "u", name: "User", avatarURL: nil, isCurrentUser: false)
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testStreamingTextEditProducesOnlyChangedTableRow() throws {
        let oldSections = [section(messages: [message("a", "old"), message("b", "steady")])]
        let newSections = [section(messages: [message("a", "streamed"), message("b", "steady")])]

        let plan = try XCTUnwrap(RowUpdatePlan.make(
            oldSections: oldSections,
            newSections: newSections,
            showsLastReadIndicator: false
        ))

        XCTAssertEqual(plan.changedIndexPaths, [IndexPath(row: 0, section: 0)])
    }

    func testLastReadIndicatorOffsetsChangedMessageTableRow() throws {
        let oldSections = [section(messages: [
            message("first", "one"),
            message("read", "old", status: .readBy(["u"]))
        ])]
        let newSections = [section(messages: [
            message("first", "one"),
            message("read", "new", status: .readBy(["u"]))
        ])]

        let plan = try XCTUnwrap(RowUpdatePlan.make(
            oldSections: oldSections,
            newSections: newSections,
            showsLastReadIndicator: true
        ))

        XCTAssertEqual(plan.changedIndexPaths, [IndexPath(row: 2, section: 0)])
    }

    func testIndicatorMoveFallsBackToStructuralUpdate() {
        let oldSections = [section(messages: [
            message("a", "one"),
            message("b", "two", status: .readBy(["u"]))
        ])]
        let newSections = [section(messages: [
            message("a", "one", status: .readBy(["u"])),
            message("b", "two")
        ])]

        XCTAssertNil(RowUpdatePlan.make(
            oldSections: oldSections,
            newSections: newSections,
            showsLastReadIndicator: true
        ))
    }

    func testInsertDeleteAndReorderFallBackToStructuralUpdate() {
        let baseline = [section(messages: [message("a", "one"), message("b", "two")])]
        let inserted = [section(messages: [message("a", "one"), message("b", "two"), message("c", "three")])]
        let reordered = [section(messages: [message("b", "two"), message("a", "one")])]

        XCTAssertNil(RowUpdatePlan.make(oldSections: baseline, newSections: inserted, showsLastReadIndicator: false))
        XCTAssertNil(RowUpdatePlan.make(oldSections: baseline, newSections: reordered, showsLastReadIndicator: false))
    }

    private func message(_ id: String, _ text: String, status: Message.Status? = nil) -> Message {
        Message(id: id, user: user, status: status, createdAt: date, text: text)
    }

    private func section(messages: [Message]) -> MessagesSection {
        MessagesSection(
            date: date,
            rows: messages.map {
                MessageRow(
                    message: $0,
                    positionInUserGroup: .single,
                    positionInMessagesSection: .single,
                    commentsPosition: nil
                )
            }
        )
    }
}

@MainActor
final class UpdateQueueCoalescingTests: XCTestCase {
    func testRapidTailUpdatesExecuteOnlyNewestWork() async {
        let queue = UpdateQueue()
        let gate = QueueTestGate()
        let recorder = QueueTestRecorder()

        await queue.createJob {
            await gate.block()
            await recorder.append(0)
        }
        await waitUntil { await queue.pendingJobCountForTesting() == 1 }

        for value in 1...100 {
            await queue.createCoalescingJob(key: "stream") {
                await recorder.append(value)
            }
        }
        await waitUntil { await queue.pendingJobCountForTesting() == 2 }

        await gate.release()
        await waitUntil { await queue.pendingJobCountForTesting() == 0 }

        let values = await recorder.snapshot()
        XCTAssertEqual(values, [0, 100])
    }

    func testNormalJobIsOrderingBarrierForCoalescing() async {
        let queue = UpdateQueue()
        let gate = QueueTestGate()
        let recorder = QueueTestRecorder()

        await queue.createJob { await gate.block() }
        await waitUntil { await queue.pendingJobCountForTesting() == 1 }
        await queue.createCoalescingJob(key: "stream") { await recorder.append(1) }
        await queue.createJob { await recorder.append(2) }
        await queue.createCoalescingJob(key: "stream") { await recorder.append(3) }
        await waitUntil { await queue.pendingJobCountForTesting() == 4 }

        await gate.release()
        await waitUntil { await queue.pendingJobCountForTesting() == 0 }

        let values = await recorder.snapshot()
        XCTAssertEqual(values, [1, 2, 3])
    }

    func testCoalescingResumesEveryTransactionWaiter() async {
        let queue = UpdateQueue()
        let gate = QueueTestGate()
        let completedTransactions = QueueTestRecorder()
        let executedWork = QueueTestRecorder()

        await queue.createJob { await gate.block() }
        await waitUntil { await queue.pendingJobCountForTesting() == 1 }

        var waiters: [Task<Void, Never>] = []
        for value in 1...3 {
            await queue.startTransaction(animationMode: .none)
            let waiter = Task {
                await queue.waitForTransactionToFinish()
                await completedTransactions.append(value)
            }
            waiters.append(waiter)
            await waitUntil { await queue.orphanTransactionWaiterCountForTesting() == 1 }
            await queue.markRealUpdate()
            await queue.createCoalescingJob(key: "stream") {
                await executedWork.append(value)
            }
        }

        await gate.release()
        for waiter in waiters {
            await waiter.value
        }
        await waitUntil { await queue.pendingJobCountForTesting() == 0 }

        let workValues = await executedWork.snapshot()
        let completedValues = await completedTransactions.snapshot().sorted()
        XCTAssertEqual(workValues, [3])
        XCTAssertEqual(completedValues, [1, 2, 3])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor QueueTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func block() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor QueueTestRecorder {
    private var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }

    func snapshot() -> [Int] {
        values
    }
}
