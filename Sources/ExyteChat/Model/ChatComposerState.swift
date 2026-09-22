import Foundation

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
    public func discard() {
        inputViewModel.discard()
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
}
