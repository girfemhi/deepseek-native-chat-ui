import XCTest
@testable import ExyteChat

@MainActor
final class AgentComposerTests: XCTestCase {
    func testImmediateModeKeepsUpstreamResetBehavior() async {
        let model = InputViewModel()
        var delivered: DraftMessage?
        model.didSendMessage = { delivered = $0 }
        model.text = "hello"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(delivered?.text, "hello")
        XCTAssertEqual(model.text, "")
        XCTAssertEqual(model.state, .empty)
    }

    func testDeferredFailureRetainsDraftForRetry() async {
        let model = InputViewModel()
        model.sendCommitMode = .deferred { _ in false }
        model.text = "retry me"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(model.text, "retry me")
        XCTAssertEqual(model.state, .hasTextOrMedia)
    }

    func testDeferredSuccessPreservesTextTypedDuringAcknowledgement() async {
        let gate = CommitGate()
        let model = InputViewModel()
        model.sendCommitMode = .deferred { draft in
            await gate.submit(draft)
        }
        model.text = "first"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { gate.hasSubmission }
        model.text = "next"
        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(gate.submittedDraft?.text, "first")
        XCTAssertEqual(model.text, "next")
        XCTAssertEqual(model.state, .hasTextOrMedia)
    }

    func testDisabledSendNeverSubmitsOrClears() async {
        let model = InputViewModel()
        var submissionCount = 0
        model.didSendMessage = { _ in submissionCount += 1 }
        model.text = "keep"
        model.state = .hasTextOrMedia
        model.sendDisabled = true

        model.send()
        await Task.yield()

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(model.text, "keep")
    }

    func testDeferredRetryReusesDraftIdentityAndCreationDate() async {
        let attempts = AttemptRecorder(results: [false, true])
        let model = InputViewModel()
        model.sendCommitMode = .deferred { draft in
            attempts.submit(draft)
        }
        model.text = "stable retry"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { !model.isCommitting }
        model.send()
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(attempts.drafts.count, 2)
        XCTAssertEqual(attempts.drafts[0].id, attempts.drafts[1].id)
        XCTAssertEqual(attempts.drafts[0].createdAt, attempts.drafts[1].createdAt)
        XCTAssertEqual(model.text, "")
    }

    func testAttachmentHandlerCanResolvePrivateURLBeforeDefaultViewer() async {
        let remote = Attachment(
            id: "attachment-1",
            url: URL(string: "https://private.invalid/file")!,
            type: .image
        )
        let local = remote.copy(
            thumbnail: URL(fileURLWithPath: "/tmp/thumbnail.jpg"),
            full: URL(fileURLWithPath: "/tmp/full.jpg")
        )
        let model = ChatViewModel()
        model.attachmentTapHandler = { _, openDefault in openDefault(local) }

        model.handleAttachmentTap(remote)
        await waitUntil { model.fullscreenAttachmentItem != nil }

        XCTAssertEqual(model.fullscreenAttachmentItem, local)
        XCTAssertTrue(model.fullscreenAttachmentPresented)
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        iterations: Int = 200
    ) async {
        for _ in 0..<iterations where !predicate() {
            await Task.yield()
        }
        XCTAssertTrue(predicate())
    }
}

@MainActor
private final class AttemptRecorder: @unchecked Sendable {
    private var results: [Bool]
    private(set) var drafts: [DraftMessage] = []

    init(results: [Bool]) {
        self.results = results
    }

    func submit(_ draft: DraftMessage) -> Bool {
        drafts.append(draft)
        return results.removeFirst()
    }
}

@MainActor
private final class CommitGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var submittedDraft: DraftMessage?

    var hasSubmission: Bool { submittedDraft != nil }

    func submit(_ draft: DraftMessage) async -> Bool {
        submittedDraft = draft
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ result: Bool) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
