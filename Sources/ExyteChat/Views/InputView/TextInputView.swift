//
//  Created by Alex.M on 14.06.2022.
//

import SwiftUI

struct TextInputView: View {
    
    @Environment(\.chatTheme) private var theme
    
    @EnvironmentObject private var globalFocusState: GlobalFocusState
    
    @Binding var text: String
    var inputFieldId: UUID
    var style: InputViewStyle
    var layout: InputViewLayout = .classic
    var availableInputs: [AvailableInputType]
    var localization: ChatLocalization
    var onPasteProviders: ([NSItemProvider], @escaping (String) -> Void) -> Void = { _, _ in }
    
    var body: some View {
        Group {
            if style == .message {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(localization.inputPlaceholder)
                            .foregroundStyle(theme.colors.inputPlaceholderText)
                            .font(.body)
                            .allowsHitTesting(false)
                    }
                    PasteAwareTextView(
                        text: $text,
                        textColor: UIColor(theme.colors.inputText),
                        isFocused: globalFocusState.focus == .uuid(inputFieldId),
                        onFocusChanged: { focused in
                            if focused {
                                globalFocusState.focus = .uuid(inputFieldId)
                            } else if globalFocusState.focus == .uuid(inputFieldId) {
                                globalFocusState.focus = nil
                            }
                        },
                        onPasteProviders: onPasteProviders
                    )
                }
            } else {
                TextField("", text: $text, prompt: Text(localization.signatureText)
                    .foregroundColor(theme.colors.inputSignaturePlaceholderText), axis: .vertical)
                    .customFocus($globalFocusState.focus, equals: .uuid(inputFieldId))
                    .foregroundColor(theme.colors.inputSignatureText)
            }
        }
            .lineLimit(1...6)
            .frame(minHeight: layout == .editorial ? 24 : 44)
            .padding(.vertical, layout == .editorial ? 12 : 10)
            .padding(.leading, layout == .editorial ? 0 : (!isAttachmentsAvailable() ? 12 : 0))
            .simultaneousGesture(
                TapGesture().onEnded {
                    globalFocusState.focus = .uuid(inputFieldId)
                }
            )
    }
    
    private func isAttachmentsAvailable() -> Bool {
        let attachmentTypes: [AvailableInputType] = [.media, .giphy, .document, .staticLocation, .liveLocation]
        return attachmentTypes.contains { availableInputs.contains($0) }
    }
}
