import Foundation

public enum ChatComposerFinalization: Sendable {
    /// No unpublished composer mutation remains.
    case noChange
    /// Persist or replace the scoped draft with this snapshot.
    case save(DraftMessage)
    /// Remove the persisted draft for this scope.
    case removeEmpty
}

/// Stable ownership for one conversation's composer.
///
/// Cache one state per account/conversation scope and pass it back when the
/// ChatView is remounted. This keeps pending submissions and draft ownership in
/// one input model instead of allowing an older model to overwrite a newer one.
@MainActor
public final class ChatComposerState {
    let inputViewModel: InputViewModel

    public init() {
        inputViewModel = InputViewModel()
    }

    init(inputViewModel: InputViewModel) {
        self.inputViewModel = inputViewModel
    }

    /// Cancels SDK work and clears in-memory draft state. By default it deletes
    /// ExyteChat-owned temporary recordings and pasted staging copies; pass
    /// `false` while the host is still durably copying those files.
    public func discard(deleteOwnedRecordings: Bool = true) {
        inputViewModel.discard(deleteOwnedRecordings: deleteOwnedRecordings)
    }

    /// Immediately publishes the current draft snapshot without waiting for
    /// the normal debounce window.
    public func checkpoint() {
        inputViewModel.checkpoint()
    }

    /// Replaces only the editable text while keeping media, documents,
    /// recording, reply and location attachments intact. Hosts can use this
    /// for suggestions or "edit and send" without mirroring every keystroke
    /// through a parent observable model.
    public func setText(_ text: String) {
        inputViewModel.text = text
    }

    /// Prepares the composer for background suspension. Pending permission
    /// requests are invalidated, active SDK recording is stopped and retained,
    /// and the resulting draft is synchronously checkpointed.
    public func checkpointForBackground() async {
        await inputViewModel.checkpointForBackground()
    }

    /// Stops any SDK recording and returns an explicit save/remove/no-change
    /// result before a scope is reset or handed to durable storage. If the last
    /// mount already started finalization, this awaits and consumes that same
    /// result rather than relying on a possibly generation-gated callback.
    public func finalizeForUnmount() async -> ChatComposerFinalization {
        await inputViewModel.finalizeForUnmount()
    }

    /// Compatibility release API. It deletes all ExyteChat-owned files retained
    /// by `discard(deleteOwnedRecordings: false)`, including pasted staging
    /// copies. Original documents and Photos library URLs are never included.
    public func releaseOwnedRecordings() async {
        await inputViewModel.releaseOwnedRecordings()
    }

    /// Releases every ExyteChat-owned staged file retained after a failed
    /// durable handoff, including recordings and pasted attachments.
    public func releaseOwnedFiles() async {
        await inputViewModel.releaseOwnedFiles()
    }
}
