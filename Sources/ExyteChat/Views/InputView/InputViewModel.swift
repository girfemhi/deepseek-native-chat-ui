//
//  Created by Alex.M on 20.06.2022.
//

import Foundation
import Combine
import ExyteMediaPicker
import SwiftUI

@MainActor
final class InputViewModel: ObservableObject {

    @Published var text = "" {
        didSet { textRevision += 1 }
    }
    @Published var attachments = InputViewAttachments() {
        didSet { attachmentRevision += 1 }
    }
    @Published var state: InputViewState = .empty

    @Published var showGiphyPicker = false
    @Published var showMediaPicker = false
    @Published var showDocumentPicker = false
    @Published var showLocationPicker = false

    @Published var mediaPickerMode = MediaPickerMode.photos

    @Published var showActivityIndicator = false
    @Published var isCommitting = false

    var inputEnabled = true
    var sendDisabled = false
    var sendCommitMode: SendCommitMode = .immediate
    var initialDraft: DraftMessage?
    var onDraftChange: ((DraftMessage) -> Void)?

    var recordingPlayer: RecordingPlayer?
    var didSendMessage: ((DraftMessage) -> Void)?
    var didCommitMessage: ((DraftMessage) -> Void)?

    private let recorder: any RecordingService

    private var saveEditingClosure: ((String) -> Void)?
    private var attachmentRevision = 0
    private var pendingDraft: DraftMessage?
    private var pendingDraftText: String?
    private var pendingAttachmentRevision: Int?
    private var hasRestoredInitialDraft = false
    private var isRestoringInitialDraft = false
    private var draftID: String?
    private var draftCreatedAt: Date?
    private var draftRevision = 0
    private var textRevision = 0
    private var lastPublishedDraftRevision = 0
    private var draftChangeTask: Task<Void, Never>?
    private var submissionTask: Task<Void, Never>?
    private var submissionEpoch = 0
    private var recordingStartTask: Task<Void, Never>?
    private var recordingGeneration = 0
    private var recordingToken: UUID?
    private let legacyMountID = UUID()
    private var activeMountIDs: Set<UUID> = []

    private var recordPlayerSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()

    init(recorder: any RecordingService = Recorder()) {
        self.recorder = recorder
    }
    
    func setRecorderSettings(recorderSettings: RecorderSettings = RecorderSettings()) {
        Task {
            await self.recorder.setRecorderSettings(recorderSettings)
        }
    }

    func onStart() {
        onStart(mountID: legacyMountID)
    }

    func onStart(mountID: UUID) {
        guard activeMountIDs.insert(mountID).inserted else { return }
        guard subscriptions.isEmpty else { return }
        isRestoringInitialDraft = true
        subscribeValidation()
        subscribeGiphyPicker()
        restoreInitialDraftIfNeeded()
        lastPublishedDraftRevision = draftRevision
        isRestoringInitialDraft = false
    }

    func onStop() {
        onStop(mountID: legacyMountID)
    }

    func onStop(mountID: UUID) {
        guard activeMountIDs.remove(mountID) != nil else { return }
        flushDraftChange()
        guard activeMountIDs.isEmpty else { return }
        draftChangeTask?.cancel()
        draftChangeTask = nil
        subscriptions.removeAll()
    }

    func setInputEnabled(_ enabled: Bool) {
        inputEnabled = enabled
        guard !enabled else { return }

        showMediaPicker = false
        showGiphyPicker = false
        showDocumentPicker = false
        showLocationPicker = false

        if [.isRecordingTap, .isRecordingHold, .waitingForRecordingPermission].contains(state) {
            let token = invalidateRecordingStart()
            let generation = recordingGeneration
            Task {
                await recorder.stopRecording(token: token)
                await recordingPlayer?.reset()
                guard generation == recordingGeneration else { return }
                if attachments.recording?.url == nil {
                    attachments.recording = nil
                }
                state = attachments.recording == nil ? .empty : .hasRecording
            }
        }
    }

    func discard() {
        let ownedRecordingURLs = Set([
            attachments.recording?.url,
            pendingDraft?.recording?.url
        ].compactMap { $0 }.filter(RecordingFileStore.isOwned))

        submissionEpoch += 1
        submissionTask?.cancel()
        submissionTask = nil
        let recordingToken = invalidateRecordingStart()
        draftChangeTask?.cancel()
        draftChangeTask = nil
        unsubscribeRecordPlayer()
        isCommitting = false
        showActivityIndicator = false

        reset()
        flushDraftChange(force: true)
        draftID = nil
        draftCreatedAt = nil
        lastPublishedDraftRevision = draftRevision

        Task {
            await recorder.stopRecording(token: recordingToken)
            await recordingPlayer?.reset()
            ownedRecordingURLs.forEach(RecordingFileStore.deleteIfOwned)
        }
    }

