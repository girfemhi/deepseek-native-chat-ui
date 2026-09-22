//
//  InputView.swift
//  Chat
//
//  Created by Alex.M on 25.05.2022.
//

import SwiftUI
import ExyteMediaPicker
import AnchoredPopup

struct InputView: View {

    @Environment(\.chatTheme) var theme
    @Environment(\.mediaPickerTheme) var pickerTheme
    @Environment(\.chatSize) var chatSize
    @Environment(\.colorScheme) private var colorScheme

    @EnvironmentObject var keyboardState: KeyboardState
    @EnvironmentObject var globalFocusState: GlobalFocusState

    @ObservedObject var viewModel: InputViewModel
    @StateObject var recordingPlayer = RecordingPlayer()

    var inputFieldId: UUID
    var style: InputViewStyle
    var layout: InputViewLayout = .classic
    var agentInputAccessory: (() -> AnyView)? = nil
    var availableInputs: [AvailableInputType]
    var recorderSettings: RecorderSettings = RecorderSettings()
    var audioRecordingMode: AudioRecordingMode = .holdToRecord
    var photoPickerBackend: PhotoPickerBackend = .custom
    var localization: ChatLocalization

    @State var stopRecordButtonSize: CGSize = .zero
    @State var lockRecordButtonSize: CGSize = .zero

    @State var recordButtonFrame: CGRect = .zero
    @State var lockRecordFrame: CGRect = .zero
    @State var deleteRecordFrame: CGRect = .zero
    @State var inputBarFrame: CGRect = .zero

    @State var dragStart: Date?
    @State var tapDelayTimer: Timer?
    @State var cancelGesture = false
    @State private var showAttachmentActions = false

    var onAction: (InputViewAction) -> Void {
        viewModel.inputViewAction()
    }

    var state: InputViewState {
        viewModel.state
    }

    var isEditorial: Bool {
        style == .message && layout == .editorial
    }

    var actionButtonSize: CGFloat {
        isEditorial ? 44 : 48
    }

    var editorialRightButtonWidth: CGFloat {
        state == .editing ? 88 : actionButtonSize
    }

    var hasAttachmentActions: Bool {
        availableInputs.contains(.media)
            || availableInputs.contains(.document)
            || availableInputs.contains(.giphy)
            || availableInputs.contains(.staticLocation)
            || availableInputs.contains(.liveLocation)
    }

