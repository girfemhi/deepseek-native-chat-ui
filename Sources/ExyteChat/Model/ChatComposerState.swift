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

    /// Cancels the SDK's pending submit task, stops recording and clears only
    /// ExyteChat-owned temporary recording files and in-memory draft state.
    public func discard(deleteOwnedRecordings: Bool = true) {
        inputViewModel.discard(deleteOwnedRecordings: deleteOwnedRecordings)
    }

    /// Immediately publishes the current draft snapshot without waiting for
    /// the normal debounce window.
    public func checkpoint() {
        inputViewModel.checkpoint()
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

    /// Deletes SDK-owned temporary recordings retained by
    /// `discard(deleteOwnedRecordings: false)` after the host has durably copied
    /// them. Documents and Photos library URLs are never included.
    public func releaseOwnedRecordings() async {
        await inputViewModel.releaseOwnedRecordings()
    }
}