    func checkpoint() {
        flushDraftChange(force: true)
    }

    func checkpointForBackground() async {
        let token = invalidateRecordingStart()
        let generation = recordingGeneration
        await recorder.stopRecording(token: token)
        await recordingPlayer?.reset()

        if generation == recordingGeneration {
            if attachments.recording?.url == nil {
                attachments.recording = nil
                state = hasDraftContent ? .hasTextOrMedia : .empty
            } else if [.isRecordingTap, .isRecordingHold, .waitingForRecordingPermission].contains(state) {
                state = .hasRecording
            }
        }
        flushDraftChange(force: true)
    }

    func reset() {
        text = ""
        attachments = InputViewAttachments()
        state = .empty
        showGiphyPicker = false
        showMediaPicker = false
        showDocumentPicker = false
        showLocationPicker = false
        saveEditingClosure = nil
        pendingDraft = nil
        pendingDraftText = nil
        pendingAttachmentRevision = nil
    }

    func send() {
        guard inputEnabled, !sendDisabled, !isCommitting, canSubmitDraft else { return }
        isCommitting = true
        submissionEpoch += 1
        let epoch = submissionEpoch
        let recordingToken = invalidateRecordingStart()
        submissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await recorder.stopRecording(token: recordingToken)
            await recordingPlayer?.reset()
            guard epoch == submissionEpoch, !Task.isCancelled else { return }
            await sendMessage(epoch: epoch)
        }
    }

    func edit(_ closure: @escaping (String) -> Void) {
        saveEditingClosure = closure
        state = .editing
    }

    func inputViewAction() -> (InputViewAction) -> Void {
        { [weak self] in
            self?.inputViewActionInternal($0)
        }
    }

    private func inputViewActionInternal(_ action: InputViewAction) {
        guard inputEnabled else { return }
        if isCommitting {
            return
        }
        if case .send = action, sendDisabled {
            return
        }
        switch action {
        case .giphy:
            showGiphyPicker = true
        case .photo:
            mediaPickerMode = .photos
            showMediaPicker = true
        case .add:
            mediaPickerMode = .camera
        case .camera:
            mediaPickerMode = .camera
            showMediaPicker = true
        case .document:
            showDocumentPicker = true
        case .location:
            showLocationPicker = true
        case .send:
            send()
        case .recordAudioTap:
            startRecording(state: .isRecordingTap)
        case .recordAudioHold:
            startRecording(state: .isRecordingHold)
        case .recordAudioLock:
            state = .isRecordingTap
        case .stopRecordAudio:
            let token = invalidateRecordingStart()
            let generation = recordingGeneration
            Task {
                await recorder.stopRecording(token: token)
                guard generation == recordingGeneration else { return }
                if attachments.recording?.url != nil {
                    state = .hasRecording
                } else {
                    attachments.recording = nil
                    state = .empty
                }
                await recordingPlayer?.reset()
            }
        case .deleteRecord:
            let recordingURL = attachments.recording?.url
            let token = invalidateRecordingStart()
            let generation = recordingGeneration
            Task {
                unsubscribeRecordPlayer()
                await recorder.stopRecording(token: token)
                RecordingFileStore.deleteIfOwned(recordingURL)
                guard generation == recordingGeneration else { return }
                attachments.recording = nil
            }
        case .playRecord:
            state = .playingRecording
            if let recording = attachments.recording {
                Task {
                    subscribeRecordPlayer()
                    await recordingPlayer?.play(recording)
                }
            }
        case .pauseRecord:
            state = .pausedRecording
            Task {
                await recordingPlayer?.pause()
            }
        case .saveEdit:
            saveEditingClosure?(text)
            reset()
        case .cancelEdit:
            reset()
        }
    }

    private func startRecording(state requestedState: InputViewState) {
        guard inputEnabled else { return }
        NotificationCenter.default.post(name: .chatAudioRecordingWillBegin, object: nil)

        let previousToken = invalidateRecordingStart()
        recordingGeneration += 1
        let generation = recordingGeneration
        let token = UUID()
        recordingToken = token

        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await recorder.stopRecording(token: previousToken)
            guard generation == recordingGeneration,
                  recordingToken == token,
                  inputEnabled,
                  !Task.isCancelled else { return }

            let allowed = await recorder.isAllowedToRecordAudio
            guard generation == recordingGeneration,
                  recordingToken == token,
                  inputEnabled,
                  !Task.isCancelled else { return }
            state = allowed ? requestedState : .waitingForRecordingPermission
            attachments.recording = Recording()

            let url = await recorder.startRecording(token: token) { [weak self] duration, samples in
                Task { @MainActor [weak self] in
                    guard let self,
                          generation == recordingGeneration,
                          recordingToken == token else { return }
                    attachments.recording?.duration = duration
                    attachments.recording?.waveformSamples = samples
                }
            }

            guard generation == recordingGeneration,
                  recordingToken == token,
                  inputEnabled,
                  !Task.isCancelled else {
                await recorder.stopRecording(token: token)
                RecordingFileStore.deleteIfOwned(url)
                return
            }

            guard let url else {
                attachments.recording = nil
                state = .empty
                recordingToken = nil
                recordingStartTask = nil
                return
            }
            attachments.recording?.url = url
            if state == .waitingForRecordingPermission {
                state = requestedState
            }
            recordingStartTask = nil
        }
    }

    private func invalidateRecordingStart() -> UUID? {
        recordingGeneration += 1
        recordingStartTask?.cancel()
        recordingStartTask = nil
        let token = recordingToken
        recordingToken = nil
        return token
    }
}