    var body: some View {
        inputLayout
            .background(backgroundColor)
            .disabled(!viewModel.inputEnabled)
            .opacity(viewModel.inputEnabled ? 1 : 0.55)
            .onAppear {
                viewModel.recordingPlayer = recordingPlayer
                viewModel.setRecorderSettings(recorderSettings: recorderSettings)
            }
            .onDrag(towards: .bottom, ofAmount: 100...) {
                keyboardState.resignFirstResponder()
            }
            .sheet(isPresented: $showAttachmentActions) {
                AttachmentActionsSheet(
                    availableInputs: availableInputs,
                    localization: localization,
                    onAction: onAction
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(theme.colors.mainBG)
            }
            .onChange(of: viewModel.inputEnabled) { _, enabled in
                if !enabled { showAttachmentActions = false }
            }
            .onChange(of: viewModel.isCommitting) { _, committing in
                if committing { showAttachmentActions = false }
            }
    }

    @ViewBuilder
    private var inputLayout: some View {
        if isEditorial {
            editorialLayout
        } else {
            classicLayout
        }
    }

    private var classicLayout: some View {
        VStack(spacing: 4) {
            viewOnTop
                .padding(.top, 6)
                .transition(.move(edge: .bottom))
                .allowsHitTesting(viewModel.inputEnabled && !viewModel.isCommitting)

            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 0) {
                    leftView
                    middleView
                    rightView
                }
                .background {
                    ComposerSurface(
                        color: style == .message ? theme.colors.inputBG : theme.colors.inputSignatureBG
                    )
                }
                .frameGetter($inputBarFrame)

                rightOutsideButton
            }
            .padding(MessageView.horizontalScreenEdgePadding, 8)
        }
    }

    private var editorialLayout: some View {
        VStack(spacing: 8) {
            viewOnTop
                .padding(.top, 4)
                .transition(.move(edge: .bottom))
                .allowsHitTesting(viewModel.inputEnabled && !viewModel.isCommitting)

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 0) {
                    middleView
                    rightView
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 48)

                HStack(spacing: 8) {
                    editorialLeadingView
                        .frame(width: 44, height: 44)

                    if let agentInputAccessory {
                        agentInputAccessory()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 44)
                            .clipped()
                    } else {
                        Spacer(minLength: 0)
                    }

                    rightOutsideButton
                        .frame(width: editorialRightButtonWidth, height: actionButtonSize)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .background {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(theme.colors.inputBG)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(theme.colors.mainText.opacity(0.08), lineWidth: 0.5)
                    }
                    .shadow(
                        color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.06),
                        radius: 2,
                        y: 1
                    )
            }
            .frameGetter($inputBarFrame)
            .padding(MessageView.horizontalScreenEdgePadding, 8)
        }
    }

    @ViewBuilder
    private var editorialLeadingView: some View {
        if [.waitingForRecordingPermission, .isRecordingTap, .isRecordingHold, .hasRecording, .playingRecording, .pausedRecording].contains(state) {
            deleteRecordButton
        } else if hasAttachmentActions {
            Button {
                globalFocusState.focus = nil
                showAttachmentActions = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.colors.mainText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.colors.mainText.opacity(0.06)))
            }
            .disabled(!viewModel.inputEnabled || viewModel.isCommitting)
            .accessibilityLabel(localization.addToConversationText)
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    @ViewBuilder
    var leftView: some View {
        if [.isRecordingTap, .isRecordingHold, .hasRecording, .playingRecording, .pausedRecording].contains(state) {
            deleteRecordButton
        } else {
            switch style {
            case .message:
                leftButton
            case .signature:
                if viewModel.mediaPickerMode == .cameraSelection {
                    addButton
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
            }
        }
    }

    @ViewBuilder
    var middleView: some View {
        Group {
            switch state {
            case .hasRecording, .playingRecording, .pausedRecording:
                recordWaveform
            case .isRecordingHold:
                swipeToCancel
            case .isRecordingTap:
                recordingInProgress
            default:
                TextInputView(
                    text: $viewModel.text,
                    inputFieldId: inputFieldId,
                    style: style,
                    layout: layout,
                    availableInputs: availableInputs,
                    localization: localization
                )
                .disabled(!viewModel.inputEnabled)
            }
        }
        .frame(minHeight: 48)
    }

    @ViewBuilder
    var rightView: some View {
        Group {
            switch state {
            case .hasTextOrMedia:
                if case .message = style, !viewModel.text.isEmpty {
                    clearTextButton
                }
            case .isRecordingHold, .isRecordingTap:
                recordDurationInProcess
            case .hasRecording:
                recordDuration
            case .playingRecording, .pausedRecording:
                recordDurationLeft
            default:
                EmptyView()
            }
        }
        .frame(minHeight: 48)
    }

    @ViewBuilder
    var rightOutsideButton: some View {
        if state == .editing {
            editingButtons
                .frame(height: actionButtonSize)
        } else if audioRecordingMode == .tapToToggle {
            tapToToggleButton
        } else {
            holdToRecordButton
        }
    }

    @ViewBuilder
    var editingButtons: some View {
        HStack {
            Button {
                onAction(.cancelEdit)
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .fontWeight(.bold)
                    .padding(5)
                    .background(Circle().foregroundStyle(.red))
            }

            Button {
                onAction(.saveEdit)
            } label: {
                Image(systemName: "checkmark")
                    .foregroundStyle(.white)
                    .fontWeight(.bold)
                    .padding(5)
                    .background(Circle().foregroundStyle(.green))
            }
        }
    }

    var sendButton: some View {
        Button {
            onAction(.send)
        } label: {
            Group {
                if viewModel.isCommitting {
                    ProgressView()
                        .tint(theme.colors.mainTint)
                        .viewSize(actionButtonSize)
                } else {
                    if isEditorial {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .viewSize(actionButtonSize)
                            .background(Circle().fill(theme.colors.sendButtonBackground))
                    } else {
                        theme.images.inputView.arrowSend
                            .viewSize(actionButtonSize)
                            .circleBackground(theme.colors.sendButtonBackground)
                    }
                }
            }
        }
        .disabled(viewModel.sendDisabled || viewModel.isCommitting || !state.canSend)
        .opacity(viewModel.sendDisabled || viewModel.isCommitting || !state.canSend ? 0.42 : 1)
    }

    var addButton: some View {
        Button {
            onAction(.add)
        } label: {
            theme.images.inputView.add
                .viewSize(24)
                .circleBackground(theme.colors.sendButtonBackground)
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 8))
        }
        .disabled(!viewModel.inputEnabled || viewModel.isCommitting)
    }

    var clearTextButton: some View {
        Button {
            viewModel.text = ""
        } label: {
            theme.images.inputView.clearText
                .sizeAndColor(18, theme.colors.mainText.opacity(0.6))
                .padding(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 12))
        }
    }

    var backgroundColor: Color {
        switch style {
        case .message:
            return theme.contentBG
        case .signature:
            return pickerTheme.main.pickerBackground
        }
    }

    func isAudioAvailable() -> Bool {
        availableInputs.contains(AvailableInputType.audio)
    }

    func isGiphyAvailable() -> Bool {
        availableInputs.contains(AvailableInputType.giphy)
    }

    func isMediaAvailable() -> Bool {
        availableInputs.contains(AvailableInputType.media)
    }

    func isDocumentAvailable() -> Bool {
        availableInputs.contains(AvailableInputType.document)
    }

    func isLocationAvailable() -> Bool {
        availableInputs.contains(AvailableInputType.staticLocation) || availableInputs.contains(AvailableInputType.liveLocation)
    }
}

private struct ComposerSurface: View {
    let color: Color

    var body: some View {
        if #available(iOS 26.0, *) {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(color.opacity(0.34))
                }
        } else {
            RoundedRectangle(cornerRadius: 22)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(color.opacity(0.72))
                }
        }
    }
}
