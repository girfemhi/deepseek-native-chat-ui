import XCTest
@testable import ExyteChat
import ExyteMediaPicker
import UIKit
import UniformTypeIdentifiers
import CryptoKit

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

    func testAttachmentSheetActionsReuseExistingPickerRoutes() {
        let model = InputViewModel()
        let action = model.inputViewAction()

        action(.camera)
        XCTAssertEqual(model.mediaPickerMode, .camera)
        XCTAssertTrue(model.showMediaPicker)

        model.showMediaPicker = false
        action(.photo)
        XCTAssertEqual(model.mediaPickerMode, .photos)
        XCTAssertTrue(model.showMediaPicker)

        action(.document)
        XCTAssertTrue(model.showDocumentPicker)
        action(.giphy)
        XCTAssertTrue(model.showGiphyPicker)
        action(.location)
        XCTAssertTrue(model.showLocationPicker)
        XCTAssertEqual(ChatLocalization.simplifiedChinese.addToConversationText, "添加到对话")
        XCTAssertEqual(ChatLocalization.simplifiedChinese.photoLibraryText, "相册")
    }

    func testPasteImporterStagesImageAndDocumentsInProviderOrder() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
        let png = renderer.image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }.pngData()!
        let imageProvider = dataProvider(name: "photo.png", type: .png, data: png)
        let firstDocument = dataProvider(name: "first.pdf", type: .pdf, data: Data("first".utf8))
        let secondDocument = dataProvider(name: "second.pdf", type: .pdf, data: Data("second".utf8))
        let providers = [imageProvider, firstDocument, secondDocument].enumerated().map {
            SendableItemProvider(index: $0.offset, provider: $0.element)
        }

        let payload = await PastedContentImporter.importProviders(providers)
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.medias.count, 1)
        XCTAssertEqual(payload.documents.map { $0.0.fileName }, ["first.pdf", "second.pdf"])
        XCTAssertEqual(payload.documents.map { $0.0.contentTypeIdentifier }, [UTType.pdf.identifier, UTType.pdf.identifier])
        XCTAssertTrue(payload.ownedURLs.allSatisfy(PastedContentImporter.isOwned))
    }

    func testPastedSVGStaysDocumentWhilePNGUsesMediaPipeline() async {
        let svg = dataProvider(name: "vector.svg", type: .svg, data: Data("<svg/>".utf8))
        let png = dataProvider(name: "bitmap.png", type: .png, data: Data([0x89, 0x50, 0x4E, 0x47]))
        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: svg),
            SendableItemProvider(index: 1, provider: png)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.map { $0.0.fileName }, ["vector.svg"])
        XCTAssertEqual(payload.documents.first?.0.contentTypeIdentifier, UTType.svg.identifier)
        XCTAssertEqual(payload.medias.count, 1)
    }

    func testPastedGIFAndPDFStayOriginalDocuments() async {
        let gif = dataProvider(name: "animated.gif", type: .gif, data: Data("GIF89a".utf8))
        let pdf = dataProvider(name: "paper.pdf", type: .pdf, data: Data("%PDF".utf8))
        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: gif),
            SendableItemProvider(index: 1, provider: pdf)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertTrue(payload.medias.isEmpty)
        XCTAssertEqual(payload.documents.map { $0.0.fileName }, ["animated.gif", "paper.pdf"])
    }

    func testUnnamedGenericPDFGetsFriendlyNameAndSpecificMIME() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
            completion(Data("%PDF-1.7".utf8), nil)
            return nil
        }
        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.first?.0.fileName, "Pasted file.pdf")
        XCTAssertEqual(payload.documents.first?.0.contentTypeIdentifier, UTType.pdf.identifier)
        XCTAssertFalse(payload.documents.first?.0.fileName.contains(PastedContentImporter.filenamePrefix) == true)
    }

    func testPasteImporterCopiesFileURLAndNeverDeletesOriginal() async throws {
        let original = FileManager.tempDirPath.appendingPathComponent("source-\(UUID().uuidString).docx")
        try Data("original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let provider = NSItemProvider(item: original as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.suggestedName = "source.docx"

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertNotEqual(payload.documents[0].0.url, original)
        XCTAssertTrue(PastedContentImporter.isOwned(payload.documents[0].0.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testPasteMenuIsAvailableForPDFMetadata() throws {
        let source = FileManager.tempDirPath.appendingPathComponent("paste-menu-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let oldProviders = UIPasteboard.general.itemProviders
        defer { UIPasteboard.general.itemProviders = oldProviders }
        UIPasteboard.general.itemProviders = [NSItemProvider(contentsOf: source)!]
        let textView = AttachmentPasteTextView()

        XCTAssertTrue(textView.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }

    func testFileURLIsStagedBeforeProviderCompletionInvalidatesSource() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("ephemeral-\(UUID().uuidString).pdf")
        try Data("ephemeral".utf8).write(to: source)
        let provider = EphemeralFileURLItemProvider(source: source)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), Data("ephemeral".utf8))
    }

    func testFileURLCallbackUnwrapsLegacyWrapperBeforeStagingPDF() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("file-url-wrapper-source-\(UUID().uuidString).pdf")
        let wrapper = FileManager.tempDirPath.appendingPathComponent("file-url-wrapper-\(UUID().uuidString)")
        let expected = Data("%PDF-file-url-callback".utf8)
        try expected.write(to: source)
        let wrapperData = try PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString, "", [String: String]()],
            format: .binary,
            options: 0
        )
        try wrapperData.write(to: wrapper)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: wrapper)
        }
        let provider = EphemeralFileURLItemProvider(source: wrapper)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
        XCTAssertEqual(payload.documents[0].0.fileName, source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFileURLCallbackPreservesActualPropertyListDocument() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("actual-file-url-\(UUID().uuidString).plist")
        let expected = try PropertyListSerialization.data(
            fromPropertyList: ["file:///private/should-not-be-followed.pdf", "", [String: String]()],
            format: .binary,
            options: 0
        )
        try expected.write(to: source)
        let provider = EphemeralFileURLItemProvider(source: source)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(payload.documents[0].0.fileName, source.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
    }

    func testPasteboardRoundTripFileProviderCopiesUnderlyingPDFBytes() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("示例交付清单-\(UUID().uuidString).pdf")
        var expected = Data("%PDF-1.7\n".utf8)
        expected.append(Data(repeating: 0x41, count: 20 * 1_024 - expected.count))
        try expected.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let previousProviders = UIPasteboard.general.itemProviders
        defer { UIPasteboard.general.itemProviders = previousProviders }
        UIPasteboard.general.itemProviders = [NSItemProvider(contentsOf: source)!]
        let roundTripped = UIPasteboard.general.itemProviders
        roundTripped.forEach { $0.suggestedName = nil }

        let payload = await PastedContentImporter.importProviders(
            roundTripped.enumerated().map { SendableItemProvider(index: $0.offset, provider: $0.element) }
        )
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        let staged = try Data(contentsOf: payload.documents[0].0.url)
        XCTAssertEqual(SHA256.hash(data: staged), SHA256.hash(data: expected))
        XCTAssertEqual(staged.count, expected.count)
        XCTAssertTrue(staged.starts(with: Data("%PDF-".utf8)))
        XCTAssertEqual(payload.documents[0].0.contentTypeIdentifier, UTType.pdf.identifier)
        XCTAssertEqual(payload.documents[0].0.fileName, source.lastPathComponent)
        XCTAssertFalse(payload.documents[0].0.fileName.contains(PastedContentImporter.filenamePrefix))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMalformedFileURLArchiveIsRejectedWithoutStageLeak() async {
        let before = stagedPasteFilenames()
        let provider = NSItemProvider(item: Data("bplist00-not-valid".utf8) as NSData, typeIdentifier: UTType.fileURL.identifier)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])

        XCTAssertTrue(payload.documents.isEmpty)
        XCTAssertTrue(payload.medias.isEmpty)
        XCTAssertEqual(stagedPasteFilenames(), before)
    }

    func testSecureArchivedNSURLFileRepresentationIsDecodedAndStaged() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("secure-url-\(UUID().uuidString).pdf")
        let expected = Data("%PDF-secure".utf8)
        try expected.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let archive = try NSKeyedArchiver.archivedData(withRootObject: source as NSURL, requiringSecureCoding: true)
        XCTAssertTrue(archive.starts(with: Data("bplist00".utf8)))
        let provider = NSItemProvider(item: archive as NSData, typeIdentifier: UTType.fileURL.identifier)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
    }

    func testLegacyThreeItemFileURLWrapperFromGenericFileRepresentationCopiesPDF() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("legacy-wrapper-source-\(UUID().uuidString).pdf")
        let wrapper = FileManager.tempDirPath.appendingPathComponent("legacy-wrapper-\(UUID().uuidString)")
        let expected = Data("%PDF-legacy-real-bytes".utf8)
        try expected.write(to: source)
        let wrapperData = try PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString, "", [String: String]()],
            format: .binary,
            options: 0
        )
        try wrapperData.write(to: wrapper)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: wrapper)
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(wrapper, true, nil)
            return nil
        }

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
        XCTAssertTrue(try Data(contentsOf: payload.documents[0].0.url).starts(with: Data("%PDF-".utf8)))
    }

    func testSpecificFileRepresentationDoesNotStageWrapperWhenResolvedSourceIsMissing() async throws {
        let missingSource = FileManager.tempDirPath.appendingPathComponent("missing-wrapper-source-\(UUID().uuidString).pdf")
        let wrapper = FileManager.tempDirPath.appendingPathComponent("missing-wrapper-\(UUID().uuidString)")
        let wrapperData = try PropertyListSerialization.data(
            fromPropertyList: [missingSource.absoluteString, "", [String: String]()],
            format: .binary,
            options: 0
        )
        try wrapperData.write(to: wrapper)
        defer { try? FileManager.default.removeItem(at: wrapper) }
        let before = stagedPasteFilenames()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(nil, nil)
            return nil
        }
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(wrapper, true, nil)
            return nil
        }

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])

        XCTAssertTrue(payload.documents.isEmpty)
        XCTAssertTrue(payload.medias.isEmpty)
        XCTAssertEqual(stagedPasteFilenames(), before)
    }

    func testLegacyFileURLWrapperFromGenericDataCallbackCopiesPDF() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("legacy-data-source-\(UUID().uuidString).pdf")
        let expected = Data("%PDF-legacy-data-callback".utf8)
        try expected.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let wrapperData = try PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString, "", [String: String]()],
            format: .binary,
            options: 0
        )
        let provider = LegacyDataFallbackItemProvider(wrapperData: wrapperData)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
        XCTAssertEqual(payload.documents[0].0.fileName, source.lastPathComponent)
    }

    func testLegacyFileURLWrapperFromSpecificPDFDataCallbackCopiesPDF() async throws {
        let source = FileManager.tempDirPath.appendingPathComponent("specific-pdf-data-source-\(UUID().uuidString).pdf")
        let expected = Data("%PDF-specific-data-callback".utf8)
        try expected.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let wrapperData = try PropertyListSerialization.data(
            fromPropertyList: [source.absoluteString, "", [String: String]()],
            format: .binary,
            options: 0
        )
        let provider = SpecificPDFDataFallbackItemProvider(wrapperData: wrapperData)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), expected)
        XCTAssertEqual(payload.documents[0].0.fileName, source.lastPathComponent)
    }

    func testActualPropertyListDocumentIsNotUnwrappedAsFileURLWrapper() async throws {
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["file:///private/should-not-be-followed.pdf", "", [String: String]()],
            format: .binary,
            options: 0
        )
        let provider = dataProvider(name: "actual.plist", type: .propertyList, data: plistData)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: provider)
        ])
        defer { PastedContentImporter.deleteOwned(payload.ownedURLs) }

        XCTAssertEqual(payload.documents.count, 1)
        XCTAssertEqual(payload.documents[0].0.fileName, "actual.plist")
        XCTAssertEqual(try Data(contentsOf: payload.documents[0].0.url), plistData)
    }

    func testPasteDetectionLeavesPlainTextAndLongWebURLToUIKitFallback() {
        let text = NSItemProvider(object: "plain text" as NSString)
        let longURL = NSItemProvider(object: "https://example.com/" + String(repeating: "a", count: 2_000) as NSString)

        XCTAssertFalse(PastedContentImporter.containsAttachment([text]))
        XCTAssertFalse(PastedContentImporter.containsAttachment([longURL]))
    }

    func testPasteImporterRejectsFolderAndSymlinkWithoutLeavingPartialStage() async throws {
        let folder = FileManager.tempDirPath.appendingPathComponent("paste-folder-\(UUID().uuidString)", isDirectory: true)
        let source = FileManager.tempDirPath.appendingPathComponent("paste-source-\(UUID().uuidString).pdf")
        let symlink = FileManager.tempDirPath.appendingPathComponent("paste-link-\(UUID().uuidString).pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: symlink)
            try? FileManager.default.removeItem(at: source)
        }
        let before = stagedPasteFilenames()
        let folderProvider = NSItemProvider(item: folder as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let symlinkProvider = NSItemProvider(item: symlink as NSURL, typeIdentifier: UTType.fileURL.identifier)

        let payload = await PastedContentImporter.importProviders([
            SendableItemProvider(index: 0, provider: folderProvider),
            SendableItemProvider(index: 1, provider: symlinkProvider)
        ])

        XCTAssertTrue(payload.medias.isEmpty)
        XCTAssertTrue(payload.documents.isEmpty)
        XCTAssertEqual(stagedPasteFilenames(), before)
    }

    func testDeferredAckRemovesSubmittedPasteButKeepsInFlightNewDocument() async {
        let provider = dataProvider(name: "submitted.pdf", type: .pdf, data: Data("submitted".utf8))
        let model = InputViewModel()
        model.onStart()
        model.stagePastedProviders([provider], insertText: { _ in })
        await waitUntil { !model.isImportingPaste && model.attachments.documents.count == 1 }
        let stagedURL = model.attachments.documents[0].url
        let gate = CommitGate()
        model.sendCommitMode = .deferred { draft in await gate.submit(draft) }

        model.send()
        await waitUntil { gate.hasSubmission }
        let newDocument = DocumentItem(url: URL(fileURLWithPath: "/tmp/new-after-send.pdf"))
        model.attachments.documents.append(newDocument)
        gate.resolve(true)
        await waitUntil { !model.isCommitting }

        XCTAssertEqual(model.attachments.documents.map(\.id), [newDocument.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testCancelledPasteImportDoesNotAttachOrLeakOwnedStage() async {
        let provider = NSItemProvider()
        provider.suggestedName = "cancelled.pdf"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                completion(Data("cancelled".utf8), nil)
            }
            return nil
        }
        let before = stagedPasteFilenames()
        let state = ChatComposerState(inputViewModel: InputViewModel())
        state.inputViewModel.stagePastedProviders([provider], insertText: { _ in })

        state.discard()
        try? await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(state.inputViewModel.attachments.documents.isEmpty)
        XCTAssertTrue(state.inputViewModel.attachments.medias.isEmpty)
        XCTAssertEqual(stagedPasteFilenames(), before)
    }

    func testSendRequestedDuringPasteWaitsForStagingToFinish() async {
        let provider = NSItemProvider()
        provider.suggestedName = "queued.pdf"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                completion(Data("queued".utf8), nil)
            }
            return nil
        }
        let model = InputViewModel()
        var submitted: DraftMessage?
        model.sendCommitMode = .deferred { draft in
            submitted = draft
            return false
        }
        model.stagePastedProviders([provider], insertText: { _ in })

        model.send()
        XCTAssertNil(submitted)
        await waitUntil { !model.isImportingPaste && !model.isCommitting && submitted != nil }

        XCTAssertEqual(submitted?.documents.first?.fileName, "queued.pdf")
        let stagedURLs = submitted?.documents.map(\.url) ?? []
        PastedContentImporter.deleteOwned(stagedURLs)
    }

    func testDiscardCanRetainPastedFileUntilExplicitOwnedFilesRelease() async {
        let state = ChatComposerState(inputViewModel: InputViewModel())
        let provider = dataProvider(name: "retained.pdf", type: .pdf, data: Data("retained".utf8))
        state.inputViewModel.stagePastedProviders([provider], insertText: { _ in })
        await waitUntil { !state.inputViewModel.isImportingPaste && state.inputViewModel.attachments.documents.count == 1 }
        let stagedURL = state.inputViewModel.attachments.documents[0].url

        state.discard(deleteOwnedRecordings: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        await state.releaseOwnedFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testCompatibilityRecordingReleaseAlsoReleasesRetainedPaste() async {
        let state = ChatComposerState(inputViewModel: InputViewModel())
        let provider = dataProvider(name: "compat.pdf", type: .pdf, data: Data("compat".utf8))
        state.inputViewModel.stagePastedProviders([provider], insertText: { _ in })
        await waitUntil { !state.inputViewModel.isImportingPaste && state.inputViewModel.attachments.documents.count == 1 }
        let stagedURL = state.inputViewModel.attachments.documents[0].url

        state.discard(deleteOwnedRecordings: false)
        await state.releaseOwnedRecordings()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    func testDefaultDiscardDeletesOwnedPastedFile() async {
        let state = ChatComposerState(inputViewModel: InputViewModel())
        let provider = dataProvider(name: "delete.pdf", type: .pdf, data: Data("delete".utf8))
        state.inputViewModel.stagePastedProviders([provider], insertText: { _ in })
        await waitUntil { !state.inputViewModel.isImportingPaste && state.inputViewModel.attachments.documents.count == 1 }
        let stagedURL = state.inputViewModel.attachments.documents[0].url

        state.discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
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

    private func dataProvider(name: String, type: UTType, data: Data) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    private func stagedPasteFilenames() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.tempDirPath.path)) ?? []
        return Set(names.filter { $0.hasPrefix(PastedContentImporter.filenamePrefix) })
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        iterations: Int = 200
    ) async {
        for _ in 0..<iterations where !predicate() {
            try? await Task.sleep(for: .milliseconds(1))
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

private final class EphemeralFileURLItemProvider: NSItemProvider {
    private let source: URL

    init(source: URL) {
        self.source = source
        super.init()
    }

    override var registeredTypeIdentifiers: [String] {
        [UTType.fileURL.identifier]
    }

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.fileURL.identifier
    }

    override func loadItem(
        forTypeIdentifier typeIdentifier: String,
        options: [AnyHashable: Any]? = nil,
        completionHandler: NSItemProvider.CompletionHandler? = nil
    ) {
        completionHandler?(source as NSURL, nil)
        try? FileManager.default.removeItem(at: source)
    }
}

private final class LegacyDataFallbackItemProvider: NSItemProvider {
    private let wrapperData: Data

    init(wrapperData: Data) {
        self.wrapperData = wrapperData
        super.init()
    }

    override var registeredTypeIdentifiers: [String] {
        [UTType.fileURL.identifier, UTType.data.identifier]
    }

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.fileURL.identifier || typeIdentifier == UTType.data.identifier
    }

    override func loadItem(
        forTypeIdentifier typeIdentifier: String,
        options: [AnyHashable: Any]? = nil,
        completionHandler: NSItemProvider.CompletionHandler? = nil
    ) {
        completionHandler?(nil, nil)
    }

    override func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, nil)
        return completedProgress()
    }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping (Data?, Error?) -> Void
    ) -> Progress {
        completionHandler(typeIdentifier == UTType.data.identifier ? wrapperData : nil, nil)
        return completedProgress()
    }

    private func completedProgress() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}

private final class SpecificPDFDataFallbackItemProvider: NSItemProvider {
    private let wrapperData: Data

    init(wrapperData: Data) {
        self.wrapperData = wrapperData
        super.init()
    }

    override var registeredTypeIdentifiers: [String] { [UTType.pdf.identifier] }

    override func hasItemConformingToTypeIdentifier(_ typeIdentifier: String) -> Bool {
        typeIdentifier == UTType.pdf.identifier
    }

    override func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, nil)
        return completedProgress()
    }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping (Data?, Error?) -> Void
    ) -> Progress {
        completionHandler(typeIdentifier == UTType.pdf.identifier ? wrapperData : nil, nil)
        return completedProgress()
    }

    private func completedProgress() -> Progress {
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}