private extension InputViewModel {

    func validateDraft() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard state != .editing else { return } // special case
            if self.attachments.recording != nil {
                if ![.isRecordingTap, .isRecordingHold, .playingRecording, .pausedRecording, .hasRecording].contains(state) {
                    state = .hasRecording
                }
                return
            }
            let hasAttachments = !self.attachments.medias.isEmpty || !self.attachments.documents.isEmpty || self.attachments.staticLocation != nil || self.attachments.liveLocation != nil
            if !self.text.isEmpty || hasAttachments {
                self.state = .hasTextOrMedia
            } else if self.text.isEmpty,
                      !hasAttachments,
                      self.attachments.recording == nil {
                self.state = .empty
            }
        }
    }

    func subscribeValidation() {
        $attachments.sink { [weak self] _ in
            self?.draftRevision += 1
            self?.validateDraft()
            self?.scheduleDraftChange()
        }
        .store(in: &subscriptions)

        $text.sink { [weak self] _ in
            self?.draftRevision += 1
            self?.validateDraft()
            self?.scheduleDraftChange()
        }
        .store(in: &subscriptions)
    }

    func subscribeGiphyPicker() {
        $showGiphyPicker
            .sink { [weak self] value in
                if !value,
                   self?.inputEnabled != false,
                   self?.isCommitting != true,
                   self?.isRestoringInitialDraft != true {
                  self?.attachments.giphyMedia = nil
                }
            }
            .store(in: &subscriptions)
    }
  
    func subscribeRecordPlayer() {
        Task { @MainActor in
            if let recordingPlayer {
                recordPlayerSubscription = recordingPlayer.didPlayTillEnd
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] in
                        self?.state = .hasRecording
                    }
            }
        }
    }

    func unsubscribeRecordPlayer() {
        recordPlayerSubscription = nil
    }
}

private extension InputViewModel {

    func restoreInitialDraftIfNeeded() {
        guard !hasRestoredInitialDraft else { return }
        hasRestoredInitialDraft = true
        guard let initialDraft else { return }

        draftID = initialDraft.id ?? UUID().uuidString
        draftCreatedAt = initialDraft.createdAt
        text = initialDraft.text

        var restoredAttachments = InputViewAttachments()
        restoredAttachments.medias = initialDraft.medias
        restoredAttachments.giphyMedia = initialDraft.giphyMedia
        restoredAttachments.documents = initialDraft.documents
        restoredAttachments.staticLocation = initialDraft.staticLocation
        restoredAttachments.liveLocation = initialDraft.liveLocation
        restoredAttachments.recording = initialDraft.recording
        restoredAttachments.replyMessage = initialDraft.replyMessage
        attachments = restoredAttachments

        if initialDraft.recording != nil {
            state = .hasRecording
        } else {
            state = hasDraftContent ? .hasTextOrMedia : .empty
        }
    }

