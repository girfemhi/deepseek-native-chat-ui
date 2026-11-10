//
//  UIList+Pagination.swift
//  Chat
//
//  Created by Alisa Mylnikova on 05.05.2026.
//

import SwiftUI
import ActivityIndicatorView

@MainActor
final class PaginationState: ObservableObject {
    @Published private(set) var olderInProgress = false
    @Published private(set) var newerInProgress = false
    private var olderArmed = true
    private var newerArmed = true

    @discardableResult
    func beginOlder() -> Bool {
        guard !olderInProgress,olderArmed else { return false }
        olderArmed = false
        olderInProgress = true
        return true
    }

    func finishOlder() {
        olderInProgress = false
    }

    func rearmOlder() {
        if !olderInProgress { olderArmed = true }
    }

    func completeOlder(after operation:@MainActor () async -> Void) async {
        await operation()
        finishOlder()
    }

    @discardableResult
    func beginNewer() -> Bool {
        guard !newerInProgress,newerArmed else { return false }
        newerArmed = false
        newerInProgress = true
        return true
    }

    func finishNewer() {
        newerInProgress = false
    }

    func rearmNewer() {
        if !newerInProgress { newerArmed = true }
    }

    func completeNewer(after operation:@MainActor () async -> Void) async {
        await operation()
        finishNewer()
    }
}

struct HeaderView<TopContent: View>: View {
    @ObservedObject var paginationState: PaginationState

    let isFirst: Bool
    let type: ChatType
    let handler: PaginationHandler?

    let topContent: () -> TopContent

    var body: some View {
        VStack(spacing: 0) {
            if paginationState.newerInProgress, let handler, isFirst {
                handler.loadingIndicatorBuilder()
            }
            if type == .comments {
                topContent()
            }
        }
    }
}

struct FooterView<TopContent: View>: View {
    @ObservedObject var paginationState: PaginationState

    let isLast: Bool
    let type: ChatType
    let handler: PaginationHandler?

    let topContent: () -> TopContent

    var body: some View {
        VStack(spacing: 0) {
            if paginationState.olderInProgress, let handler, isLast {
                handler.loadingIndicatorBuilder()
            }
            if type == .conversation {
                topContent()
            }
        }
    }
}

extension UITableView {
    func relayoutHeadersFooters() {
        // update header/footer heights without full reload
        self.beginUpdates()
        self.endUpdates()
    }
}

public struct DefaultActivityIndicator: View {

    @Environment(\.chatTheme) var theme
    var size: CGFloat
    var color: Color?

    public init(size: CGFloat = 30, color: Color? = nil) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        ActivityIndicatorView(type: .default())
            .foregroundColor(color != nil ? color! : theme.colors.sendButtonBackground)
            .viewSize(size)
            .padding(.vertical, 10)
    }
}
