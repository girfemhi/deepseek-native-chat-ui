import XCTest
@testable import ExyteChat
import ExyteMediaPicker
import UIKit

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

    func testDeferredAcknowledgementAfterStopPublishesEmptyDraft() async {
        let gate = CommitGate()
        let model = InputViewModel()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }
        model.onStart()
        model.text = "send me"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { gate.hasSubmission }
        model.onStop()
        await waitUntil { snapshots.last?.text == "send me" }
        XCTAssertEqual(snapshots.last?.text, "send me")

        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(snapshots.last?.id, gate.submittedDraft?.id)
        XCTAssertEqual(snapshots.last?.createdAt, gate.submittedDraft?.createdAt)
        XCTAssertEqual(snapshots.last?.text, "")
        XCTAssertTrue(snapshots.last?.medias.isEmpty == true)
        XCTAssertTrue(snapshots.last?.documents.isEmpty == true)
    }

    func testDeferredAcknowledgementAfterStopPublishesNewText() async {
        let gate = CommitGate()
        let model = InputViewModel()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }
        model.onStart()
        model.text = "send me"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { gate.hasSubmission }
        model.text = "next draft"
        model.onStop()
        await waitUntil { snapshots.last?.text == "next draft" }
        XCTAssertEqual(snapshots.last?.text, "next draft")

        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(model.text, "next draft")
        XCTAssertEqual(snapshots.last?.text, "next draft")
        XCTAssertNotEqual(snapshots.last?.id, gate.submittedDraft?.id)
        XCTAssertNotEqual(snapshots.last?.createdAt, gate.submittedDraft?.createdAt)
    }

    func testSharedComposerStateRemountPreventsOldAcknowledgementOverwritingNewEdit() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let gate = CommitGate()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }
        model.onStart()
        model.text = "old submission"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { gate.hasSubmission }
        model.onStop()
        model.onStart()
        model.text = "new edit"
        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(model.text, "new edit")
        XCTAssertEqual(snapshots.last?.text, "new edit")
        XCTAssertNotEqual(snapshots.last?.id, gate.submittedDraft?.id)
    }

    func testOldMountStoppingAfterNewMountKeepsNewDraftSubscriptionAndCallback() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let oldMount = UUID()
        let newMount = UUID()
        var oldSnapshots: [DraftMessage] = []
        var newSnapshots: [DraftMessage] = []

        model.onDraftChange = { oldSnapshots.append($0) }
        model.onStart(mountID: oldMount)
        model.text = "A"

        model.onDraftChange = { newSnapshots.append($0) }
        model.onStart(mountID: newMount)
        model.onStop(mountID: oldMount)
        model.text = "B"
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(oldSnapshots.count, 0)
        XCTAssertEqual(newSnapshots.last?.text, "B")
        model.onStop(mountID: newMount)
    }

    func testLastMountStopFinalizesAndRetainsActiveRecordingDraft() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let mountID = UUID()
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("recorded".utf8).write(to: ownedURL)
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart(mountID: mountID)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { model.attachments.recording?.url == ownedURL }

        model.onStop(mountID: mountID)
        await waitUntilAsync { !(await recorder.isRecording) }
        await waitUntil { snapshots.last?.recording?.url == ownedURL }

        XCTAssertEqual(model.attachments.recording?.url, ownedURL)
        XCTAssertEqual(model.state, .hasRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))

        state.discard()
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
    }

    func testLastMountStopSynchronouslyPublishesTailBeforeImmediateDiscard() {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let mountID = UUID()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart(mountID: mountID)
        model.text = "tail before discard"

        model.onStop(mountID: mountID)
        state.discard()

        XCTAssertTrue(snapshots.contains { $0.text == "tail before discard" })
    }

    func testUnmountThenResetCanRetainOwnedRecordingUntilDurableCopyCompletes() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let mountID = UUID()
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        let expectedData = Data("durable recording bytes".utf8)
        try expectedData.write(to: ownedURL)
        model.onStart(mountID: mountID)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { model.attachments.recording?.url == ownedURL }

        model.onStop(mountID: mountID)
        let finalization = await state.finalizeForUnmount()
        XCTAssertEqual(finalization.savedDraft?.recording?.url, ownedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))

        let copiedData = try Data(contentsOf: ownedURL)
        XCTAssertEqual(copiedData, expectedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))

        state.discard(deleteOwnedRecordings: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedURL.path))
        await state.releaseOwnedRecordings()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testFinalizeUnmountReturnsNilForAlreadyPublishedUnchangedDraft() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        model.onDraftChange = { _ in }
        model.onStart()
        model.text = "already persisted"
        state.checkpoint()

        let finalization = await state.finalizeForUnmount()

        XCTAssertTrue(finalization.isNoChange)
    }

    func testFinalizeUnmountReturnsPendingTextWithoutDependingOnCallback() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        model.onStart()
        model.text = "pending tail"

        let finalization = await state.finalizeForUnmount()

        XCTAssertEqual(finalization.savedDraft?.text, "pending tail")
    }

    func testHostCanConsumeAutomaticUnmountRecordingSnapshotAfterCallbackRan() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let mountID = UUID()
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("final bytes".utf8).write(to: ownedURL)
        var callbackSnapshots: [DraftMessage] = []
        model.onDraftChange = { callbackSnapshots.append($0) }
        model.onStart(mountID: mountID)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { model.attachments.recording?.url == ownedURL }

        model.onStop(mountID: mountID)
        await waitUntilAsync { !(await recorder.isRecording) }
        await waitUntil { callbackSnapshots.last?.recording?.url == ownedURL }
        let directFinalization = await state.finalizeForUnmount()

        XCTAssertEqual(directFinalization.savedDraft?.recording?.url, ownedURL)
        XCTAssertEqual(try Data(contentsOf: ownedURL), Data("final bytes".utf8))

        state.discard()
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
    }

    func testHostCanConsumeSameUnmountTextSnapshotAfterCallbackWasIgnored() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let mountID = UUID()
        var callbackSnapshot: DraftMessage?
        model.onDraftChange = { callbackSnapshot = $0 }
        model.onStart(mountID: mountID)
        model.text = "tail callback intentionally ignored by host"

        model.onStop(mountID: mountID)
        await waitUntil { callbackSnapshot != nil }
        let directFinalization = await state.finalizeForUnmount()

        XCTAssertEqual(directFinalization.savedDraft?.id, callbackSnapshot?.id)
        XCTAssertEqual(directFinalization.savedDraft?.createdAt, callbackSnapshot?.createdAt)
        XCTAssertEqual(directFinalization.savedDraft?.text, callbackSnapshot?.text)
    }

    func testHostCanConsumeRemoveEmptyWhenUnmountCallbackWasIgnored() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let mountID = UUID()
        var callbacks: [DraftMessage] = []
        model.onDraftChange = { callbacks.append($0) }
        model.onStart(mountID: mountID)
        model.text = "persisted first"
        state.checkpoint()
        model.text = ""

        model.onStop(mountID: mountID)
        await waitUntil { callbacks.last?.text == "" }
        let directFinalization = await state.finalizeForUnmount()

        XCTAssertTrue(directFinalization.isRemoveEmpty)
    }

    func testOldMountStopDoesNotFinalizeRecordingWhileNewMountRemains() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let oldMount = UUID()
        let newMount = UUID()
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("recorded".utf8).write(to: ownedURL)
        model.onStart(mountID: oldMount)
        model.onStart(mountID: newMount)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { model.attachments.recording?.url == ownedURL }

        model.onStop(mountID: oldMount)
        await Task.yield()
        let isStillRecording = await recorder.isRecording

        XCTAssertTrue(isStillRecording)
        XCTAssertEqual(model.attachments.recording?.url, ownedURL)

        model.onStop(mountID: newMount)
        await waitUntilAsync { !(await recorder.isRecording) }
        state.discard()
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
    }

    func testDeferredAcknowledgementDoesNotClearABAEdit() async {
        let state = ChatComposerState()
        let model = state.inputViewModel
        let gate = CommitGate()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }
        model.onStart()
        model.text = "A"
        model.state = .hasTextOrMedia

        model.send()
        await waitUntil { gate.hasSubmission }
        model.text = "B"
        model.text = "A"
        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(model.text, "A")
        XCTAssertEqual(snapshots.last?.text, "A")
        XCTAssertNotEqual(snapshots.last?.id, gate.submittedDraft?.id)
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

    func testInitialDraftRestoresAllComposerFieldsOnlyOnce() async {
        let createdAt = Date(timeIntervalSince1970: 123_456)
        let media = Media(source: TestMediaSource(url: URL(fileURLWithPath: "/tmp/photo.jpg")))
        let document = DocumentItem(url: URL(fileURLWithPath: "/tmp/report.pdf"), fileName: "report.pdf")
        let recording = Recording(duration: 3, waveformSamples: [0.1, 0.5], url: URL(fileURLWithPath: "/tmp/audio.m4a"))
        let reply = ReplyMessage(
            id: "reply-1",
            user: User(id: "user-1", name: "User", avatarURL: nil, isCurrentUser: false),
            createdAt: createdAt,
            text: "quoted"
        )
        let draft = DraftMessage(
            id: "draft-1",
            text: "restored",
            medias: [media],
            giphyMedia: nil,
            documents: [document],
            staticLocation: StaticLocation(latitude: 1, longitude: 2),
            liveLocation: LiveLocation(
                latitude: 3,
                longitude: 4,
                startedAt: createdAt,
                expiresAt: createdAt.addingTimeInterval(3_600)
            ),
            recording: recording,
            replyMessage: reply,
            createdAt: createdAt
        )
        let model = InputViewModel()
        model.initialDraft = draft

        model.onStart()

        XCTAssertEqual(model.text, draft.text)
        XCTAssertEqual(model.attachments.medias.map(\.id), draft.medias.map(\.id))
        XCTAssertEqual(model.attachments.documents, draft.documents)
        XCTAssertEqual(model.attachments.staticLocation, draft.staticLocation)
        XCTAssertEqual(model.attachments.liveLocation, draft.liveLocation)
        XCTAssertEqual(model.attachments.recording, draft.recording)
        XCTAssertEqual(model.attachments.replyMessage, draft.replyMessage)
        await Task.yield()
        XCTAssertEqual(model.state, .hasRecording)

        model.onStop()
        model.initialDraft = DraftMessage(
            text: "must not replace",
            medias: [],
            giphyMedia: nil,
            recording: nil,
            replyMessage: nil,
            createdAt: Date()
        )
        model.onStart()
        XCTAssertEqual(model.text, "restored")
    }

    func testDraftSnapshotRoundTripUsesStableIdentityAndEmitsEmpty() async {
        let media = Media(source: TestMediaSource(url: URL(fileURLWithPath: "/tmp/photo.jpg")))
        let document = DocumentItem(url: URL(fileURLWithPath: "/tmp/report.pdf"))
        let model = InputViewModel()
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart()

        model.text = "work in progress"
        model.attachments.medias = [media]
        model.attachments.documents = [document]
        model.attachments.recording = Recording(duration: 2, url: URL(fileURLWithPath: "/tmp/audio.m4a"))
        model.attachments.staticLocation = StaticLocation(latitude: 10, longitude: 20)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(snapshots.isEmpty)

        let saved = snapshots.last!
        XCTAssertNotNil(saved.id)
        XCTAssertEqual(saved.text, model.text)
        XCTAssertEqual(saved.medias.map(\.id), [media.id])
        XCTAssertEqual(saved.documents, [document])
        XCTAssertEqual(saved.recording, model.attachments.recording)
        XCTAssertEqual(saved.staticLocation, model.attachments.staticLocation)

        model.reset()
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertGreaterThanOrEqual(snapshots.count, 2)

        let empty = snapshots.last!
        XCTAssertEqual(empty.id, saved.id)
        XCTAssertEqual(empty.createdAt, saved.createdAt)
        XCTAssertEqual(empty.text, "")
        XCTAssertTrue(empty.medias.isEmpty)
        XCTAssertTrue(empty.documents.isEmpty)
        XCTAssertNil(empty.recording)
    }

    func testDisablingInputClosesPickersAndPreservesDraft() async {
        let document = DocumentItem(url: URL(fileURLWithPath: "/tmp/report.pdf"))
        let model = InputViewModel()
        model.text = "keep"
        model.attachments.documents = [document]
        model.attachments.recording = Recording(
            duration: 1,
            url: RecordingFileStore.makeURL(fileExtension: ".m4a")
        )
        model.state = .isRecordingTap
        model.showMediaPicker = true
        model.showGiphyPicker = true
        model.showDocumentPicker = true
        model.showLocationPicker = true

        model.setInputEnabled(false)
        await waitUntil { model.state != .isRecordingTap }

        XCTAssertFalse(model.showMediaPicker)
        XCTAssertFalse(model.showGiphyPicker)
        XCTAssertFalse(model.showDocumentPicker)
        XCTAssertFalse(model.showLocationPicker)
        XCTAssertEqual(model.text, "keep")
        XCTAssertEqual(model.attachments.documents, [document])
        XCTAssertNotNil(model.attachments.recording)
        XCTAssertEqual(model.state, .hasRecording)
    }

    func testDefaultMenuActionInitializerDoesNotRecurse() {
        XCTAssertEqual(DefaultMessageMenuAction(), .copy)
    }

    func testDefaultAttachmentsProjectionRemovesOnlyTextAndReply() {
        let createdAt = Date(timeIntervalSince1970: 42)
        let attachment = Attachment(
            id: "image-1",
            url: URL(fileURLWithPath: "/tmp/image.jpg"),
            type: .image
        )
        let reply = ReplyMessage(
            id: "reply-1",
            user: User(id: "user-2", name: "Other", avatarURL: nil, isCurrentUser: false),
            createdAt: createdAt,
            text: "reply"
        )
        let message = Message(
            id: "message-1",
            user: User(id: "user-1", name: "Agent", avatarURL: nil, isCurrentUser: false),
            createdAt: createdAt,
            text: "**Markdown**",
            attachments: [attachment],
            recording: Recording(duration: 1),
            replyMessage: reply
        )
        let params = MessageBuilderParameters(
            message: message,
            positionInGroup: .single,
            positionInMessagesSection: .single,
            positionInCommentsGroup: nil,
            showContextMenuClosure: {},
            messageActionClosure: { _, _ in },
            showAttachmentClosure: { _ in }
        )

        let projected = params.attachmentsOnlyMessage
        XCTAssertFalse(projected.hasText)
        XCTAssertNil(projected.replyMessage)
        XCTAssertEqual(projected.attachments, message.attachments)
        XCTAssertEqual(projected.recording, message.recording)
        XCTAssertEqual(projected.id, message.id)
    }

    func testPortableThemeImagesActuallyInitialize() {
        let names = [
            "backArrow", "camera", "contact", "document", "location", "photo",
            "pickDocument", "pickLocation", "pickPhoto", "add", "arrowSend",
            "sticker", "attach", "attachCamera", "microphone", "chevronDown",
            "chevronRight", "attachedDocument", "MuteVideo", "pauseAudio",
            "playAudio", "delete", "edit", "forward", "retry", "save", "select",
            "cancelRecord", "deleteRecord", "lockRecord", "sendRecord", "stopRecord",
            "waiting", "Poweredby_100px-Black_VertText", "Poweredby_100px-White_VertText"
        ]
        for name in names {
            XCTAssertNotNil(UIImage(named: name, in: ChatPortableImages.bundle, compatibleWith: nil), name)
        }

        _ = ChatTheme.Images()
        _ = ChatTheme.agentDefault.images
    }

    func testPortableColorsPreserveAssetCatalogAppearance() {
        let light = UIColor(ChatPortableColors.mainBG)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = UIColor(ChatPortableColors.mainBG)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        assertRGBA(light, 1, 1, 1, 1)
        assertRGBA(dark, 0, 0, 0, 1)
    }

    func testLocalDocumentsUseQuickLookAndRemoteURLsRemainExternal() {
        let local = URL(fileURLWithPath: "/tmp/report.pdf")
        let remote = URL(string: "https://example.invalid/report.pdf")!

        XCTAssertEqual(AttachmentsPage.documentOpenRoute(for: local), .quickLook(local))
        XCTAssertEqual(AttachmentsPage.documentOpenRoute(for: remote), .external(remote))
        XCTAssertEqual(PreviewItem(url: local).previewItemURL, local)
        XCTAssertEqual(ChatLocalization.simplifiedChinese.openDocumentText, "打开文件")
    }

    func testComposerLayoutDefaultsToClassicAndSupportsEditorialOverride() {
        XCTAssertEqual(ChatTheme.Style().inputLayout, .classic)
        XCTAssertEqual(ChatTheme.Style(inputLayout: .editorial).inputLayout, .editorial)

        let classic = ChatView(messages: []) { _ in }
        XCTAssertNil(classic.inputViewCustomizationParameters.inputLayout)

        let editorial = classic.inputViewLayout(.editorial)
        XCTAssertEqual(editorial.inputViewCustomizationParameters.inputLayout, .editorial)
    }

    func testComposerDiscardCancelsLateAcknowledgementAndDeletesOnlyOwnedRecording() async throws {
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        let unrelatedURL = FileManager.tempDirPath.appendingPathComponent("unrelated-recording-\(UUID().uuidString).m4a")
        try Data("owned".utf8).write(to: ownedURL)
        try Data("unrelated".utf8).write(to: unrelatedURL)
        defer { try? FileManager.default.removeItem(at: unrelatedURL) }

        let state = ChatComposerState()
        let model = state.inputViewModel
        let gate = CommitGate()
        var snapshots: [DraftMessage] = []
        var committedCount = 0
        model.onDraftChange = { snapshots.append($0) }
        model.didCommitMessage = { _ in committedCount += 1 }
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }
        model.onStart()
        model.attachments.recording = Recording(duration: 1, url: ownedURL)
        model.state = .hasRecording

        model.send()
        await waitUntil { gate.hasSubmission }
        state.discard()
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }

        XCTAssertFalse(model.isCommitting)
        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(snapshots.last?.text, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))

        gate.resolve(true)
        await Task.yield()
        XCTAssertEqual(committedCount, 0)
        XCTAssertEqual(model.state, .empty)
    }

    func testSuccessfulDeferredAcknowledgementDeletesOwnedRecording() async throws {
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("audio".utf8).write(to: ownedURL)

        let model = InputViewModel()
        model.sendCommitMode = .deferred { _ in true }
        model.attachments.recording = Recording(duration: 1, url: ownedURL)
        model.state = .hasRecording

        model.send()
        await waitUntil { !model.isCommitting }
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertNil(model.attachments.recording)
    }

    func testDeleteRecordingNeverDeletesUnownedURL() async throws {
        let unrelatedURL = FileManager.tempDirPath.appendingPathComponent("user-provided-\(UUID().uuidString).m4a")
        try Data("external".utf8).write(to: unrelatedURL)
        defer { try? FileManager.default.removeItem(at: unrelatedURL) }

        let model = InputViewModel()
        model.attachments.recording = Recording(duration: 1, url: unrelatedURL)
        model.state = .hasRecording
        model.inputViewAction()(.deleteRecord)
        await waitUntil { model.attachments.recording == nil }

        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testPendingRecordingStartReleasedAfterDiscardCannotReacquireMicrophone() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("pending".utf8).write(to: ownedURL)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        state.discard()
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
        let isRecording = await recorder.isRecording

        XCTAssertNil(model.attachments.recording)
        XCTAssertFalse(isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testPendingRecordingStartReleasedAfterDisableCannotReacquireMicrophone() async throws {
        let recorder = SuspendedRecordingService()
        let model = InputViewModel(recorder: recorder)
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("pending".utf8).write(to: ownedURL)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        model.setInputEnabled(false)
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
        let isRecording = await recorder.isRecording

        XCTAssertNil(model.attachments.recording)
        XCTAssertFalse(isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testPendingRecordingStartReleasedAfterDeleteCannotReacquireMicrophone() async throws {
        let recorder = SuspendedRecordingService()
        let model = InputViewModel(recorder: recorder)
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("pending".utf8).write(to: ownedURL)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        model.inputViewAction()(.deleteRecord)
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
        let isRecording = await recorder.isRecording

        XCTAssertNil(model.attachments.recording)
        XCTAssertFalse(isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testRecordingStartPostsPublicAudioCoordinationNotificationOnce() async {
        let recorder = SuspendedRecordingService()
        let model = InputViewModel(recorder: recorder)
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .chatAudioRecordingWillBegin,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.inputViewAction()(.recordAudioTap)

        XCTAssertEqual(notificationCount, 1)
        await waitUntilAsync { await recorder.hasPendingStart }
        model.discard()
        await recorder.releaseStart(with: nil)
    }

    func testDisabledComposerDoesNotPostRecordingNotification() {
        let model = InputViewModel()
        model.setInputEnabled(false)
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .chatAudioRecordingWillBegin,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.inputViewAction()(.recordAudioTap)

        XCTAssertEqual(notificationCount, 0)
    }

    func testCheckpointImmediatelyPublishesPendingDebounceWithLatestText() {
        let state = ChatComposerState()
        let model = state.inputViewModel
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart()
        model.text = "latest text"

        state.checkpoint()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.last?.text, "latest text")
    }

    func testCheckpointWithoutChangesDoesNotRepublishDraft() {
        let state = ChatComposerState()
        let model = state.inputViewModel
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart()
        model.text = "one revision"
        state.checkpoint()
        XCTAssertEqual(snapshots.count, 1)

        state.checkpoint()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.last?.text, "one revision")
    }

    func testBackgroundCheckpointCancelsPendingRecordingPermissionWithoutDisablingInput() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("pending".utf8).write(to: ownedURL)

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await state.checkpointForBackground()
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
        let isRecording = await recorder.isRecording

        XCTAssertTrue(model.inputEnabled)
        XCTAssertNil(model.attachments.recording)
        XCTAssertFalse(isRecording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
    }

    func testBackgroundCheckpointStopsAndRetainsActiveRecordingThenPublishesIt() async throws {
        let recorder = SuspendedRecordingService()
        let state = ChatComposerState(inputViewModel: InputViewModel(recorder: recorder))
        let model = state.inputViewModel
        let ownedURL = RecordingFileStore.makeURL(fileExtension: ".m4a")
        try Data("recorded".utf8).write(to: ownedURL)
        var snapshots: [DraftMessage] = []
        model.onDraftChange = { snapshots.append($0) }
        model.onStart()

        model.inputViewAction()(.recordAudioTap)
        await waitUntilAsync { await recorder.hasPendingStart }
        await recorder.releaseStart(with: ownedURL)
        await waitUntil { model.attachments.recording?.url == ownedURL }
        await state.checkpointForBackground()
        let isRecording = await recorder.isRecording

        XCTAssertTrue(model.inputEnabled)
        XCTAssertEqual(model.attachments.recording?.url, ownedURL)
        XCTAssertEqual(model.state, .hasRecording)
        XCTAssertEqual(snapshots.last?.recording?.url, ownedURL)
        XCTAssertFalse(isRecording)

        state.discard()
        await waitUntil { !FileManager.default.fileExists(atPath: ownedURL.path) }
    }

    private func assertRGBA(
        _ color: UIColor,
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        _ alpha: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var actualRed: CGFloat = 0
        var actualGreen: CGFloat = 0
        var actualBlue: CGFloat = 0
        var actualAlpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&actualRed, green: &actualGreen, blue: &actualBlue, alpha: &actualAlpha), file: file, line: line)
        XCTAssertEqual(actualRed, red, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actualGreen, green, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actualBlue, blue, accuracy: 0.000_001, file: file, line: line)
        XCTAssertEqual(actualAlpha, alpha, accuracy: 0.000_001, file: file, line: line)
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

    private func waitUntilAsync(
        _ predicate: @escaping () async -> Bool,
        iterations: Int = 200
    ) async {
        for _ in 0..<iterations {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("condition was not satisfied")
    }
}

private struct TestMediaSource: MediaModelProtocol {
    let url: URL
    var mediaType: MediaType? { .image }
    var duration: CGFloat? { get async { nil } }
    func getURL() async -> URL? { url }
    func getThumbnailURL() async -> URL? { url }
    func getData() async throws -> Data? { nil }
    func getThumbnailData() async -> Data? { nil }
}

private extension ChatComposerFinalization {
    var savedDraft: DraftMessage? {
        if case .save(let draft) = self { return draft }
        return nil
    }

    var isNoChange: Bool {
        if case .noChange = self { return true }
        return false
    }

    var isRemoveEmpty: Bool {
        if case .removeEmpty = self { return true }
        return false
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

private actor SuspendedRecordingService: RecordingService {
    private var pendingToken: UUID?
    private var activeToken: UUID?
    private var continuation: CheckedContinuation<URL?, Never>?

    var isAllowedToRecordAudio: Bool { true }
    var isRecording: Bool { activeToken != nil }
    var hasPendingStart: Bool { continuation != nil }

    func setRecorderSettings(_ recorderSettings: RecorderSettings) {}

    func startRecording(
        token: UUID,
        durationProgressHandler: @escaping RecordingProgressHandler
    ) async -> URL? {
        pendingToken = token
        return await withCheckedContinuation { continuation = $0 }
    }

    func releaseStart(with url: URL?) {
        activeToken = pendingToken
        pendingToken = nil
        continuation?.resume(returning: url)
        continuation = nil
    }

    func stopRecording(token: UUID?) {
        guard token == nil || activeToken == token else { return }
        activeToken = nil
    }
}
