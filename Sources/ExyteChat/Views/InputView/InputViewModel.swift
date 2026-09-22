//
//  Created by Alex.M on 20.06.2022.
//

import Foundation
import Combine
import ExyteMediaPicker
import SwiftUI

@MainActor
final class InputViewModel: ObservableObject {

    @Published var text = ""
    @Published var attachments = InputViewAttachments()
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

    var recordingPlayer: RecordingPlayer?
    var didSendMessage: ((DraftMessage) -> Void)?
    var didCommitMessage: ((DraftMessage) -> Void)?

    private var recorder = Recorder()

    private var saveEditingClosure: ((String) -> Void)?
    private var attachmentRevision = 0
    private var pendingDraft: DraftMessage?
    private var pendingDraftText: String?
    private var pendingAttachmentRevision: Int?

    private var recordPlayerSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    
    func setRecorderSettings(recorderSettings: RecorderSettings = RecorderSettings()) {
        Task {
            await self.recorder.setRecorderSettings(recorderSettings)
        }
    }

    func onStart() {
        subscribeValidation()
        subscribeGiphyPicker()
    }

    func onStop() {
        subscriptions.removeAll()
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
        Task {
            await recorder.stopRecording()
            await recordingPlayer?.reset()
            await sendMessage()
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
            Task {
                state = await recorder.isAllowedToRecordAudio ? .isRecordingTap : .waitingForRecordingPermission
                recordAudio()
            }
        case .recordAudioHold:
            Task {
                state = await recorder.isAllowedToRecordAudio ? .isRecordingHold : .waitingForRecordingPermission
                recordAudio()
            }
        case .recordAudioLock:
            state = .isRecordingTap
        case .stopRecordAudio:
            Task {
                await recorder.stopRecording()
                if let _ = attachments.recording {
                    state = .hasRecording
                }
                await recordingPlayer?.reset()
            }
        case .deleteRecord:
            Task {
                unsubscribeRecordPlayer()
                await recorder.stopRecording()
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

    private func recordAudio() {
        Task { @MainActor [recorder] in
            if await recorder.isRecording { return }
            attachments.recording = Recording()
            let url = await recorder.startRecording { duration, samples in
                DispatchQueue.main.async { [weak self] in
                    self?.attachments.recording?.duration = duration
                    self?.attachments.recording?.waveformSamples = samples
                }
            }
            if state == .waitingForRecordingPermission {
                state = .isRecordingTap
            }
            attachments.recording?.url = url
        }
    }
}

private extension InputViewModel {

    func validateDraft() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard state != .editing else { return } // special case
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
            self?.attachmentRevision += 1
            self?.validateDraft()
        }
        .store(in: &subscriptions)

        $text.sink { [weak self] _ in
            self?.validateDraft()
        }
        .store(in: &subscriptions)
    }

    func subscribeGiphyPicker() {
        $showGiphyPicker
            .sink { [weak self] value in
                if !value {
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

    func makeDraft(deferred: Bool) -> DraftMessage {
        let messageId = deferred || attachments.liveLocation != nil ? UUID().uuidString : nil
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
            createdAt: Date()
        )
    }

    func sendMessage() async {
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

        switch sendCommitMode {
        case .immediate:
            didSendMessage?(draft)
            showActivityIndicator = false
            reset()
            isCommitting = false

        case .deferred(let commit):
            let acknowledged = await commit(draft)
            if acknowledged {
                if text == draft.text {
                    text = ""
                }
                if attachmentRevision == submittedAttachmentRevision {
                    attachments = InputViewAttachments()
                }
                state = hasDraftContent ? .hasTextOrMedia : .empty
                didCommitMessage?(draft)
                pendingDraft = nil
                pendingDraftText = nil
                pendingAttachmentRevision = nil
            } else {
                pendingDraft = draft
                pendingDraftText = draft.text
                pendingAttachmentRevision = submittedAttachmentRevision
            }
            showActivityIndicator = false
            isCommitting = false
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
