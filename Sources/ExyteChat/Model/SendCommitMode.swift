//
//  SendCommitMode.swift
//  Chat
//

import Foundation

/// Controls when the built-in composer clears a draft.
///
/// The default ``immediate`` mode preserves ExyteChat's original behavior.
/// ``deferred`` is intended for agent and remote-service clients: the composer
/// retains its draft until the async host submission acknowledges delivery.
public enum SendCommitMode {
    case immediate
    case deferred(@MainActor @Sendable (DraftMessage) async -> Bool)
}
