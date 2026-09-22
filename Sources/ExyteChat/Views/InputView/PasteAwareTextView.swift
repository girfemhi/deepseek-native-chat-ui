import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PasteAwareTextView: UIViewRepresentable {
    @Binding var text: String
    let textColor: UIColor
    let isFocused: Bool
    let onFocusChanged: (Bool) -> Void
    let onPasteProviders: ([NSItemProvider], @escaping (String) -> Void) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> AttachmentPasteTextView {
        let view = AttachmentPasteTextView()
        view.delegate = context.coordinator
        view.pasteDelegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.returnKeyType = .default
        view.pasteConfiguration = UIPasteConfiguration(
            acceptableTypeIdentifiers: [UTType.item.identifier]
        )
        view.onPasteProviders = { providers, insertText in
            context.coordinator.parent.onPasteProviders(providers, insertText)
        }
        return view
    }

    func updateUIView(_ view: AttachmentPasteTextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteProviders = { providers, insertText in
            context.coordinator.parent.onPasteProviders(providers, insertText)
        }
        if view.text != text { view.text = text }
        view.textColor = textColor
        if isFocused, !view.isFirstResponder { view.becomeFirstResponder() }
        if !isFocused, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AttachmentPasteTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        return CGSize(width: width, height: min(max(measured.height, lineHeight), lineHeight * 6))
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        var parent: PasteAwareTextView

        init(parent: PasteAwareTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChanged(false)
        }

        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            transform item: UITextPasteItem
        ) {
            item.setDefaultResult()
        }
    }
}

final class AttachmentPasteTextView: UITextView {
    var onPasteProviders: (([NSItemProvider], @escaping (String) -> Void) -> Void)?

    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        guard !providers.isEmpty,
              PastedContentImporter.containsAttachment(providers),
              let onPasteProviders else {
            super.paste(sender)
            return
        }

        onPasteProviders(providers) { [weak self] text in
            guard let self, !text.isEmpty else { return }
            insertText(text)
            delegate?.textViewDidChange?(self)
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)),
           PastedContentImporter.containsAttachment(UIPasteboard.general.itemProviders) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
