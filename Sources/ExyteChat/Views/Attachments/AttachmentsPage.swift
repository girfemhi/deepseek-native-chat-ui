//
//  Created by Alex.M on 20.06.2022.
//

import SwiftUI

struct AttachmentsPage: View {

    @EnvironmentObject var mediaPagesViewModel: FullscreenMediaPagesViewModel
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatLocalization) private var localization

    @State private var quickLookItem: DocumentQuickLookItem?

    let attachment: Attachment

    var body: some View {
        Group {
            if attachment.type == .image {
                ZoomableContainer {
                    if attachment.full.isGIF {
                        CachedAnimatedImage(
                            url: attachment.full,
                            cacheKey: attachment.fullCacheKey,
                            contentMode: .fit
                        ) {
                            ActivityIndicator()
                        }
                    } else {
                        CachedAsyncImage(
                            url: attachment.full,
                            cacheKey: attachment.fullCacheKey
                        ) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            default:
                                ActivityIndicator()
                            }
                        }
                    }
                }
            } else if attachment.type == .video {
                VideoView(viewModel: VideoViewModel(attachment: attachment))
            } else if attachment.type == .document {
                documentView
            } else {
                Rectangle()
                    .foregroundColor(Color.gray)
                    .frame(minWidth: 100, minHeight: 100)
                    .frame(maxHeight: 200)
                    .overlay {
                        Text("Unknown", bundle: .module)
                    }
            }
        }
        .sheet(item: $quickLookItem) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
    }

    private var documentView: some View {
        VStack(spacing: 16) {
            theme.images.message.attachedDocument
                .sizeAndColor(64, theme.colors.mainTint)

            Text(attachment.fileName ?? attachment.full.lastPathComponent)
                .foregroundColor(theme.colors.mainText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button {
                switch Self.documentOpenRoute(for: attachment.full) {
                case .quickLook(let url):
                    quickLookItem = DocumentQuickLookItem(url: url)
                case .external(let url):
                    UIApplication.shared.open(url)
                }
            } label: {
                Text(localization.openDocumentText)
                    .padding(20, 10)
                    .background(Capsule().fill(theme.colors.mainText.opacity(0.15)))
                    .foregroundColor(theme.colors.mainText)
            }
        }
    }

    static func documentOpenRoute(for url: URL) -> DocumentOpenRoute {
        url.isFileURL ? .quickLook(url) : .external(url)
    }
}

enum DocumentOpenRoute: Equatable {
    case quickLook(URL)
    case external(URL)
}

private struct DocumentQuickLookItem: Identifiable {
    let url: URL
    var id: URL { url }
}
