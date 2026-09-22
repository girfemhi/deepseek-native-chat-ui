import SwiftUI

struct AttachmentActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatTheme) private var theme

    let availableInputs: [AvailableInputType]
    let localization: ChatLocalization
    let onAction: (InputViewAction) -> Void

    private var isMediaAvailable: Bool {
        availableInputs.contains(.media)
    }

    private var actions: [AttachmentSheetAction] {
        var result: [AttachmentSheetAction] = []
        if isMediaAvailable {
            result.append(.init(icon: "camera", title: localization.attachCameraText, action: .camera))
            result.append(.init(icon: "photo.on.rectangle", title: localization.attachMediaText, action: .photo))
        }
        if availableInputs.contains(.document) {
            result.append(.init(icon: "doc", title: localization.attachDocumentText, action: .document))
        }
        if availableInputs.contains(.giphy) {
            result.append(.init(icon: "face.smiling", title: localization.attachGifText, action: .giphy))
        }
        if availableInputs.contains(.staticLocation) || availableInputs.contains(.liveLocation) {
            result.append(.init(icon: "location", title: localization.attachLocationText, action: .location))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(actions) { item in
                        actionRow(item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .background(theme.colors.mainBG.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.mainText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.colors.mainText.opacity(0.07)))
            }
            .accessibilityLabel(localization.cancelButtonText)

            Text(localization.addToConversationText)
                .font(.headline)
                .foregroundStyle(theme.colors.mainText)

            Spacer(minLength: 8)

            if isMediaAvailable {
                Button(localization.photoLibraryText) {
                    perform(.photo)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.colors.mainTint)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(
                    Capsule().fill(theme.colors.mainText.opacity(0.06))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func actionRow(_ item: AttachmentSheetAction) -> some View {
        Button {
            perform(item.action)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(theme.colors.mainTint)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.colors.mainText.opacity(0.06))
                    )

                Text(item.title)
                    .font(.body)
                    .foregroundStyle(theme.colors.mainText)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.colors.mainCaptionText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.colors.inputBG)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func perform(_ action: InputViewAction) {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            onAction(action)
        }
    }
}

private struct AttachmentSheetAction: Identifiable {
    let icon: String
    let title: String
    let action: InputViewAction
    var id: String { icon + ":" + title }
}