    func scheduleDraftChange() {
        guard !isRestoringInitialDraft, onDraftChange != nil else { return }
        draftChangeTask?.cancel()
        draftChangeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            self?.flushDraftChange()
        }
    }

    func flushDraftChange(force: Bool = false) {
        guard !isRestoringInitialDraft,
              (force || draftRevision != lastPublishedDraftRevision),
              let onDraftChange else { return }

        if force {
            draftChangeTask?.cancel()
            draftChangeTask = nil
        }

        let hasContent = hasDraftContent
        guard hasContent || draftID != nil || draftCreatedAt != nil else {
            lastPublishedDraftRevision = draftRevision
            return
        }

        let snapshot = makeDraft(deferred: true)
        lastPublishedDraftRevision = draftRevision
        onDraftChange(snapshot)

        if !hasContent {
            draftID = nil
            draftCreatedAt = nil
            pendingDraft = nil
            pendingDraftText = nil
            pendingAttachmentRevision = nil
        }
    }

    func makeDraft(deferred: Bool) -> DraftMessage {
        let needsStableIdentity = deferred
            || onDraftChange != nil
            || initialDraft != nil
            || attachments.liveLocation != nil
        let messageId: String?
        let createdAt: Date
        if needsStableIdentity {
            if draftID == nil {
                draftID = UUID().uuidString
            }
            if draftCreatedAt == nil {
                draftCreatedAt = Date()
            }
            messageId = draftID
            createdAt = draftCreatedAt ?? Date()
        } else {
            messageId = nil
            createdAt = Date()
        }
        return DraftMessage(
            id: messageId,
            text: text,
            medias: attachments.medias,
            giphyMedia: attachments.giphyMedia,
            documents: attachments.documents,
            staticLocation: attachments.staticLocation,
            liveLocation: attachments.liveLocation,
            recording: attachments.recording,
            replyMessage: attachments.replyMessage,
            createdAt: createdAt
        )
    }

    func sendMessage(epoch: Int) async {
        showActivityIndicator = true
        let isDeferred: Bool
        switch sendCommitMode {
        case .immediate: isDeferred = false
        case .deferred: isDeferred = true
        }
        let canReusePendingDraft = pendingDraftText == text
            && pendingAttachmentRevision == attachmentRevision
        let draft = canReusePendingDraft ? (pendingDraft ?? makeDraft(deferred: isDeferred)) : makeDraft(deferred: isDeferred)
        let submittedAttachmentRevision = attachmentRevision
        let submittedTextRevision = textRevision

        switch sendCommitMode {
        case .immediate:
            didSendMessage?(draft)
            guard epoch == submissionEpoch, !Task.isCancelled else { return }
            showActivityIndicator = false
            reset()
            isCommitting = false
            submissionTask = nil

        case .deferred(let commit):
            let acknowledged = await commit(draft)
            guard epoch == submissionEpoch, !Task.isCancelled else { return }
            if acknowledged {
                let textUnchanged = textRevision == submittedTextRevision
                let attachmentsUnchanged = attachmentRevision == submittedAttachmentRevision
                let submittedRecordingURL = draft.recording?.url
                let submittedRecordingStillCurrent = submittedRecordingURL != nil
                    && attachments.recording?.url == submittedRecordingURL

                if textUnchanged {
                    text = ""
                }
                if attachmentsUnchanged {
                    attachments = InputViewAttachments()
                } else if submittedRecordingStillCurrent {
                    attachments.recording = nil
                }
                if submittedRecordingStillCurrent {
                    RecordingFileStore.deleteIfOwned(submittedRecordingURL)
                }
                state = hasDraftContent ? .hasTextOrMedia : .empty
                pendingDraft = nil
                pendingDraftText = nil
                pendingAttachmentRevision = nil
                if hasDraftContent, !textUnchanged || !attachmentsUnchanged {
                    draftID = nil
                    draftCreatedAt = nil
                }
                // A view may disappear while the host is awaiting ACK. Its
                // Combine subscriptions are then gone, so publish the final
                // state explicitly rather than relying on @Published sinks.
                flushDraftChange(force: true)
                didCommitMessage?(draft)
            } else {
                pendingDraft = draft
                pendingDraftText = draft.text
                pendingAttachmentRevision = submittedAttachmentRevision
            }
            showActivityIndicator = false
            isCommitting = false
            submissionTask = nil
        }
    }

    var hasDraftContent: Bool {
        !text.isEmpty
            || !attachments.medias.isEmpty
            || !attachments.documents.isEmpty
            || attachments.giphyMedia != nil
            || attachments.staticLocation != nil
            || attachments.liveLocation != nil
            || attachments.recording != nil
            || attachments.replyMessage != nil
    }

    var canSubmitDraft: Bool {
        state.canSend
            || !text.isEmpty
            || !attachments.medias.isEmpty
            || attachments.giphyMedia != nil
            || !attachments.documents.isEmpty
            || attachments.staticLocation != nil
            || attachments.liveLocation != nil
    }
}
